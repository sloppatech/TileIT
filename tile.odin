package tileit

// "Quick" tiling mode:
//   1. Periodic-plus-smooth decomposition (Moisan, "Periodic plus Smooth Image
//      Decomposition", JMIV 2011). u = p + s, where s is the smooth image that
//      carries all the wrap-around edge discontinuity. Output p tiles seamlessly.
//   2. Optional lighting flatten: subtract a broad Gaussian low-pass of p.
//      p is periodic, so a periodic (FFT) convolution is exactly right here.
// Both steps are one multiply in the frequency domain, so the whole thing is
// 2 forward + 1 inverse 2D FFT per pair of channels.

import "core:math"
import "core:strings"
import stbi "vendor:stb/image"

Image :: struct {
	w, h:     int,
	px:       []f32, // RGBA interleaved, 0..1 (always 4 channels in memory)
	channels: int,   // channel count of the source file (1..4); used when saving
	bits16:   bool,  // source was 16 bits per channel; saved as 16-bit PNG
}

Mode :: enum {
	Quick, // periodic-plus-smooth only: instant, great for noise-like textures
	Synth, // Quick, then rebuild a band around the seams from real texture patches
}

// Size of the saved tile. Fitting to whole repeats or straightening changes
// the size; this puts it back (or to a standard size) as the very last step,
// with a wrap-around resize so the tile stays seamless.
Out_Size :: enum {
	Fitted, // whatever the fit produced (e.g. 1532x1643)
	Input,  // same as the selection, or the whole photo (e.g. 2048x2048)
	S1K,    // 1024x1024
	S2K,    // 2048x2048
	S4K,    // 4096x4096
}

Tile_Params :: struct {
	out_size:      Out_Size,
	mode:          Mode,
	flatten:       f32, // 0 = off, 1 = remove all low-frequency lighting
	flatten_scale: f32, // Gaussian sigma as a fraction of the shorter side (flatten + even)
	even:          f32, // 0..1: even out local contrast (stationarity), colour maps only
	band:          f32, // Synth: half-width of the rebuilt band, fraction of the shorter side
	seed:          u32, // Synth: different seeds give different fills
	crop:          int,    // centre-crop to at most crop × crop first (0 = off), e.g. 2048
	region:        [4]int, // x, y, w, h of the part of the input to use (w = 0: whole image); overrides crop
	fit_repeat:    bool, // detect a regular repeat (bricks, tiles) and trim to whole repeats
	stretch:       bool, // fit_repeat: rescale slightly to whole repeats instead of cropping
	straighten:    bool, // detect a slight tilt (0.3-15 degrees) and rotate it out
	center:        f32, // trusted central fraction: repeat is measured there, Synth copies from there
}

DEFAULT_PARAMS :: Tile_Params {
	mode = .Synth, flatten = 0, flatten_scale = 0.15, band = 0.06, seed = 1, out_size = .Input,
	crop = 0, fit_repeat = true, center = 0.65, straighten = true,
}
image_make :: proc(w, h: int, channels := 4) -> Image { return {w, h, make([]f32, w * h * 4), channels, false} }

// New w × h image with the same file format (channels, bit depth) as `like`.
image_like :: proc(like: Image, w, h: int) -> Image {
	out := image_make(w, h, like.channels)
	out.bits16 = like.bits16
	return out
}

image_clone :: proc(img: Image) -> Image {
	out := image_like(img, img.w, img.h)
	copy(out.px, img.px)
	return out
}
image_destroy :: proc(img: ^Image) { delete(img.px); img^ = {} }

// Why the last image_load failed (stb's reason), for error messages.
load_error: string

image_load :: proc(path: string) -> (img: Image, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	x, y, ch: i32
	defer if !ok do load_error = string(stbi.failure_reason())
	if stbi.is_16_bit(cpath) {
		data := stbi.load_16(cpath, &x, &y, &ch, 4)
		if data == nil do return
		defer stbi.image_free(data)
		img = image_make(int(x), int(y), int(ch))
		img.bits16 = true
		for i in 0 ..< len(img.px) do img.px[i] = f32(data[i]) / 65535
	} else {
		data := stbi.load(cpath, &x, &y, &ch, 4)
		if data == nil {
			// stb can't read it (inside tileit that includes every JPEG, see
			// winimage.odin): let the operating system decode it.
			reason := string(stbi.failure_reason())
			if sys, sys_ok := os_image_load(path); sys_ok do return sys, true
			load_error = reason
			ok = false
			return
		}
		defer stbi.image_free(data)
		img = image_make(int(x), int(y), int(ch))
		for i in 0 ..< len(img.px) do img.px[i] = f32(data[i]) / 255
	}
	return img, true
}

