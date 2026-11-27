package tileit

// Cropping, and repeat ("period") detection for regular textures.
//
// A brick wall only tiles cleanly if the tile holds a whole number of
// repeats in each direction; otherwise the seam has to join half a brick to a
// whole one and no amount of blending fixes that. So, before tiling, we
// measure the repeat from the autocorrelation of the image (computed with the
// FFT) and trim the tile to a whole number of repeats.
//
// Only the central part of the photo is used to measure it: the outer edges
// of a photo carry lens distortion, perspective and vignetting, so their
// spacing is less trustworthy. (Liu, Lin & Hays 2004, "Near-Regular Texture
// Analysis and Manipulation", use the same autocorrelation idea.)

import "core:fmt"
import "core:math"
import "core:slice"
_ :: fmt
_ :: slice

// Centre crop to at most cw × ch (no-op when the image is already smaller).
crop_center :: proc(img: Image, max_w, max_h: int) -> Image {
	cw, ch := min(max_w, img.w), min(max_h, img.h)
	return crop_rect(img, (img.w - cw) / 2, (img.h - ch) / 2, cw, ch)
}

// Bilinear resample to nw × nh (pixel-centre aligned). For the small scale
// changes of stretch-to-fit, bilinear keeps detail well enough; when
// shrinking, a quick box prefilter avoids aliasing.
resample :: proc(img: Image, nw, nh: int) -> Image {
	src := img
	pre: Image
	defer if pre.px != nil do image_destroy(&pre)
	if nw < img.w * 3 / 4 || nh < img.h * 3 / 4 {
		// Shrinking a lot: halve with a box filter first (repeat as needed).
		pre = image_clone(img)
		for pre.w / 2 >= nw && pre.h / 2 >= nh {
			half := image_like(pre, max(pre.w / 2, 1), max(pre.h / 2, 1))
			for y in 0 ..< half.h do for x in 0 ..< half.w do for c in 0 ..< 4 {
				s: f32
				for j in 0 ..< 2 do for i in 0 ..< 2 do s += pre.px[((2 * y + j) * pre.w + 2 * x + i) * 4 + c]
				half.px[(y * half.w + x) * 4 + c] = s * 0.25
			}
			image_destroy(&pre)
			pre = half
		}
		src = pre
	}
	out := image_like(img, nw, nh)
	sx, sy := f32(src.w) / f32(nw), f32(src.h) / f32(nh)
	for y in 0 ..< nh {
		fy := (f32(y) + 0.5) * sy - 0.5
		y0 := clamp(int(math.floor(fy)), 0, src.h - 1)
		y1 := min(y0 + 1, src.h - 1)
		ty := clamp(fy - f32(y0), 0, 1)
		for x in 0 ..< nw {
			fx := (f32(x) + 0.5) * sx - 0.5
			x0 := clamp(int(math.floor(fx)), 0, src.w - 1)
			x1 := min(x0 + 1, src.w - 1)
			tx := clamp(fx - f32(x0), 0, 1)
			o := out.px[(y * nw + x) * 4:][:4]
			for c in 0 ..< 4 {
				a := math.lerp(src.px[(y0 * src.w + x0) * 4 + c], src.px[(y0 * src.w + x1) * 4 + c], tx)
				b := math.lerp(src.px[(y1 * src.w + x0) * 4 + c], src.px[(y1 * src.w + x1) * 4 + c], tx)
				o[c] = math.lerp(a, b, ty)
			}
		}
	}
	return out
}

