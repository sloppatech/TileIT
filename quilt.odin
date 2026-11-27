package tileit

// Repeat quilting: seams for regular textures, from the real continuation.
//
// Once the tile holds whole repeats (W = k·Px), the photo itself shows what
// must come after the tile's right edge: the pixels just past it, which are
// one tile-width further along the same wall. Near the tile's left edge we
// switch over to that continuation, along the cut that differs least between
// the two (Efros & Freeman 2001, "Image Quilting": minimum-error boundary cut,
// found by dynamic programming). Every output pixel is copied from exactly
// one place in the photo - nothing is averaged, so joints can't come out
// doubled ("ghosts") - and a screened Poisson pass evens out the slight tone
// difference across the cut. Same for the top/bottom seam, computed on rows
// that already have the left/right cut applied, so the corner is consistent.
//
// The result is a source map (tile pixel -> photo pixel) that every map of a
// material set is resampled through, keeping them aligned.

Quilt_Plan :: struct {
	w, h:     int,    // tile size
	src:      []i32,  // per tile pixel: pixel index in the full image
	band:     []bool, // per tile pixel: in a seam band (Poisson-blended)
	quilted:  [2]bool,
	img_w:    int,    // full image width (to decode src)
}

quilt_plan_destroy :: proc(q: ^Quilt_Plan) {
	delete(q.src); delete(q.band)
	q^ = {}
}

// Band width for the cut search: a good part of a repeat, so the cut can find
// a path through brick faces instead of across joints.
@(private = "file")
quilt_band :: proc(period: f32, tile: int) -> int {
	return clamp(int(period * 0.2), 16, max(tile / 3, 16))
}

@(private = "file")
diff2 :: #force_inline proc "contextless" (img: Image, a, b: int) -> f32 {
	p := img.px[a * 4:][:3]
	q := img.px[b * 4:][:3]
	d0, d1, d2 := p[0] - q[0], p[1] - q[1], p[2] - q[2]
	return d0 * d0 + d1 * d1 + d2 * d2
}

// Minimum-error path through cost[i][j] (i = step along the seam, j = 0..n-1
// position across it), moving at most one position per step. Returns the
// position per step.
@(private = "file")
min_cut :: proc(cost: []f32, steps, n: int) -> []int {
	acc := make([]f32, steps * n)
	defer delete(acc)
	copy(acc[:n], cost[:n])
	for i in 1 ..< steps {
		for j in 0 ..< n {
			best := acc[(i - 1) * n + j]
			if j > 0 do best = min(best, acc[(i - 1) * n + j - 1])
			if j < n - 1 do best = min(best, acc[(i - 1) * n + j + 1])
			acc[i * n + j] = cost[i * n + j] + best
		}
	}
	path := make([]int, steps)
	j := 0
	for k in 1 ..< n do if acc[(steps - 1) * n + k] < acc[(steps - 1) * n + j] do j = k
	path[steps - 1] = j
	for i := steps - 2; i >= 0; i -= 1 {
		bj := j
		for k in max(j - 1, 0) ..= min(j + 1, n - 1) do if acc[i * n + k] < acc[i * n + bj] do bj = k
		j = bj
		path[i] = j
	}
	return path
}

