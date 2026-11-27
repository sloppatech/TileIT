package tileit

// "Synth" tiling mode: rebuild the seams from real texture content.
//
//   1. Start from the Quick (periodic-plus-smooth) result, which already tiles
//      and has matched colours, but may show broken structure at the seams.
//   2. Shift by half the size so the seams form a cross in the middle.
//   3. Mark a band around that cross as unknown and fill it with patch-based
//      texture synthesis (Wexler et al. 2007 "Space-Time Completion", using
//      PatchMatch, Barnes et al. 2009), coarse to fine. Everything wraps around
//      the edges, so the result stays periodic.
//   4. Shift back. Outside the band the pixels are exactly the Quick result.
//
// The final nearest-neighbour field is a per-pixel "where did this come from"
// map, which is what will later let normal/roughness/height maps be tiled with
// exactly the same edit as the albedo.

import "core:math"
import "core:sync"

PATCH_R :: 3 // 7×7 patches

// Rough fraction done, for the GUI. Written by the worker, read by the UI.
synth_progress: f32

@(private = "file")
Level :: struct {
	w, h:    int,
	img:     []f32,  // RGBA
	unknown: []bool,
	valid:   []bool, // a patch centred here lies entirely in the known region
	srcs:    []i32,  // all valid centres
	targets: []i32,  // pixels whose patch touches the unknown region
	holes:   []i32,  // unknown pixels
	nnf:     []i32,  // per pixel: matched source centre, -1 if not a target
	nnf_old: []i32,  // snapshot taken before each PatchMatch sweep
	cost:    []f32,
	srcmap:  []i32,  // finest level: the source pixel each hole was copied from
	// Repeat lattice (0 = none on that axis): a target may only copy from a
	// source a whole number of repeats away, ± tol. Keeps joints and mortar
	// where the pattern puts them instead of merging bricks.
	per, tol: [2]f32,
	usage:   []u16, // per source pixel: how many targets copy from it (reuse penalty)
	lambda:  f32,   // reuse penalty per extra use
	weights: [2 * PATCH_R + 1][2 * PATCH_R + 1]f32,
}

@(private = "file")
wrap :: #force_inline proc "contextless" (v, n: int) -> int {
	r := v % n
	return r < 0 ? r + n : r
}

@(private = "file")
xorshift :: #force_inline proc "contextless" (s: ^u32) -> u32 {
	x := s^
	x ~= x << 13; x ~= x >> 17; x ~= x << 5
	s^ = x
	return x
}

@(private = "file")
dilate :: proc(m: []bool, w, h, r: int) -> []bool {
	tmp := make([]bool, w * h)
	defer delete(tmp)
	out := make([]bool, w * h)
	for y in 0 ..< h {
		for x in 0 ..< w {
			for d in -r ..= r do if m[y * w + wrap(x + d, w)] { tmp[y * w + x] = true; break }
		}
	}
	for y in 0 ..< h {
		for x in 0 ..< w {
			for d in -r ..= r do if tmp[wrap(y + d, h) * w + x] { out[y * w + x] = true; break }
		}
	}
	return out
}

@(private = "file")
// center: only patches whose position in the *original* (unshifted) image
// lies inside the central `center` fraction may be copied from. Photo edges
// carry lens distortion, perspective and vignetting, and P+S altered them.
level_prepare :: proc(L: ^Level, center: f32 = 1) {
	n := L.w * L.h
	near := dilate(L.unknown, L.w, L.h, PATCH_R)
	defer delete(near)
	L.valid = make([]bool, n)
	L.nnf = make([]i32, n)
	L.nnf_old = make([]i32, n)
	L.cost = make([]f32, n)
	srcs, targets, holes: [dynamic]i32
	for i in 0 ..< n {
		L.valid[i] = !near[i]
		if center < 1 && L.valid[i] {
			// Undo the half shift to get original coordinates.
			ox := (i % L.w + L.w / 2) % L.w
			oy := (i / L.w + L.h / 2) % L.h
			hx := center * f32(L.w) / 2 - PATCH_R
			hy := center * f32(L.h) / 2 - PATCH_R
			if abs(f32(ox) + 0.5 - f32(L.w) / 2) > hx || abs(f32(oy) + 0.5 - f32(L.h) / 2) > hy {
				L.valid[i] = false
			}
		}
		L.nnf[i] = -1
		if L.valid[i] do append(&srcs, i32(i))
		if near[i] do append(&targets, i32(i))
		if L.unknown[i] do append(&holes, i32(i))
	}
	L.srcs, L.targets, L.holes = srcs[:], targets[:], holes[:]
}