// Resize a tileable image to nw × nh and keep it tileable: separable bicubic
// (Catmull-Rom) with wrap-around sampling, so the left edge is filtered with
// the right edge as its neighbour, exactly as when tiled. When shrinking, the
// kernel is widened by the scale factor so fine detail is averaged instead of
// aliasing. Values are clamped (bicubic can overshoot a little).
resize_periodic :: proc(img: Image, nw, nh: int) -> Image {
	if nw == img.w && nh == img.h do return image_clone(img)
	cubic :: proc(t: f32) -> f32 { // Catmull-Rom
		x := abs(t)
		if x < 1 do return 1.5 * x * x * x - 2.5 * x * x + 1
		if x < 2 do return -0.5 * x * x * x + 2.5 * x * x - 4 * x + 2
		return 0
	}
	// 1D pass along one axis of a w×h RGBA buffer, from n_in to n_out samples.
	pass :: proc(src: []f32, w, h: int, horizontal: bool, n_out: int, cubic: proc(f32) -> f32) -> []f32 {
		n_in := horizontal ? w : h
		ow, oh := horizontal ? n_out : w, horizontal ? h : n_out
		dst := make([]f32, ow * oh * 4)
		scale := f32(n_in) / f32(n_out)
		support := 2 * max(scale, 1) // widen the kernel when shrinking
		for o in 0 ..< n_out {
			centre := (f32(o) + 0.5) * scale - 0.5
			i0 := int(centre - support) + 1
			i1 := int(centre + support)
			// Weights for this output sample.
			weights: [64]f32
			count := min(i1 - i0 + 1, 64)
			sum: f32
			for k in 0 ..< count {
				wt := cubic((f32(i0 + k) - centre) / max(scale, 1))
				weights[k] = wt
				sum += wt
			}
			for k in 0 ..< count do weights[k] /= sum
			lines := horizontal ? h : w
			for l in 0 ..< lines {
				acc: [4]f32
				for k in 0 ..< count {
					i := (i0 + k) %% n_in // wrap around: the image is periodic
					si := horizontal ? (l * w + i) * 4 : (i * w + l) * 4
					acc += weights[k] * [4]f32{src[si], src[si + 1], src[si + 2], src[si + 3]}
				}
				di := horizontal ? (l * ow + o) * 4 : (o * ow + l) * 4
				for c in 0 ..< 4 do dst[di + c] = acc[c]
			}
		}
		return dst
	}
	tmp := pass(img.px, img.w, img.h, true, nw, cubic)
	defer delete(tmp)
	out := image_like(img, nw, nh)
	delete(out.px)
	out.px = pass(tmp, nw, img.h, false, nh, cubic)
	for &v in out.px do v = clamp(v, 0, 1)
	return out
}

// Copy of the rectangle (x, y, w, h), clamped to the image.
crop_rect :: proc(img: Image, x, y, w, h: int) -> Image {
	x0, y0 := clamp(x, 0, img.w - 1), clamp(y, 0, img.h - 1)
	cw, ch := clamp(w, 1, img.w - x0), clamp(h, 1, img.h - y0)
	out := image_like(img, cw, ch)
	for r in 0 ..< ch {
		copy(out.px[r * cw * 4:][:cw * 4], img.px[((y0 + r) * img.w + x0) * 4:][:cw * 4])
	}
	return out
}

Repeat_Info :: struct {
	px, py:           f32,  // repeat length in pixels (valid if found_*)
	found_x, found_y: bool,
	strength_x, strength_y: f32, // normalised autocorrelation at the repeat (0..1)
}