image_to_rgba8 :: proc(img: Image, allocator := context.allocator) -> []u8 {
	out := make([]u8, len(img.px), allocator)
	for v, i in img.px do out[i] = u8(clamp(v, 0, 1) * 255 + 0.5)
	return out
}

// Writes with the source's channel count, so a greyscale roughness map stays
// greyscale and an RGB albedo doesn't gain an alpha channel.
image_save_png :: proc(img: Image, path: string) -> bool {
	if img.bits16 do return png16_write(img, path)
	comp := clamp(img.channels, 1, 4)
	n := img.w * img.h
	bytes := make([]u8, n * comp)
	defer delete(bytes)
	to8 :: #force_inline proc(v: f32) -> u8 { return u8(clamp(v, 0, 1) * 255 + 0.5) }
	for i in 0 ..< n {
		s := img.px[i * 4:][:4]
		switch comp {
		case 1: bytes[i] = to8(s[0])
		case 2: bytes[i * 2] = to8(s[0]); bytes[i * 2 + 1] = to8(s[3]) // grey + alpha
		case:   for c in 0 ..< comp do bytes[i * comp + c] = to8(s[c])
		}
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	return stbi.write_png(cpath, i32(img.w), i32(img.h), i32(comp), raw_data(bytes), i32(img.w * comp)) != 0
}

// ---------------------------------------------------------------------------

// How a colour map is represented while it is made periodic:
//   l   = ln(luminance + eps)       brightness, in log space: a photo is
//                                   albedo x lighting, so lighting becomes an
//                                   additive low-frequency term that P+S and
//                                   the flatten filter can remove (including
//                                   the contrast change it causes);
//   r_k = C_k / (luminance + eps)   colour as a ratio to brightness, linear.
// Doing colour in log space per channel instead (an earlier version) blew up
// corrections in dark channels - the blue of a red brick is ~0.15 - and
// tinted mortar near the seams. Ratios are bounded, so the colour correction
// stays as small as the actual colour jump across the edge.
LUMA_EPS :: 0.02

@(private)
luma :: #force_inline proc "contextless" (p: []f32) -> f32 {
	return 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]
}

// colour: true for colour (albedo) maps; false for data maps such as normal,
// roughness or height, which are processed per channel, linearly, with no
// flatten.
make_tileable :: proc(src: Image, params: Tile_Params, colour := true) -> Image {
	w, h := src.w, src.h
	n := w * h
	out := image_like(src, w, h)

	// Planar working channels. Colour: ratios R,G,B, alpha, then log-luminance
	// last, so it gets an FFT pass of its own (it is the only one flattened).
	nch := colour ? 5 : 4
	planes := make([][]f32, nch)
	backing := make([]f32, n * nch)
	defer { delete(planes); delete(backing) }
	for c in 0 ..< nch do planes[c] = backing[c * n:][:n]
	for i in 0 ..< n {
		p := src.px[i * 4:][:4]
		if colour {
			y := max(luma(p[:3]), 0) + LUMA_EPS // inputs may be slightly out of range
			planes[0][i] = p[0] / y
			planes[1][i] = p[1] / y
			planes[2][i] = p[2] / y
			planes[3][i] = p[3]
			planes[4][i] = math.ln(y)
		} else {
			for c in 0 ..< 4 do planes[c][i] = p[c]
		}
	}

	flatten_mask := make([]bool, nch)
	defer delete(flatten_mask)
	if colour do flatten_mask[4] = params.flatten > 0
	periodic_plus_smooth(planes, w, h, flatten_mask, params)
	if colour && params.even > 0 do even_contrast(planes[4], w, h, params)

	for i in 0 ..< n {
		o := out.px[i * 4:][:4]
		if colour {
			y := math.exp(planes[4][i])
			o[0] = planes[0][i] * y
			o[1] = planes[1][i] * y
			o[2] = planes[2][i] * y
			o[3] = planes[3][i]
		} else {
			for c in 0 ..< 4 do o[c] = planes[c][i]
		}
	}
	for &v in out.px do v = clamp(v, 0, 1)
	return out
}