@(private = "file")
level_destroy :: proc(L: ^Level) {
	delete(L.img); delete(L.unknown); delete(L.valid); delete(L.srcs)
	delete(L.targets); delete(L.holes); delete(L.nnf); delete(L.nnf_old); delete(L.cost); delete(L.srcmap); delete(L.usage)
}

@(private = "file")
patch_dist :: proc "contextless" (L: ^Level, p, s: int, best: f32) -> f32 {
	w, h := L.w, L.h
	px, py := p % w, p / w
	sx, sy := s % w, s / w
	img := L.img
	inner := px >= PATCH_R && px < w - PATCH_R && sx >= PATCH_R && sx < w - PATCH_R
	d: f32
	for dy in -PATCH_R ..= PATCH_R {
		ty := wrap(py + dy, h) * w
		uy := wrap(sy + dy, h) * w
		if inner {
			a := (ty + px - PATCH_R) * 4
			b := (uy + sx - PATCH_R) * 4
			for k in 0 ..< 2 * PATCH_R + 1 {
				e0 := img[a + k * 4] - img[b + k * 4]
				e1 := img[a + k * 4 + 1] - img[b + k * 4 + 1]
				e2 := img[a + k * 4 + 2] - img[b + k * 4 + 2]
				d += e0 * e0 + e1 * e1 + e2 * e2
			}
		} else {
			for dx in -PATCH_R ..= PATCH_R {
				a := (ty + wrap(px + dx, w)) * 4
				b := (uy + wrap(sx + dx, w)) * 4
				e0 := img[a] - img[b]
				e1 := img[a + 1] - img[b + 1]
				e2 := img[a + 2] - img[b + 2]
				d += e0 * e0 + e1 * e1 + e2 * e2
			}
		}
		if d >= best do return d
	}
	return d
}

@(private = "file")
Pass :: struct {
	L:       ^Level,
	reverse: bool,
	seed:    u32,
}

@(private = "file")
random_source :: #force_inline proc "contextless" (L: ^Level, rng: ^u32) -> int {
	return int(L.srcs[int(xorshift(rng)) % len(L.srcs)])
}

@(private = "file")
lattice_active :: #force_inline proc "contextless" (L: ^Level) -> bool { return L.per.x > 0 || L.per.y > 0 }

// Is source s a whole number of repeats (± tol) away from target p?
@(private = "file")
lattice_ok :: proc "contextless" (L: ^Level, p, s: int) -> bool {
	off :: #force_inline proc "contextless" (d, per: f32) -> f32 {
		k := f32(int(d / per + 0.5)) // d >= 0
		return abs(d - k * per)
	}
	if L.per.x > 0 && off(f32(wrap(s % L.w - p % L.w, L.w)), L.per.x) > L.tol.x do return false
	if L.per.y > 0 && off(f32(wrap(s / L.w - p / L.w, L.h)), L.per.y) > L.tol.y do return false
	return true
}