// Measures the horizontal and vertical repeat of `img`, using only the
// central `center` fraction of it (e.g. 0.65 = middle 65% in each axis).
detect_repeat :: proc(img: Image, center: f32) -> (info: Repeat_Info) {
	c := clamp(center, 0.2, 1)
	rw, rh := max(int(f32(img.w) * c), 8), max(int(f32(img.h) * c), 8)
	x0, y0 := (img.w - rw) / 2, (img.h - rh) / 2

	// Work at a reduced size (<= 1024 on the long side) - plenty for finding
	// repeats, which are many pixels long - then refine with harmonics.
	s := max((max(rw, rh) + 1023) / 1024, 1)
	dw, dh := rw / s, rh / s
	if dw < 16 || dh < 16 do return
	lum := make([]f32, dw * dh)
	defer delete(lum)
	for y in 0 ..< dh {
		for x in 0 ..< dw {
			l: f32
			for j in 0 ..< s do for i in 0 ..< s {
				p := img.px[((y0 + y * s + j) * img.w + x0 + x * s + i) * 4:][:3]
				l += 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]
			}
			lum[y * dw + x] = l / f32(s * s)
		}
	}

	// Edge maps rather than brightness: brightness is dominated by the long
	// mortar lines, which look the same one course or two courses apart. The
	// vertical-edge map (joints) is what tells a half repeat from a full one,
	// and edges ignore lighting gradients. A full repeat must match both maps,
	// so the two autocorrelation profiles are averaged.
	// Edges at the scale of the structure, not of the surface grain (rough
	// brick faces would otherwise drown the mortar and joints): blur first.
	box_blur(lum, dw, dh, 3)
	box_blur(lum, dw, dh, 3)
	gx := make([]f32, dw * dh)
	gy := make([]f32, dw * dh)
	defer { delete(gx); delete(gy) }
	for y in 0 ..< dh {
		for x in 0 ..< dw {
			xl, xr := max(x - 1, 0), min(x + 1, dw - 1)
			yu, yd := max(y - 1, 0), min(y + 1, dh - 1)
			gx[y * dw + x] = abs(lum[y * dw + xr] - lum[y * dw + xl])
			gy[y * dw + x] = abs(lum[yd * dw + x] - lum[yu * dw + x])
		}
	}

	// Lags up to 3/4 of the region: a two-course brick repeat can be long,
	// and the overlap normalisation keeps long lags comparable.
	prof_x := make([]f32, dw * 3 / 4 + 2)
	prof_y := make([]f32, dh * 3 / 4 + 2)
	defer { delete(prof_x); delete(prof_y) }
	if !accumulate_autocorr(gx, dw, dh, prof_x, prof_y) do return
	if !accumulate_autocorr(gy, dw, dh, prof_x, prof_y) do return
	for &v in prof_x do v *= 0.5
	for &v in prof_y do v *= 0.5

	px, sx, okx := find_period(prof_x)
	py, sy, oky := find_period(prof_y)
	info.found_x, info.found_y = okx, oky
	info.px, info.py = px * f32(s), py * f32(s)
	info.strength_x, info.strength_y = sx, sy
	return
}

// In-place separable box blur with clamped edges.
@(private = "file")
box_blur :: proc(f: []f32, w, h, r: int) {
	tmp := make([]f32, max(w, h))
	defer delete(tmp)
	for y in 0 ..< h {
		row := f[y * w:][:w]
		for x in 0 ..< w {
			s: f32
			for d in -r ..= r do s += row[clamp(x + d, 0, w - 1)]
			tmp[x] = s / f32(2 * r + 1)
		}
		copy(row, tmp[:w])
	}
	for x in 0 ..< w {
		for y in 0 ..< h {
			s: f32
			for d in -r ..= r do s += f[clamp(y + d, 0, h - 1) * w + x]
			tmp[y] = s / f32(2 * r + 1)
		}
		for y in 0 ..< h do f[y * w + x] = tmp[y]
	}
}

// Adds the normalised autocorrelation of `f` along the x and y axes to the
// profiles (index = lag). Normalised by overlap, so long lags aren't
// penalised just for overlapping less, and by the zero-lag value, so a
// perfect repeat scores 1. Returns false for a flat feature map.
@(private = "file")
accumulate_autocorr :: proc(f: []f32, dw, dh: int, prof_x, prof_y: []f32) -> bool {
	// Zero-pad to twice the size so the FFT's circular correlation doesn't
	// wrap around.
	pw, ph := 2 * dw, 2 * dh
	buf := make([]complex64, pw * ph)
	defer delete(buf)
	mean: f64
	for v in f do mean += f64(v)
	mean /= f64(len(f))
	for y in 0 ..< dh do for x in 0 ..< dw do buf[y * pw + x] = complex(f[y * dw + x] - f32(mean), 0)

	row_plan := fft_plan_make(pw)
	col_plan := fft_plan_make(ph)
	defer { fft_plan_destroy(&row_plan); fft_plan_destroy(&col_plan) }
	fft2(buf, pw, ph, &row_plan, &col_plan)
	for &v in buf do v = complex(real(v) * real(v) + imag(v) * imag(v), 0) // power spectrum
	fft2(buf, pw, ph, &row_plan, &col_plan, inverse = true)                 // -> autocorrelation

	a0 := real(buf[0]) / f32(dw * dh)
	if a0 <= 1e-12 do return false
	for d in 0 ..< len(prof_x) do prof_x[d] += real(buf[d]) / f32((dw - d) * dh) / a0
	for d in 0 ..< len(prof_y) do prof_y[d] += real(buf[d * pw]) / f32(dw * (dh - d)) / a0
	return true
}