// Plans the cuts for a tile at (tx, ty) of size W x H inside `guide`. axes:
// which seams to quilt (those with a known repeat). An axis is only quilted
// when the photo has room for the continuation on one side.
quilt_plan :: proc(guide: Image, tx, ty, W, H: int, axes: [2]bool, period: [2]f32) -> (q: Quilt_Plan) {
	q.w, q.h, q.img_w = W, H, guide.w
	q.src = make([]i32, W * H)
	q.band = make([]bool, W * H)
	iw, ih := guide.w, guide.h

	// Per axis: band width and which side the continuation comes from.
	// +1: continuation lies past the far edge (right/bottom), cut near x=0.
	// -1: continuation lies before the near edge (left/top), cut near x=W.
	bx, by := 0, 0
	sx, sy := 0, 0
	// A narrower band than ideal still beats no quilting, down to MIN_BAND.
	MIN_BAND :: 24
	pick :: proc(ideal, before, after: int) -> (band, side: int) {
		if after >= ideal do return ideal, 1
		if before >= ideal do return ideal, -1
		room := max(before, after)
		if room < MIN_BAND do return 0, 0
		return room, after >= before ? 1 : -1
	}
	if axes.x do bx, sx = pick(quilt_band(period.x, W), tx, iw - (tx + W))
	if axes.y do by, sy = pick(quilt_band(period.y, H), ty, ih - (ty + H))
	q.quilted = {sx != 0, sy != 0}

	// Rows the left/right cut is needed for: the tile's rows plus the
	// continuation rows the top/bottom cut will read.
	r0, r1 := ty, ty + H
	if sy > 0 do r1 = ty + H + by
	if sy < 0 do r0 = ty - by
	nr := r1 - r0

	// srcx[r][x]: source column for tile column x on absolute row r0 + r.
	srcx := make([]i32, nr * W)
	defer delete(srcx)
	for r in 0 ..< nr do for x in 0 ..< W do srcx[r * W + x] = i32(tx + x)
	if sx != 0 {
		// Band columns: sx > 0: x in [0, bx), alternative = column + W.
		//               sx < 0: x in [W-bx, W), alternative = column - W.
		// Cut position j in [1, bx-1]: the first j band columns (counted from
		// the tile edge) take the alternative; the edge column always does.
		n := bx - 1
		cost := make([]f32, nr * n)
		defer delete(cost)
		for r in 0 ..< nr {
			y := r0 + r
			for j in 0 ..< n {
				// Cost of switching between band column j and j+1 (from edge):
				// how much the two sources differ there.
				e: f32
				for k in j ..= j + 1 {
					x := sx > 0 ? k : W - 1 - k
					a := y * iw + tx + x
					b := a + (sx > 0 ? W : -W)
					e += diff2(guide, a, b)
				}
				cost[r * n + j] = e
			}
		}
		path := min_cut(cost, nr, n)
		defer delete(path)
		for r in 0 ..< nr {
			cut := path[r] + 1 // columns [0, cut) from the edge use the alternative
			for k in 0 ..< cut {
				x := sx > 0 ? k : W - 1 - k
				srcx[r * W + x] = i32(tx + x + (sx > 0 ? W : -W))
			}
		}
	}

	// Composite reader: pixel index for tile column x on absolute row y.
	at :: #force_inline proc(srcx: []i32, W, r0, iw, x, y: int) -> int {
		return y * iw + int(srcx[(y - r0) * W + x])
	}

	// Row choice per tile pixel (absolute row), default the tile's own row.
	rowsel := make([]i32, W * H)
	defer delete(rowsel)
	for y in 0 ..< H do for x in 0 ..< W do rowsel[y * W + x] = i32(ty + y)
	if sy != 0 {
		n := by - 1
		cost := make([]f32, W * n)
		defer delete(cost)
		for x in 0 ..< W {
			for j in 0 ..< n {
				e: f32
				for k in j ..= j + 1 {
					y := sy > 0 ? k : H - 1 - k
					a := at(srcx, W, r0, iw, x, ty + y)
					b := at(srcx, W, r0, iw, x, ty + y + (sy > 0 ? H : -H))
					e += diff2(guide, a, b)
				}
				cost[x * n + j] = e
			}
		}
		path := min_cut(cost, W, n)
		defer delete(path)
		for x in 0 ..< W {
			cut := path[x] + 1
			for k in 0 ..< cut {
				y := sy > 0 ? k : H - 1 - k
				rowsel[y * W + x] = i32(ty + y + (sy > 0 ? H : -H))
			}
		}
	}

	for y in 0 ..< H {
		for x in 0 ..< W {
			r := int(rowsel[y * W + x])
			q.src[y * W + x] = i32(at(srcx, W, r0, iw, x, r))
			inx := sx > 0 ? x < bx : sx < 0 ? x >= W - bx : false
			iny := sy > 0 ? y < by : sy < 0 ? y >= H - by : false
			q.band[y * W + x] = inx || iny
		}
	}
	return
}

// Builds the tile for one map through the plan, then blends the bands.
quilt_apply :: proc(full: Image, q: Quilt_Plan) -> Image {
	out := image_like(full, q.w, q.h)
	for i in 0 ..< q.w * q.h {
		s := int(q.src[i])
		copy(out.px[i * 4:][:4], full.px[s * 4:][:4])
	}
	quilt_blend(full, q, &out)
	return out
}

// Screened Poisson over the band pixels: gradients from the photo at each
// pixel's source (averaged with the neighbour's), pinned by the pixels
// outside the bands, gently pulled towards the copied values. Removes tone
// steps along the cuts without moving any edge.
@(private = "file")
quilt_blend :: proc(full: Image, q: Quilt_Plan, tile: ^Image) {
	cells: [dynamic]i32
	defer delete(cells)
	for b, i in q.band do if b do append(&cells, i32(i))
	if len(cells) == 0 do return
	G := grid_make(q.w, q.h, cells[:], BLEND_SCREEN)
	defer grid_destroy(&G)
	n := len(cells)
	bufs := make([][4]f32, 2 * n)
	defer delete(bufs)
	B, X := bufs[:n], bufs[n:]

	fw := full.w
	fpx :: #force_inline proc(img: Image, x, y: int) -> [4]f32 {
		i := (clamp(y, 0, img.h - 1) * img.w + clamp(x, 0, img.w - 1)) * 4
		return {img.px[i], img.px[i + 1], img.px[i + 2], img.px[i + 3]}
	}
	for c, i in cells {
		p := int(c)
		x, y := p % q.w, p / q.w
		s := int(q.src[p])
		sx, sy := s % fw, s / fw
		v := fpx(full, sx, sy)
		b := G.screen * v
		for d in ([4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
			nx, ny := (x + d.x + q.w) % q.w, (y + d.y + q.h) % q.h
			np := ny * q.w + nx
			// Desired f(p) - f(n): from p's source, averaged with n's source.
			g := v - fpx(full, sx + d.x, sy + d.y)
			ns := int(q.src[np])
			nsx, nsy := ns % fw, ns / fw
			g = 0.5 * (g + fpx(full, nsx - d.x, nsy - d.y) - fpx(full, nsx, nsy))
			if G.idx[np] < 0 {
				t := tile.px[np * 4:][:4]
				b += [4]f32{t[0], t[1], t[2], t[3]} // pinned neighbour
			}
			b += g
		}
		B[i] = b
		X[i] = v
	}
	poisson_solve(&G, X, B)
	for c, i in cells {
		o := tile.px[int(c) * 4:][:4]
		for k in 0 ..< 4 do o[k] = clamp(X[i][k], 0, 1) // blending can overshoot slightly
	}
}