// A random valid source on p's lattice (falls back to any valid source).
@(private = "file")
lattice_random :: proc "contextless" (L: ^Level, p: int, rng: ^u32) -> int {
	if !lattice_active(L) do return random_source(L, rng)
	px, py := p % L.w, p / L.w
	for _ in 0 ..< 24 {
		x, y: int
		if L.per.x > 0 {
			nx := max(int(f32(L.w) / L.per.x + 0.5), 1)
			k := int(xorshift(rng) % u32(nx))
			j := int(xorshift(rng) % u32(2 * int(L.tol.x) + 1)) - int(L.tol.x)
			x = wrap(px + int(f32(k) * L.per.x + 0.5) + j, L.w)
		} else do x = int(xorshift(rng) % u32(L.w))
		if L.per.y > 0 {
			ny := max(int(f32(L.h) / L.per.y + 0.5), 1)
			k := int(xorshift(rng) % u32(ny))
			j := int(xorshift(rng) % u32(2 * int(L.tol.y) + 1)) - int(L.tol.y)
			y = wrap(py + int(f32(k) * L.per.y + 0.5) + j, L.h)
		} else do y = int(xorshift(rng) % u32(L.h))
		c := y * L.w + x
		if L.valid[c] && lattice_ok(L, p, c) do return c
	}
	return random_source(L, rng)
}

@(private = "file")
init_chunk :: proc(data: rawptr, begin, end, chunk: int) {
	P := (^Pass)(data)
	L := P.L
	rng := P.seed ~ u32(chunk * 7919 + 1)
	for i in begin ..< end {
		p := int(L.targets[i])
		if L.nnf[p] < 0 do L.nnf[p] = i32(lattice_random(L, p, &rng))
		L.cost[p] = patch_dist(L, p, int(L.nnf[p]), max(f32))
	}
}

// Completeness, cheaply (cf. Wexler et al.'s bidirectional similarity, Kaspar
// et al. 2015): copying from a source spot that other targets already copy
// from costs a little extra, so the fill spreads over more of the photo
// instead of repeating one (often smoother) region. Off on a repeat lattice,
// where reusing the same repeat offsets is the point.
REUSE_PENALTY :: #config(TILEIT_REUSE, 0.15) // per extra use, x mean patch distance

@(private = "file")
reuse_penalty :: #force_inline proc "contextless" (L: ^Level, c: int, own: bool) -> f32 {
	if L.usage == nil || L.lambda <= 0 do return 0
	u := int(L.usage[c])
	if own do u -= 1 // the target's current match counts itself
	return L.lambda * f32(max(u, 0))
}

@(private = "file")
try_source :: #force_inline proc "contextless" (L: ^Level, p, c: int, best: ^int, bestd, bestraw: ^f32) {
	pen := reuse_penalty(L, c, false)
	if pen >= bestd^ do return
	d := patch_dist(L, p, c, bestd^ - pen)
	if d + pen < bestd^ {
		bestd^ = d + pen
		bestraw^ = d
		best^ = c
	}
}

// Recount how many targets copy from each source spot (before a sweep).
@(private = "file")
update_usage :: proc(L: ^Level) {
	if lattice_active(L) || REUSE_PENALTY <= 0 { L.lambda = 0; return }
	if L.usage == nil do L.usage = make([]u16, L.w * L.h)
	for &u in L.usage do u = 0
	sum: f64
	for t in L.targets {
		s := L.nnf[t]
		if s >= 0 && L.usage[s] < max(u16) do L.usage[s] += 1
		sum += f64(L.cost[t])
	}
	L.lambda = f32(REUSE_PENALTY * sum / f64(max(len(L.targets), 1)))
}