// Thresholds for accepting a repeat (profile values are normalised
// autocorrelations, averaged over the two edge maps).
MIN_PEAK       :: #config(TILEIT_MIN_PEAK, 0.25)
MIN_PROMINENCE :: #config(TILEIT_MIN_PROM, 0.15)

// Picks the repeat from an autocorrelation profile (index = lag).
@(private = "file")
find_period :: proc(a: []f32) -> (period: f32, strength: f32, ok: bool) {
	n := len(a) - 1 // last index usable as a neighbour
	if n <= 6 do return

	// Skip the central lobe around lag 0 (every image correlates with itself
	// when shifted by a pixel or two): start after its first dip.
	MIN_LAG := 2
	for MIN_LAG < n - 1 && a[MIN_LAG + 1] < a[MIN_LAG] do MIN_LAG += 1

	// A candidate must be a local maximum that rises clearly above the lowest
	// point between the lobe and itself.
	is_peak :: proc(a: []f32, i: int) -> bool { return a[i] >= a[i - 1] && a[i] >= a[i + 1] }
	prominent :: proc(a: []f32, from, i: int) -> bool {
		dip := a[from]
		for j in from ..= i do dip = min(dip, a[j])
		return a[i] - dip >= MIN_PROMINENCE
	}
	best := -1
	best_v: f32 = -1
	for i in MIN_LAG ..< n do if is_peak(a, i) && a[i] > best_v && prominent(a, MIN_LAG, i) { best_v = a[i]; best = i }
	when #config(TILEIT_TRACE, false) {
		fmt.printf("  profile peaks (lag: value):")
		shown := 0
		for i in MIN_LAG ..< n do if is_peak(a, i) && a[i] > 0.5 * best_v && shown < 12 { fmt.printf(" %d: %.3f", i, a[i]); shown += 1 }
		fmt.printfln("  | min %.3f", slice.min(a[MIN_LAG:]))
	}
	if best < 0 || best_v < MIN_PEAK do return

	// Prefer the shortest lag that is nearly as strong as the strongest one:
	// harmonics (2P, 3P) score about as high as P, while a half-repeat (a
	// brick course offset by half a brick) scores clearly lower.
	chosen := best
	for i in MIN_LAG ..< best {
		if is_peak(a, i) && a[i] >= 0.9 * best_v && prominent(a, MIN_LAG, i) {
			chosen = i
			break
		}
	}

	p := refine_peak(a, chosen)

	// A partial repeat still correlates well: one course of a wall whose
	// courses alternate, or half a brick in running bond, because the
	// mortar lines dominate. The full repeat then correlates *better* at a
	// multiple. Take the smallest multiple that is (nearly) the best.
	{
		vals: [5]f32
		lags: [5]f32
		vals[1], lags[1] = a[chosen], p
		vmax := vals[1]
		for k in 2 ..= 4 {
			centre := int(math.round(p * f32(k)))
			half := max(int(p / 6), 1)
			lo, hi := max(centre - half, 1), min(centre + half, n - 1)
			if lo >= hi || centre >= n do break
			m := lo
			for i in lo ..= hi do if a[i] > a[m] do m = i
			if m == lo || m == hi do continue // edge of window: not a peak
			vals[k], lags[k] = a[m], refine_peak(a, m)
			vmax = max(vmax, vals[k])
		}
		MARGIN :: 0.03
		when #config(TILEIT_TRACE, false) {
			fmt.printfln("  repeat candidates: P=%.1f  multiples (k: lag, value): 1: %.1f %.3f | 2: %.1f %.3f | 3: %.1f %.3f | 4: %.1f %.3f",
				p, lags[1], vals[1], lags[2], vals[2], lags[3], vals[3], lags[4], vals[4])
		}
		if vmax > vals[1] + MARGIN {
			for k in 2 ..= 4 {
				if vals[k] >= vmax - MARGIN {
					chosen = int(math.round(lags[k]))
					p = lags[k]
					break
				}
			}
		}
	}

	// A true repeat comes back at twice its length too. Irregular stonework
	// has a typical course height, but the second course over no longer
	// lines up - that's not a lattice to fit to. When 2P is within view, it
	// must correlate at least half as well as P.
	{
		c2 := int(math.round(2 * p))
		half := max(int(p / 6), 1)
		if c2 + half < n {
			lo, hi := max(c2 - half, 1), min(c2 + half, n - 1)
			m := lo
			for i in lo ..= hi do if a[i] > a[m] do m = i
			v2: f32 = (m > lo && m < hi) ? a[m] : 0 // must be a real peak
			when #config(TILEIT_TRACE, false) {
				fmt.printfln("  harmonic check: P=%.1f value %.3f, 2P value %.3f", p, a[chosen], v2)
			}
			if v2 < 0.5 * a[chosen] do return
		}
	}

	// Use the furthest harmonic we can still see for precision: P = lag_k / k.
	k := int(f32(n) / p)
	for ; k >= 2; k -= 1 {
		centre := int(math.round(p * f32(k)))
		half := max(int(p / 4), 1)
		lo, hi := max(centre - half, 1), min(centre + half, n - 1)
		if lo >= hi do continue
		m := lo
		for i in lo ..= hi do if a[i] > a[m] do m = i
		if a[m] >= 0.7 * a[chosen] && m > lo && m < hi {
			p = refine_peak(a, m) / f32(k)
			break
		}
	}
	return p, a[chosen], true
}