// Stationarity, the practical version of Moritz et al. 2017 ("Texture
// Stationarization", local histogram matching): a photo has patches that
// are washed out or extra contrasty, and once tiled those repeat as visible
// blotches. On the (already periodic) log-luminance l, measure the local
// mean m and spread v with a broad Gaussian, and scale each area's detail
// towards the image-wide spread: l' = m + (l - m) * (v_global / v)^(even / 2).
even_contrast :: proc(l: []f32, w, h: int, params: Tile_Params) {
	n := w * h
	m := make([]f32, n)
	m2 := make([]f32, n)
	defer { delete(m); delete(m2) }
	for v, i in l { m[i] = v; m2[i] = v * v }
	sigma := f64(max(params.flatten_scale, 0.02)) * f64(min(w, h))
	blur_periodic_pair(m, m2, w, h, sigma)
	vg: f64
	for i in 0 ..< n do vg += f64(max(m2[i] - m[i] * m[i], 1e-6))
	vg /= f64(n)
	e := 0.5 * f64(clamp(params.even, 0, 1))
	for i in 0 ..< n {
		v := f64(max(m2[i] - m[i] * m[i], 1e-6))
		g := f32(clamp(math.pow(vg / v, e), 0.25, 4))
		l[i] = m[i] + (l[i] - m[i]) * g
	}
}

// Gaussian blur (std dev sigma, in pixels) of two planes at once, with
// wrap-around: exact for periodic images, via one complex FFT.
blur_periodic_pair :: proc(a, b: []f32, w, h: int, sigma: f64) {
	n := w * h
	U := make([]complex64, n)
	defer delete(U)
	for i in 0 ..< n do U[i] = complex(a[i], b[i])
	row_plan := fft_plan_make(w)
	col_plan := fft_plan_make(h)
	defer { fft_plan_destroy(&row_plan); fft_plan_destroy(&col_plan) }
	fft2(U, w, h, &row_plan, &col_plan)
	for r in 0 ..< h {
		fy := f64(r <= h / 2 ? r : r - h) / f64(h)
		gy := math.exp(-2 * math.PI * math.PI * sigma * sigma * fy * fy)
		for q in 0 ..< w {
			fx := f64(q <= w / 2 ? q : q - w) / f64(w)
			g := f32(gy * math.exp(-2 * math.PI * math.PI * sigma * sigma * fx * fx))
			U[r * w + q] *= complex(g, 0)
		}
	}
	fft2(U, w, h, &row_plan, &col_plan, inverse = true)
	for i in 0 ..< n { a[i] = real(U[i]); b[i] = imag(U[i]) }
}

// In place: replaces each plane by its periodic component (Moisan's
// periodic-plus-smooth decomposition), and for planes in flatten_mask also
// removes a broad Gaussian low-pass (strength params.flatten, size
// params.flatten_scale). Two real planes are packed into one complex FFT;
// all frequency-domain multipliers are real, so they never mix.
periodic_plus_smooth :: proc(planes: [][]f32, w, h: int, flatten_mask: []bool, params: Tile_Params) {
	n := w * h
	row_plan := fft_plan_make(w)
	col_plan := fft_plan_make(h)
	defer { fft_plan_destroy(&row_plan); fft_plan_destroy(&col_plan) }

	U := make([]complex64, n)
	V := make([]complex64, n)
	defer { delete(U); delete(V) }

	// Frequency-domain multipliers depend only on (q, r); precompute 1D parts.
	cos_x := make([]f32, w)
	cos_y := make([]f32, h)
	gx := make([]f32, w)
	gy := make([]f32, h)
	defer { delete(cos_x); delete(cos_y); delete(gx); delete(gy) }
	sigma := f64(max(params.flatten_scale, 0.001)) * f64(min(w, h))
	for q in 0 ..< w {
		cos_x[q] = f32(2 * math.cos(2 * math.PI * f64(q) / f64(w)))
		f := f64(q <= w / 2 ? q : q - w) / f64(w)
		gx[q] = f32(math.exp(-2 * math.PI * math.PI * sigma * sigma * f * f))
	}
	for r in 0 ..< h {
		cos_y[r] = f32(2 * math.cos(2 * math.PI * f64(r) / f64(h)))
		f := f64(r <= h / 2 ? r : r - h) / f64(h)
		gy[r] = f32(math.exp(-2 * math.PI * math.PI * sigma * sigma * f * f))
	}

	for c0 := 0; c0 < len(planes); c0 += 2 {
		c1 := c0 + 1
		has1 := c1 < len(planes)
		a := planes[c0]
		for i in 0 ..< n do U[i] = complex(a[i], has1 ? planes[c1][i] : 0)

		// Boundary image v (Moisan eq. 9): jumps across the wrap-around edges.
		for &e in V do e = 0
		for x in 0 ..< w {
			d := U[(h - 1) * w + x] - U[x]
			V[x] += d
			V[(h - 1) * w + x] -= d
		}
		for y in 0 ..< h {
			d := U[y * w + w - 1] - U[y * w]
			V[y * w] += d
			V[y * w + w - 1] -= d
		}

		fft2(U, w, h, &row_plan, &col_plan)
		fft2(V, w, h, &row_plan, &col_plan)

		// Callers order planes so both lanes of a pair share the flatten setting.
		assert(!has1 || flatten_mask[c0] == flatten_mask[c1])
		f0 := flatten_mask[c0] ? params.flatten : 0
		for r in 0 ..< h {
			for q in 0 ..< w {
				i := r * w + q
				if q == 0 && r == 0 do continue // keep the mean; s has zero mean
				denom := cos_x[q] + cos_y[r] - 4
				p := U[i] - V[i] / complex(denom, 0) // p̂ = û - ŝ, ŝ = v̂ / denom
				g := gx[q] * gy[r]
				U[i] = p * complex(1 - f0 * g, 0)
			}
		}
		fft2(U, w, h, &row_plan, &col_plan, inverse = true)
		for i in 0 ..< n {
			a[i] = real(U[i])
			if has1 do planes[c1][i] = imag(U[i])
		}
	}
}