// One PatchMatch sweep (propagation + random search) over a slice of targets.
@(private = "file")
pm_chunk :: proc(data: rawptr, begin, end, chunk: int) {
	P := (^Pass)(data)
	L := P.L
	w, h := L.w, L.h
	rng := P.seed ~ u32(chunk * 104729 + 17)
	step := P.reverse ? -1 : 1
	max_r := max(w, h)
	// Targets are sorted, so this chunk owns exactly the targets in [lo, hi].
	// Neighbours owned by other chunks are read from the pre-sweep snapshot,
	// which keeps the result independent of thread timing.
	lo, hi := int(L.targets[begin]), int(L.targets[end - 1])
	for k in 0 ..< end - begin {
		i := P.reverse ? end - 1 - k : begin + k
		p := int(L.targets[i])
		px, py := p % w, p / w
		best := int(L.nnf[p])
		bestraw := L.cost[p] // plain patch distance of the current best
		bestd := bestraw + reuse_penalty(L, best, true) // what candidates must beat

		// Propagation: the neighbour we just visited, shifted by one pixel.
		for axis in 0 ..< 2 {
			q := axis == 0 ? py * w + wrap(px - step, w) : wrap(py - step, h) * w + px
			sq := int(q >= lo && q <= hi ? L.nnf[q] : L.nnf_old[q])
			if sq < 0 do continue
			cx, cy := sq % w, sq / w
			if axis == 0 do cx = wrap(cx + step, w)
			else do cy = wrap(cy + step, h)
			c := cy * w + cx
			if c == best || !L.valid[c] || !lattice_ok(L, p, c) do continue
			try_source(L, p, c, &best, &bestd, &bestraw)
		}

		if lattice_active(L) {
			// On a lattice: a few jumps to other lattice sites, then a local
			// search within the tolerance around the best.
			for _ in 0 ..< 4 {
				c := lattice_random(L, p, &rng)
				if c == best || !L.valid[c] || !lattice_ok(L, p, c) do continue
				try_source(L, p, c, &best, &bestd, &bestraw)
			}
			r0 := max(int(max(L.tol.x, L.tol.y)), 1)
			for r := r0; r >= 1; r /= 2 {
				bx, by := best % w, best / w
				span := u32(2 * r + 1)
				c := wrap(by + int(xorshift(&rng) % span) - r, h) * w + wrap(bx + int(xorshift(&rng) % span) - r, w)
				if !L.valid[c] || !lattice_ok(L, p, c) do continue
				try_source(L, p, c, &best, &bestd, &bestraw)
			}
		} else {
			// Random search around the current best, shrinking radius.
			for r := max_r; r >= 1; r /= 2 {
				bx, by := best % w, best / w
				span := u32(2 * r + 1)
				cx := wrap(bx + int(xorshift(&rng) % span) - r, w)
				cy := wrap(by + int(xorshift(&rng) % span) - r, h)
				c := cy * w + cx
				if !L.valid[c] do continue
				try_source(L, p, c, &best, &bestd, &bestraw)
			}
		}
		L.nnf[p] = i32(best)
		L.cost[p] = bestraw
	}
}

// Every unknown pixel becomes the weighted average of what the overlapping
// patches' matches say it should be. Sources are always fully known, so this
// only reads known pixels and can safely write in place.
@(private = "file")
vote_chunk :: proc(data: rawptr, begin, end, chunk: int) {
	P := (^Pass)(data)
	L := P.L
	w, h := L.w, L.h
	for i in begin ..< end {
		q := int(L.holes[i])
		qx, qy := q % w, q / w
		acc: [4]f32
		ws: f32
		for dy in -PATCH_R ..= PATCH_R {
			py := wrap(qy - dy, h)
			for dx in -PATCH_R ..= PATCH_R {
				p := py * w + wrap(qx - dx, w)
				s := int(L.nnf[p])
				if s < 0 do continue
				src := (wrap(s / w + dy, h) * w + wrap(s % w + dx, w)) * 4
				wt := L.weights[dy + PATCH_R][dx + PATCH_R]
				acc += wt * [4]f32{L.img[src], L.img[src + 1], L.img[src + 2], L.img[src + 3]}
				ws += wt
			}
		}
		if ws > 0 {
			acc /= ws
			L.img[q * 4 + 0] = acc[0]
			L.img[q * 4 + 1] = acc[1]
			L.img[q * 4 + 2] = acc[2]
			L.img[q * 4 + 3] = acc[3]
		}
	}
}