// Sub-pixel peak position by fitting a parabola through three samples.
@(private = "file")
refine_peak :: proc(a: []f32, i: int) -> f32 {
	l, c, r := a[i - 1], a[i], a[i + 1]
	den := l - 2 * c + r
	if abs(den) < 1e-9 do return f32(i)
	return f32(i) + clamp(0.5 * (l - r) / den, -0.5, 0.5)
}

// Largest size ≤ n that holds a whole number of repeats of length p.
whole_repeats :: proc(n: int, p: f32) -> int {
	if p <= 0 do return n
	k := int(f32(n) / p)
	if k < 1 do return n
	return clamp(int(math.round(f32(k) * p)), 1, n)
}

// ---------------------------------------------------------------------------
// Straightening: a wall photographed slightly rotated has no clean horizontal
// repeat, so its seams can't line up. Edge directions (gradient angles,
// folded modulo 90 degrees so horizontal and vertical edges agree) pile up at
// the tilt; we measure that peak and rotate it out.

TILT_MIN_PEAK :: #config(TILEIT_TILT_PEAK, 1.8)

// Tilt in radians (content rotated clockwise on screen is positive), and
// whether the evidence is clear. Textures without dominant straight edges
// (sand, grass) report found = false.
detect_tilt :: proc(img: Image, center: f32) -> (angle: f32, found: bool) {
	c := clamp(center, 0.2, 1)
	rw, rh := max(int(f32(img.w) * c), 8), max(int(f32(img.h) * c), 8)
	x0, y0 := (img.w - rw) / 2, (img.h - rh) / 2
	s := max((max(rw, rh) + 511) / 512, 1)
	dw, dh := rw / s, rh / s
	if dw < 32 || dh < 32 do return
	lum := make([]f32, dw * dh)
	defer delete(lum)
	for y in 0 ..< dh do for x in 0 ..< dw {
		l: f32
		for j in 0 ..< s do for i in 0 ..< s {
			p := img.px[((y0 + y * s + j) * img.w + x0 + x * s + i) * 4:][:3]
			l += 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]
		}
		lum[y * dw + x] = l / f32(s * s)
	}
	box_blur(lum, dw, dh, 1)

	// Edge maps: eh responds to horizontal lines (mortar), ev to vertical ones
	// (joints, plank edges).
	eh := make([]f32, dw * dh)
	ev := make([]f32, dw * dh)
	defer { delete(eh); delete(ev) }
	BINS :: 360 // gate: 0.25 degree bins of edge direction over 90 degrees
	hist: [BINS]f64
	for y in 1 ..< dh - 1 do for x in 1 ..< dw - 1 {
		gx := lum[y * dw + x + 1] - lum[y * dw + x - 1]
		gy := lum[(y + 1) * dw + x] - lum[(y - 1) * dw + x]
		eh[y * dw + x] = abs(gy)
		ev[y * dw + x] = abs(gx)
		m := gx * gx + gy * gy
		if m < 1e-8 do continue
		a := math.atan2(gy, gx) * 180 / math.PI
		a = a - 90 * math.floor(a / 90)
		hist[min(int(a * BINS / 90), BINS - 1)] += f64(m)
	}

	// Gate: do straight edges dominate at all? (Sand and grass don't.)
	sm: [BINS]f64
	for i in 0 ..< BINS {
		for d in -6 ..= 6 do sm[i] += hist[(i + d + BINS) % BINS] * math.exp(-f64(d * d) / 8)
	}
	peak := 0
	total: f64
	for v, i in sm { total += v; if v > sm[peak] do peak = i }
	mean := total / BINS
	when #config(TILEIT_TRACE, false) {
		fmt.printfln("  tilt gate: edge-direction peak/mean %.2f", mean > 0 ? sm[peak] / mean : 0)
	}
	if mean <= 0 || sm[peak] < TILT_MIN_PEAK * mean do return

	// Angle: project the edge maps along candidate angles; at the true tilt
	// the lines stack up and the projection is sharpest (highest variance).
	// Each family is normalised by its own score range so neither dominates.
	MAX_DEG :: 15.0
	score :: proc(e: []f32, dw, dh: int, theta: f64, horizontal: bool) -> f64 {
		cs, sn := math.cos(theta), math.sin(theta)
		n := dw + dh + 2
		prof := make([]f64, n, context.temp_allocator)
		cnt := make([]f64, n, context.temp_allocator)
		cx, cy := f64(dw) / 2, f64(dh) / 2
		for y in 1 ..< dh - 1 do for x in 1 ..< dw - 1 {
			fx, fy := f64(x) - cx, f64(y) - cy
			t := horizontal ? -fx * sn + fy * cs : fx * cs + fy * sn
			k := int(t + f64(n) / 2)
			if k < 0 || k >= n do continue
			prof[k] += f64(e[y * dw + x])
			cnt[k] += 1
		}
		mu, m2, used: f64
		for i in 0 ..< n do if cnt[i] > f64(min(dw, dh)) / 4 {
			v := prof[i] / cnt[i]
			mu += v; m2 += v * v; used += 1
		}
		if used < 2 do return 0
		mu /= used
		return m2 / used - mu * mu
	}
	best_theta := 0.0
	{
		coarse: [61]f64 // -15 .. 15 degrees in 0.5 degree steps
		lo_h, hi_h, lo_v, hi_v := max(f64), 0.0, max(f64), 0.0
		sh, sv: [61]f64
		for i in 0 ..< 61 {
			th := (f64(i) * 0.5 - MAX_DEG) * math.PI / 180
			sh[i] = score(eh, dw, dh, th, true)
			sv[i] = score(ev, dw, dh, th, false)
			lo_h, hi_h = min(lo_h, sh[i]), max(hi_h, sh[i])
			lo_v, hi_v = min(lo_v, sv[i]), max(hi_v, sv[i])
		}
		norm :: proc(v, lo, hi: f64) -> f64 { return hi > lo ? (v - lo) / (hi - lo) : 0 }
		bi := 0
		for i in 0 ..< 61 {
			coarse[i] = norm(sh[i], lo_h, hi_h) + norm(sv[i], lo_v, hi_v)
			if coarse[i] > coarse[bi] do bi = i
		}
		// Refine around the coarse best in 0.05 degree steps.
		centre := f64(bi) * 0.5 - MAX_DEG
		best := -1.0
		for k in -10 ..= 10 {
			deg := centre + f64(k) * 0.05
			th := deg * math.PI / 180
			v := norm(score(eh, dw, dh, th, true), lo_h, hi_h) + norm(score(ev, dw, dh, th, false), lo_v, hi_v)
			if v > best { best = v; best_theta = th }
		}
		free_all(context.temp_allocator)
	}
	when #config(TILEIT_TRACE, false) {
		fmt.printfln("  tilt: %.2f deg", best_theta * 180 / math.PI)
	}
	return f32(best_theta), true
}