// Ratio of the mean colour jump across the wrap-around edges to the mean jump
// between ordinary neighbouring pixels. ~1 means the seam is as smooth as the
// rest of the texture; a raw photo is usually several times higher.
seam_score :: proc(img: Image) -> f32 {
	w, h := img.w, img.h
	diff :: #force_inline proc(img: Image, x0, y0, x1, y1: int) -> f32 {
		a := (y0 * img.w + x0) * 4
		b := (y1 * img.w + x1) * 4
		s: f32
		for c in 0 ..< 3 do s += abs(img.px[a + c] - img.px[b + c])
		return s
	}
	edge, inner: f64
	for y in 0 ..< h do edge += f64(diff(img, w - 1, y, 0, y))
	for x in 0 ..< w do edge += f64(diff(img, x, h - 1, x, 0))
	edge /= f64(w + h)
	// Sample interior neighbours on every row/column (cheap, representative).
	cnt := 0
	for y := 0; y < h; y += max(h / 64, 1) {
		for x in 0 ..< w - 1 { inner += f64(diff(img, x, y, x + 1, y)); cnt += 1 }
	}
	for x := 0; x < w; x += max(w / 64, 1) {
		for y in 0 ..< h - 1 { inner += f64(diff(img, x, y, x, y + 1)); cnt += 1 }
	}
	inner /= f64(max(cnt, 1))
	return f32(edge / max(inner, 1e-6))
}

// n×n repetition of img, for previews and tests.
image_repeat :: proc(img: Image, n: int) -> Image {
	out := image_like(img, img.w * n, img.h * n)
	for y in 0 ..< out.h {
		sy := y % img.h
		for x in 0 ..< out.w {
			sx := x % img.w
			copy(out.px[(y * out.w + x) * 4:][:4], img.px[(sy * img.w + sx) * 4:][:4])
		}
	}
	return out
}

// Non-periodic test texture: fractal value noise + a strong lighting gradient.
make_test_texture :: proc(w, h: int) -> Image {
	hash :: proc(x, y, s: i32) -> f32 {
		v := u32(x) * 374761393 + u32(y) * 668265263 + u32(s) * 2246822519
		v = (v ~ (v >> 13)) * 1274126177
		v ~= v >> 16
		return f32(v & 0xffffff) / f32(0xffffff)
	}
	noise :: proc(x, y: f32, s: i32) -> f32 {
		ix, iy := i32(math.floor(x)), i32(math.floor(y))
		fx, fy := x - math.floor(x), y - math.floor(y)
		ux, uy := fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
		a := math.lerp(hash(ix, iy, s), hash(ix + 1, iy, s), ux)
		b := math.lerp(hash(ix, iy + 1, s), hash(ix + 1, iy + 1, s), ux)
		return math.lerp(a, b, uy)
	}
	img := image_make(w, h)
	for y in 0 ..< h {
		for x in 0 ..< w {
			fx, fy := f32(x) / 24, f32(y) / 24
			v: f32
			amp: f32 = 0.5
			for o in 0 ..< 5 {
				v += amp * noise(fx, fy, i32(o))
				fx *= 2; fy *= 2; amp *= 0.5
			}
			light := 0.45 + 0.75 * f32(x) / f32(w) * (0.6 + 0.4 * f32(y) / f32(h))
			i := (y * w + x) * 4
			img.px[i + 0] = clamp(v * 0.9 * light, 0, 1)
			img.px[i + 1] = clamp(v * 0.7 * light, 0, 1)
			img.px[i + 2] = clamp(v * 0.45 * light, 0, 1)
			img.px[i + 3] = 1
		}
	}
	return img
}