// Final pass: instead of averaging (which blurs fine grain like sand), each
// hole copies the pixel from the single best-matching overlapping patch.
// Neighbouring holes usually pick the same patch, so this copies coherent
// chunks; the screened Poisson blend then hides the tone steps between them.
// Records the chosen source pixel in srcmap.
@(private = "file")
copy_chunk :: proc(data: rawptr, begin, end, chunk: int) {
	P := (^Pass)(data)
	L := P.L
	w, h := L.w, L.h
	for i in begin ..< end {
		q := int(L.holes[i])
		qx, qy := q % w, q / w
		best := max(f32)
		src := -1
		for dy in -PATCH_R ..= PATCH_R {
			py := wrap(qy - dy, h)
			for dx in -PATCH_R ..= PATCH_R {
				p := py * w + wrap(qx - dx, w)
				s := int(L.nnf[p])
				if s < 0 || L.cost[p] >= best do continue
				best = L.cost[p]
				src = wrap(s / w + dy, h) * w + wrap(s % w + dx, w)
			}
		}
		if src < 0 do src = int(L.nnf[q]) // q is a target, so this exists
		L.srcmap[q] = i32(src)
		copy(L.img[q * 4:][:4], L.img[src * 4:][:4])
	}
}

// ---------------------------------------------------------------------------
// Gradient-domain blending (Pérez et al. 2003, "Poisson Image Editing").
// Unknowns: the band pixels. Each edge between neighbours q, n should have the
// gradient that the *source* texture has there (from the final patch matches),
// and band pixels next to untouched pixels are pinned by them. That gives a
// masked Laplacian system (poisson.odin), warm-started from the voted result.
//
// It is *screened* (Bhat et al. 2008, "Fourier Analysis of the 2D Screened
// Poisson Equation"): a weak pull towards the voted colours. Unscreened,
// small inconsistencies in the guidance integrate across the whole band into
// colour drift (cyan mortar on bricks); screened, a tone step is spread over
// a few dozen pixels and then dies out.
BLEND_SCREEN :: #config(TILEIT_SCREEN, 0.002)

@(private = "file")
Blend :: struct {
	L:    ^Level,
	G:    ^Mask_Grid,
	b, x: [][4]f32,
}

@(private = "file")
NEIGHBOURS :: [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

@(private = "file")
px4 :: #force_inline proc "contextless" (L: ^Level, i: int) -> [4]f32 {
	return {L.img[i * 4], L.img[i * 4 + 1], L.img[i * 4 + 2], L.img[i * 4 + 3]}
}

@(private = "file")
offset :: #force_inline proc "contextless" (L: ^Level, i, dx, dy: int) -> int {
	return wrap(i / L.w + dy, L.h) * L.w + wrap(i % L.w + dx, L.w)
}

@(private = "file")
blend_setup :: proc(data: rawptr, begin, end, chunk: int) {
	B := (^Blend)(data)
	L := B.L
	for i in begin ..< end {
		q := int(L.holes[i])
		sq := int(L.srcmap[q])
		b: [4]f32
		for d in NEIGHBOURS {
			n := offset(L, q, d.x, d.y)
			// Desired f(q) - f(n), from q's source; averaged with n's source.
			// Inside a coherently copied chunk both agree exactly.
			g := px4(L, sq) - px4(L, offset(L, sq, d.x, d.y))
			if B.G.idx[n] >= 0 {
				sn := int(L.srcmap[n])
				g = 0.5 * (g + px4(L, offset(L, sn, -d.x, -d.y)) - px4(L, sn))
			} else {
				b += px4(L, n) // pinned neighbour
			}
			b += g
		}
		v := px4(L, q)
		B.b[i] = b + B.G.screen * v
		B.x[i] = v
	}
}

@(private = "file")
poisson_blend :: proc(L: ^Level) {
	n := len(L.holes)
	if n == 0 do return
	G := grid_make(L.w, L.h, L.holes, BLEND_SCREEN)
	defer grid_destroy(&G)
	bufs := make([][4]f32, 2 * n)
	defer delete(bufs)
	B := Blend{L, &G, bufs[:n], bufs[n:]}
	parallel_for(n, &B, blend_setup, 4096)
	poisson_solve(&G, B.x, B.b)
	for q, i in L.holes {
		for c in 0 ..< 4 do L.img[int(q) * 4 + c] = B.x[i][c]
	}
}