// Rotates the content by -angle (undoing a tilt of `angle`) about the centre
// and crops to the largest centred axis-aligned rectangle that stays inside
// the photo. For normal maps (normal_y_up tells the green convention) the
// stored vectors are rotated as well.
straighten :: proc(img: Image, angle: f32, is_normal := false, normal_y_up := true) -> Image {
	ca, sa := math.cos(angle), math.sin(abs(angle))
	nw := int(f32(img.w) * ca - f32(img.h) * sa)
	nh := int(f32(img.h) * ca - f32(img.w) * sa)
	nw, nh = max(nw, 16), max(nh, 16)
	out := image_like(img, nw, nh)
	cs, sn := math.cos(angle), math.sin(angle)
	icx, icy := f32(img.w) / 2, f32(img.h) / 2
	ocx, ocy := f32(nw) / 2, f32(nh) / 2
	for y in 0 ..< nh {
		for x in 0 ..< nw {
			dx, dy := f32(x) + 0.5 - ocx, f32(y) + 0.5 - ocy
			// Source position: the output grid rotated by +angle.
			sx := cs * dx - sn * dy + icx - 0.5
			sy := sn * dx + cs * dy + icy - 0.5
			x0 := clamp(int(math.floor(sx)), 0, img.w - 1)
			y0 := clamp(int(math.floor(sy)), 0, img.h - 1)
			x1, y1 := min(x0 + 1, img.w - 1), min(y0 + 1, img.h - 1)
			tx, ty := clamp(sx - f32(x0), 0, 1), clamp(sy - f32(y0), 0, 1)
			o := out.px[(y * nw + x) * 4:][:4]
			for c in 0 ..< 4 {
				a := math.lerp(img.px[(y0 * img.w + x0) * 4 + c], img.px[(y0 * img.w + x1) * 4 + c], tx)
				b := math.lerp(img.px[(y1 * img.w + x0) * 4 + c], img.px[(y1 * img.w + x1) * 4 + c], tx)
				o[c] = math.lerp(a, b, ty)
			}
			if is_normal {
				// Vector in image coordinates (y down), rotated by -angle.
				vx := o[0] * 2 - 1
				vy := o[1] * 2 - 1
				if normal_y_up do vy = -vy
				rx := cs * vx + sn * vy
				ry := -sn * vx + cs * vy
				if normal_y_up do ry = -ry
				o[0], o[1] = rx * 0.5 + 0.5, ry * 0.5 + 0.5
			}
		}
	}
	return out
}

// Hidden test helper: rotate an image by `deg` degrees (crop to inside).
rotate_for_test :: proc(img: Image, deg: f32) -> Image {
	return straighten(img, -deg * math.PI / 180)
}