@(private = "file")
downsample :: proc(F: ^Level) -> (C: Level) {
	C.w, C.h = (F.w + 1) / 2, (F.h + 1) / 2
	C.img = make([]f32, C.w * C.h * 4)
	C.unknown = make([]bool, C.w * C.h)
	for y in 0 ..< C.h {
		for x in 0 ..< C.w {
			o := (y * C.w + x) * 4
			for j in 0 ..< 2 {
				for i in 0 ..< 2 {
					f := wrap(2 * y + j, F.h) * F.w + wrap(2 * x + i, F.w)
					for c in 0 ..< 4 do C.img[o + c] += 0.25 * F.img[f * 4 + c]
					if F.unknown[f] do C.unknown[y * C.w + x] = true
				}
			}
		}
	}
	return
}

Synth_Params :: struct {
	band:   f32, // half-width of the rebuilt band, as a fraction of the shorter side
	seed:   u32,
	center: f32, // copy sources only from this central fraction of the original (1 = anywhere)
	// Repeat of a regular texture in pixels (0 = none on that axis). The image
	// must already hold whole repeats; copies are then restricted to whole
	// repeat offsets (± REPEAT_TOL of a repeat).
	period: [2]f32,
	// Which seams to rebuild: x = the left/right seam (a vertical band),
	// y = the top/bottom seam. Zero value means both.
	axes:   [2]bool,
}

// Slack around exact repeat offsets, as a fraction of the repeat: real walls
// drift a little (perspective, uneven bricks), so the match may slide a bit.
REPEAT_TOL :: 0.03

// Shift by half the size (forward: the old edges meet in the middle).
@(private = "file")
shift_half :: proc(dst, src: []f32, w, h: int, back: bool) {
	for y in 0 ..< h {
		for x in 0 ..< w {
			s: int
			if back do s = (((y - h / 2) %% h) * w + (x - w / 2) %% w) * 4
			else do s = ((y + h / 2) % h * w + (x + w / 2) % w) * 4
			copy(dst[(y * w + x) * 4:][:4], src[s:][:4])
		}
	}
}

// src must already be periodic (the Quick result). Returns a new image.
synthesize_seams :: proc(src: Image, sp: Synth_Params) -> Image {
	out, _ := synthesize_seams_set(src, nil, sp)
	return out
}

// Material-set version. The synthesis is driven by `guide` (normally the
// albedo); every image in `others` (normal, roughness, height... — also
// already periodic, same size) receives exactly the same edit: each band
// pixel is copied from the same source location, then blended the same way.
// That keeps all maps of a material aligned.
synthesize_seams_set :: proc(guide: Image, others: []Image, sp: Synth_Params) -> (out: Image, others_out: []Image) {
	src := guide
	w, h := src.w, src.h
	sync.atomic_store(&synth_progress, 0)
	out = image_like(src, w, h)
	others_out = make([]Image, len(others))
	for o, i in others do others_out[i] = image_like(o, w, h)
	b := max(f32(min(w, h)) * sp.band, 2)

	// Finest level: src shifted by half, so the old edges meet in the middle.
	levels: [dynamic]Level
	defer { for &L in levels do level_destroy(&L); delete(levels) }
	{
		L := Level{w = w, h = h, img = make([]f32, w * h * 4), unknown = make([]bool, w * h)}
		shift_half(L.img, src.px, w, h, back = false)
		cx, cy := f32(w) / 2 - 0.5, f32(h) / 2 - 0.5
		ax, ay := sp.axes.x, sp.axes.y
		if !ax && !ay do ax, ay = true, true
		for y in 0 ..< h {
			for x in 0 ..< w {
				L.unknown[y * w + x] = (ax && abs(f32(x) - cx) <= b) || (ay && abs(f32(y) - cy) <= b)
			}
		}
		append(&levels, L)
	}
	for min(levels[len(levels) - 1].w, levels[len(levels) - 1].h) >= 96 {
		append(&levels, downsample(&levels[len(levels) - 1]))
	}
	for &L, i in levels {
		level_prepare(&L, sp.center > 0 ? sp.center : 1)
		for a in 0 ..< 2 {
			if sp.period[a] <= 0 do continue
			scale := a == 0 ? f32(L.w) / f32(w) : f32(L.h) / f32(h)
			L.per[a] = sp.period[a] * scale
			L.tol[a] = max(L.per[a] * REPEAT_TOL, 1.5)
		}
		// Coarse levels average uniformly (structure); the finest level leans
		// towards each patch's centre, which keeps the result sharper.
		sigma: f32 = i == 0 ? 1.5 : 1000
		for dy in -PATCH_R ..= PATCH_R do for dx in -PATCH_R ..= PATCH_R {
			L.weights[dy + PATCH_R][dx + PATCH_R] = math.exp(-f32(dx * dx + dy * dy) / (2 * sigma * sigma))
		}
		if len(L.srcs) == 0 {
			// Band covers everything (tiny image): nothing to copy from.
			copy(out.px, src.px)
			for o, j in others do copy(others_out[j].px, o.px)
			return
		}
	}

	// Work estimate for the progress bar: targets × iterations, per level.
	iters :: proc(level, count: int) -> int {
		if level == 0 do return 2
		if level == count - 1 do return 6
		return 3
	}
	total, done: f64
	for L, i in levels do total += f64(len(L.targets) * iters(i, len(levels)))

	seed := sp.seed | 1
	for li := len(levels) - 1; li >= 0; li -= 1 {
		L := &levels[li]
		pass := Pass{L = L}
		if li < len(levels) - 1 {
			// Upsample the coarser field: same source, doubled coordinates.
			C := &levels[li + 1]
			rng := seed ~ u32(li * 31)
			for t in L.targets {
				p := int(t)
				x, y := p % L.w, p / L.w
				s := int(C.nnf[(y / 2) * C.w + x / 2])
				if s >= 0 {
					fx := wrap((s % C.w) * 2 + (x & 1), L.w)
					fy := wrap((s / C.w) * 2 + (y & 1), L.h)
					f := fy * L.w + fx
					if L.valid[f] && lattice_ok(L, p, f) { L.nnf[p] = i32(f); continue }
				}
				L.nnf[p] = i32(lattice_random(L, p, &rng))
			}
			parallel_for(len(L.holes), &pass, vote_chunk)
		}
		pass.seed = seed
		parallel_for(len(L.targets), &pass, init_chunk)

		n_it := iters(li, len(levels))
		for it in 0 ..< n_it {
			for dir in 0 ..< 2 {
				pass.reverse = dir == 1
				pass.seed = seed + u32(li * 1000 + it * 10 + dir) * 2654435761
				copy(L.nnf_old, L.nnf)
				update_usage(L)
				parallel_for(len(L.targets), &pass, pm_chunk)
			}
			if li == 0 && it == n_it - 1 {
				L.srcmap = make([]i32, L.w * L.h)
				parallel_for(len(L.holes), &pass, copy_chunk)
			} else {
				parallel_for(len(L.holes), &pass, vote_chunk)
			}
			done += f64(len(L.targets))
			sync.atomic_store(&synth_progress, f32(done / total))
		}
	}

	// Copied chunks carry their own overall tone, which shows as straight edges
	// where chunks meet each other or the untouched texture. Re-solve the band
	// in the gradient domain so the detail stays but the tones join up.
	F := &levels[0]
	when !#config(TILEIT_NO_BLEND, false) do poisson_blend(F)

	// Shift back so the texture keeps its original framing.
	shift_half(out.px, F.img, w, h, back = true)

	// Other maps of the set: same copy (srcmap), same blend, same shift.
	for o, j in others {
		E := Level{w = w, h = h, img = make([]f32, w * h * 4), holes = F.holes, srcmap = F.srcmap}
		defer delete(E.img)
		shift_half(E.img, o.px, w, h, back = false)
		for q in F.holes {
			s := int(F.srcmap[q])
			copy(E.img[int(q) * 4:][:4], E.img[s * 4:][:4])
		}
		when !#config(TILEIT_NO_BLEND, false) do poisson_blend(&E)
		shift_half(others_out[j].px, E.img, w, h, back = true)
	}
	sync.atomic_store(&synth_progress, 1)
	return
}
