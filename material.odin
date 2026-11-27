package tileit

// Material sets: albedo + normal + roughness + height (+ ...) tiled together.
//
// Drop or pass any one map of a set; its siblings in the same folder are found
// by name (Bricks_Color.png, Bricks_NormalGL.png, Bricks_Roughness.png, or
// brick_wall_diff_2k.png, brick_wall_nor_gl_2k.png, ...). The colour map
// drives the synthesis, and every other map gets exactly the same edit, so
// the maps stay aligned with each other.

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Map_Kind :: enum u8 {
	Albedo,
	Normal,
	Roughness,
	Metallic,
	Height,
	AO,
	Other, // gloss, specular, packed ARM/ORM, opacity... treated as plain data
}

MAP_KIND_NAMES := [Map_Kind]string {
	.Albedo    = "Albedo",
	.Normal    = "Normal",
	.Roughness = "Roughness",
	.Metallic  = "Metallic",
	.Height    = "Height",
	.AO        = "AO",
	.Other     = "Other",
}

Material_Map :: struct {
	kind: Map_Kind,
	path: string,
	img:  Image,
}

// Name tokens per kind, matched case-insensitively at the end of the file
// stem (after a resolution suffix like _2k has been removed). Longer tokens
// are tried first, so "nor_gl" wins over "gl".
@(private = "file")
Token :: struct {
	text: string,
	kind: Map_Kind,
}

@(private = "file")
TOKENS := []Token {
	{"ambientocclusion", .AO}, {"ambient_occlusion", .AO}, {"occlusion", .AO}, {"ao", .AO},
	{"basecolor", .Albedo}, {"base_color", .Albedo}, {"albedo", .Albedo}, {"diffuse", .Albedo},
	{"colour", .Albedo}, {"color", .Albedo}, {"diff", .Albedo}, {"col", .Albedo}, {"alb", .Albedo},
	{"normalgl", .Normal}, {"normaldx", .Normal}, {"normal_gl", .Normal}, {"normal_dx", .Normal},
	{"nor_gl", .Normal}, {"nor_dx", .Normal}, {"normal", .Normal}, {"norm", .Normal}, {"nrm", .Normal}, {"nor", .Normal},
	{"roughness", .Roughness}, {"rough", .Roughness}, {"rgh", .Roughness},
	{"metalness", .Metallic}, {"metallic", .Metallic}, {"metal", .Metallic}, {"mtl", .Metallic},
	{"displacement", .Height}, {"height", .Height}, {"disp", .Height}, {"bump", .Height},
	{"glossiness", .Other}, {"gloss", .Other}, {"specular", .Other}, {"spec", .Other},
	{"opacity", .Other}, {"alpha", .Other}, {"arm", .Other}, {"orm", .Other}, {"mask", .Other},
}

IMAGE_EXTS :: []string{".png", ".jpg", ".jpeg", ".tga", ".bmp", ".psd", ".gif", ".hdr", ".pic"}

@(private = "file")
is_sep :: proc(c: u8) -> bool { return c == '_' || c == '-' || c == ' ' || c == '.' }

// Splits a file name into (base, kind). ok is false when no kind token is
// found; base is then the whole stem.
classify_name :: proc(path: string, allocator := context.temp_allocator) -> (base: string, kind: Map_Kind, ok: bool) {
	stem := strings.to_lower(filepath.stem(path), allocator)
	// Drop a trailing resolution tag: _1k, _2K, _4k, _1024, _2048 ...
	{
		i := len(stem)
		for i > 0 && (stem[i - 1] == 'k' || (stem[i - 1] >= '0' && stem[i - 1] <= '9')) do i -= 1
		tag := stem[i:]
		if i > 0 && i < len(stem) && is_sep(stem[i - 1]) && len(tag) >= 2 && tag[0] >= '0' && tag[0] <= '9' {
			stem = stem[:i - 1]
		}
	}
	best := -1
	for t, ti in TOKENS {
		if !strings.has_suffix(stem, t.text) do continue
		start := len(stem) - len(t.text)
		if start == 0 || !is_sep(stem[start - 1]) do continue
		if best < 0 || len(t.text) > len(TOKENS[best].text) do best = ti
	}
	if best < 0 do return stem, .Albedo, false
	t := TOKENS[best]
	return stem[:len(stem) - len(t.text) - 1], t.kind, true
}

@(private = "file")
has_image_ext :: proc(path: string) -> bool {
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	return slice.contains(IMAGE_EXTS, ext)
}

// Given one map of a set, finds the others next to it. The result always
// contains `path` itself; a file whose name has no map token comes back as a
// single Albedo map. Ordered by kind (Albedo first). Paths are allocated.
find_material_set :: proc(path: string) -> [dynamic]Material_Map {
	set: [dynamic]Material_Map
	base, kind, ok := classify_name(path)
	if !ok {
		append(&set, Material_Map{kind = .Albedo, path = strings.clone(path)})
		return set
	}
	dir := filepath.dir(path)
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		append(&set, Material_Map{kind = kind, path = strings.clone(path)})
		return set
	}
	for e in entries {
		if e.type == .Directory || !has_image_ext(e.name) do continue
		lower := strings.to_lower(e.name, context.temp_allocator)
		if strings.contains(lower, "_tiled") do continue // our own output
		b, k, k_ok := classify_name(e.name)
		if !k_ok || b != base do continue
		// One file per kind; prefer the one that was dropped.
		existing := -1
		for m, i in set do if m.kind == k do existing = i
		full, _ := filepath.join({dir, e.name}, context.allocator)
		if existing >= 0 {
			if strings.equal_fold(filepath.base(path), e.name) {
				delete(set[existing].path)
				set[existing].path = full
			} else do delete(full)
			continue
		}
		append(&set, Material_Map{kind = k, path = full})
	}
	if len(set) == 0 do append(&set, Material_Map{kind = kind, path = strings.clone(path)})
	slice.sort_by(set[:], proc(a, b: Material_Map) -> bool { return a.kind < b.kind })
	return set
}

// Groups explicitly given files (e.g. several dropped at once) into a set.
// Files without a map token count as Albedo. Later duplicates of a kind are
// ignored.
group_material_files :: proc(paths: []string) -> [dynamic]Material_Map {
	set: [dynamic]Material_Map
	outer: for p in paths {
		_, k, _ := classify_name(p)
		for m in set do if m.kind == k do continue outer
		append(&set, Material_Map{kind = k, path = strings.clone(p)})
	}
	slice.sort_by(set[:], proc(a, b: Material_Map) -> bool { return a.kind < b.kind })
	return set
}

// Loads every map; maps that fail to load or differ in size from the first
// one are dropped, and their names returned in `skipped`.
load_material_set :: proc(set: ^[dynamic]Material_Map) -> (skipped: [dynamic]string) {
	for i := 0; i < len(set); {
		img, ok := image_load(set[i].path)
		if ok && i > 0 && (img.w != set[0].img.w || img.h != set[0].img.h) {
			image_destroy(&img)
			ok = false
		}
		if !ok {
			append(&skipped, filepath.base(set[i].path))
			delete(set[i].path)
			ordered_remove(set, i)
			continue
		}
		set[i].img = img
		i += 1
	}
	return
}

material_set_destroy :: proc(set: ^[dynamic]Material_Map) {
	for &m in set { delete(m.path); image_destroy(&m.img) }
	delete(set^)
	set^ = nil
}

// ---------------------------------------------------------------------------

// Re-normalise a tangent-space normal map stored as 0..1 RGB.
normalize_normal_map :: proc(img: ^Image) {
	for i in 0 ..< img.w * img.h {
		p := img.px[i * 4:][:3]
		n := [3]f32{p[0] * 2 - 1, p[1] * 2 - 1, p[2] * 2 - 1}
		l := math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
		if l < 1e-6 do n = {0, 0, 1}
		else do n /= l
		for c in 0 ..< 3 do p[c] = n[c] * 0.5 + 0.5
	}
}

// What tile_material did besides tiling, for reporting and the GUI overlay.
Tile_Info :: struct {
	repeat:        Repeat_Info, // measured on the guide after the size crop
	crop_x, crop_y: int,        // region of the input that was used (centred)
	crop_w, crop_h: int,
	single_repeat:  bool, // only one repeat fits on a detected axis: Synth was skipped
	synth_ran:      bool, // the seed mattered for this result
	quilted:        [2]bool, // seams joined from the photo's real continuation (x, y)
	scale:          [2]f32,  // stretch-to-fit factors (1 = not stretched)
	tilt:           f32,     // radians the photo was straightened by (0 = none)
	fit_w, fit_h:   int,     // tile size before the final output resize
	out_w, out_h:   int,     // final tile size
}

// Tiles all maps of a material together. Returns one image per map, in the
// same order. Steps: optional crop to a selected region (or a centred size
// cap), optional trim to a
// whole number of repeats (measured on the guide's central region), then
// Quick or Synth. The colour map (Albedo if present, else the first map)
// drives repeat detection and Synth; Flatten applies to the colour map only.
tile_material :: proc(maps: []Material_Map, params: Tile_Params) -> (out: []Image, info: Tile_Info) {
	n := len(maps)
	out = make([]Image, n)
	if n == 0 do return
	guide := 0
	for m, i in maps do if m.kind == .Albedo { guide = i; break }
	ow, oh := maps[guide].img.w, maps[guide].img.h // original photo size

	// Straighten a slightly rotated photo first (repeat.odin): a tilted wall
	// has no clean horizontal repeat.
	base := maps
	tilt: f32
	if params.straighten {
		a, ok := detect_tilt(maps[guide].img, params.center)
		deg := abs(a) * 180 / math.PI
		if ok && deg >= 0.3 && deg <= 15 {
			tilt = a
			st := make([]Material_Map, n, context.temp_allocator)
			for m, i in maps {
				y_up := !strings.contains(strings.to_lower(filepath.base(m.path), context.temp_allocator), "dx")
				st[i] = {kind = m.kind, path = m.path, img = straighten(m.img, a, m.kind == .Normal, y_up)}
			}
			base = st
		}
	}
	defer if tilt != 0 do for &m in base do image_destroy(&m.img)
	info.tilt = tilt
	// Straightened frame <-> original photo (rotation about the centres).
	bw0, bh0 := f32(base[guide].img.w), f32(base[guide].img.h)
	to_base :: proc(x, y, tilt, ow, oh, bw, bh: f32) -> (f32, f32) {
		c, s := math.cos(tilt), math.sin(tilt)
		dx, dy := x - ow / 2, y - oh / 2
		return c * dx + s * dy + bw / 2, -s * dx + c * dy + bh / 2
	}
	to_orig :: proc(x, y, tilt, ow, oh, bw, bh: f32) -> (f32, f32) {
		c, s := math.cos(tilt), math.sin(tilt)
		dx, dy := x - bw / 2, y - bh / 2
		return c * dx - s * dy + ow / 2, s * dx + c * dy + oh / 2
	}

	// Decide the crop: the selected region (or a centred size cap), then
	// whole repeats inside that, centred in it.
	w, h := base[guide].img.w, base[guide].img.h
	rx, ry, rw, rh := 0, 0, w, h
	if params.region[2] > 0 && params.region[3] > 0 {
		r := params.region
		// Same centre and size, carried into the straightened frame.
		cx, cy := to_base(f32(r[0]) + f32(r[2]) / 2, f32(r[1]) + f32(r[3]) / 2, tilt, f32(ow), f32(oh), bw0, bh0)
		rw, rh = clamp(r[2], 1, w), clamp(r[3], 1, h)
		rx = clamp(int(cx - f32(rw) / 2), 0, w - rw)
		ry = clamp(int(cy - f32(rh) / 2), 0, h - rh)
	} else if params.crop > 0 {
		rw, rh = min(w, params.crop), min(h, params.crop)
		rx, ry = (w - rw) / 2, (h - rh) / 2
	}
	cw, ch := rw, rh
	if params.fit_repeat {
		sel := crop_rect(base[guide].img, rx, ry, rw, rh)
		info.repeat = detect_repeat(sel, params.center)
		image_destroy(&sel)
		// A small selection may be too short to see a long repeat twice;
		// the repeat belongs to the whole wall, so measure it there instead.
		// Also, a long repeat (four courses) can sit at the edge of what a
		// smaller window can see, leaving only a partial one (one course):
		// when the whole image shows a repeat that is a whole multiple of the
		// selection's, the longer one is the complete repeat.
		if rw < w || rh < h {
			whole := detect_repeat(base[guide].img, params.center)
			multiple_of :: proc(long, short: f32) -> bool {
				if short <= 0 do return false
				k := math.round(long / short)
				return k >= 2 && abs(long - k * short) <= 0.03 * long
			}
			if whole.found_x && whole.px <= f32(rw) && (!info.repeat.found_x || multiple_of(whole.px, info.repeat.px)) {
				info.repeat.found_x, info.repeat.px, info.repeat.strength_x = true, whole.px, whole.strength_x
			}
			if whole.found_y && whole.py <= f32(rh) && (!info.repeat.found_y || multiple_of(whole.py, info.repeat.py)) {
				info.repeat.found_y, info.repeat.py, info.repeat.strength_y = true, whole.py, whole.strength_y
			}
		}
	}

	// Stretch instead of crop: rescale the photo slightly so the selection
	// holds a whole number of repeats exactly, keeping all of it.
	rp := info.repeat // repeat in the working (possibly rescaled) pixels
	work := base // the maps everything below reads from
	scale := [2]f32{1, 1}
	if params.fit_repeat && params.stretch && (rp.found_x || rp.found_y) {
		fit :: proc(rlen, full: int, p: f32) -> f32 {
			k := max(int(math.round(f32(rlen) / p)), 1)
			if f32(k) * p > f32(full) do k = max(int(f32(full) / p), 1) // not enough photo
			s := f32(rlen) / (f32(k) * p)
			// Beyond ±15% the texture visibly distorts: crop that axis instead.
			return abs(s - 1) <= 0.15 ? s : 1
		}
		if rp.found_x do scale.x = fit(rw, w, rp.px)
		if rp.found_y do scale.y = fit(rh, h, rp.py)
		nw, nh := max(int(math.round(f32(w) * scale.x)), 1), max(int(math.round(f32(h) * scale.y)), 1)
		scaled := make([]Material_Map, n, context.temp_allocator)
		for m, i in base do scaled[i] = {kind = m.kind, path = m.path, img = resample(m.img, nw, nh)}
		work = scaled
		// Same selection centre, same output size, in the rescaled photo.
		cx := (f32(rx) + f32(rw) / 2) * scale.x
		cy := (f32(ry) + f32(rh) / 2) * scale.y
		rw, rh = min(rw, nw), min(rh, nh)
		rx = clamp(int(math.round(cx - f32(rw) / 2)), 0, nw - rw)
		ry = clamp(int(math.round(cy - f32(rh) / 2)), 0, nh - rh)
		rp.px *= scale.x
		rp.py *= scale.y
		w, h = nw, nh
	}
	defer if raw_data(work) != raw_data(base) do for &m in work do image_destroy(&m.img)
	info.scale = scale

	if rp.found_x do cw = whole_repeats(rw, rp.px)
	if rp.found_y do ch = whole_repeats(rh, rp.py)
	tx, ty := rx + (rw - cw) / 2, ry + (rh - ch) / 2 // tile origin in `work` pixels
	// Reported in the original photo's pixels (for the overlay): undo the
	// stretch, then the rotation (the rectangle's centre; its size is kept).
	{
		bcx := (f32(tx) + f32(cw) / 2) / scale.x
		bcy := (f32(ty) + f32(ch) / 2) / scale.y
		ocx, ocy := to_orig(bcx, bcy, tilt, f32(ow), f32(oh), bw0, bh0)
		info.crop_w, info.crop_h = int(f32(cw) / scale.x), int(f32(ch) / scale.y)
		info.crop_x = int(ocx - f32(info.crop_w) / 2)
		info.crop_y = int(ocy - f32(info.crop_h) / 2)
	}

	// Regular texture: join the seams from the photo's real continuation
	// (quilt.odin). Axes it can't do (no repeat, or no room in the photo for
	// the continuation) fall through to the rebuild below.
	plan: Quilt_Plan
	defer quilt_plan_destroy(&plan)
	if rp.found_x || rp.found_y {
		plan = quilt_plan(work[guide].img, tx, ty, cw, ch,
			{rp.found_x, rp.found_y}, {rp.px, rp.py})
	}
	info.quilted = plan.quilted

	quick := make([]Image, n)
	defer delete(quick)
	for m, i in work {
		p := params
		colour := m.kind == .Albedo
		if !colour do p.flatten = 0 // lighting removal only makes sense for colour
		src: Image
		owned := true
		switch {
		case plan.quilted.x || plan.quilted.y: src = quilt_apply(m.img, plan)
		case cw != w || ch != h:               src = crop_rect(m.img, tx, ty, cw, ch)
		case:                                  src = m.img; owned = false
		}
		quick[i] = make_tileable(src, p, colour = colour)
		if owned do image_destroy(&src)
	}

	// Seams still to rebuild with Synth: axes that weren't quilted.
	todo := [2]bool{!plan.quilted.x, !plan.quilted.y}
	// With a single repeat on a not-quilted axis there's no copy source a
	// whole repeat away, but the edges already line up: keep the Quick result.
	single := (todo.x && rp.found_x && f32(cw) < 1.5 * rp.px) ||
	          (todo.y && rp.found_y && f32(ch) < 1.5 * rp.py)
	info.single_repeat = single
	if params.mode == .Quick || single || (!todo.x && !todo.y) {
		copy(out, quick)
	} else {
		others := make([dynamic]Image, 0, n - 1, context.temp_allocator)
		for q, i in quick do if i != guide do append(&others, q)
		sp := Synth_Params{band = params.band, seed = params.seed, center = params.center, axes = todo}
		// The tile holds whole repeats, so copies can be pinned to them.
		if rp.found_x do sp.period.x = rp.px
		if rp.found_y do sp.period.y = rp.py
		g, rest := synthesize_seams_set(quick[guide], others[:], sp)
		info.synth_ran = true
		defer delete(rest)
		out[guide] = g
		j := 0
		for i in 0 ..< n {
			if i == guide do continue
			out[i] = rest[j]
			j += 1
		}
		for &q in quick do image_destroy(&q)
	}
	// Output size (last step): wrap-around resize so the tile stays seamless.
	info.fit_w, info.fit_h = out[guide].w, out[guide].h
	target_w, target_h := info.fit_w, info.fit_h
	switch params.out_size {
	case .Fitted:
	case .Input:
		target_w, target_h = ow, oh
		if params.region[2] > 0 && params.region[3] > 0 {
			target_w, target_h = min(params.region[2], ow), min(params.region[3], oh)
		} else if params.crop > 0 {
			target_w, target_h = min(params.crop, ow), min(params.crop, oh)
		}
	case .S1K: target_w, target_h = 1024, 1024
	case .S2K: target_w, target_h = 2048, 2048
	case .S4K: target_w, target_h = 4096, 4096
	}
	info.out_w, info.out_h = target_w, target_h
	if target_w != info.fit_w || target_h != info.fit_h {
		for &o in out {
			r := resize_periodic(o, target_w, target_h)
			image_destroy(&o)
			o = r
		}
	}

	for m, i in maps do if m.kind == .Normal do normalize_normal_map(&out[i])
	return
}

// One line describing the crop/repeat decision, for CLI output and the GUI.
describe_info :: proc(info: Tile_Info, src_w, src_h: int, allocator := context.temp_allocator) -> string {
	rep: string
	switch {
	case info.repeat.found_x && info.repeat.found_y:
		rep = fmt.aprintf("repeat %.0fx%.0f", info.repeat.px, info.repeat.py, allocator = allocator)
	case info.repeat.found_x:
		rep = fmt.aprintf("repeat %.1f px horizontally", info.repeat.px, allocator = allocator)
	case info.repeat.found_y:
		rep = fmt.aprintf("repeat %.1f px vertically", info.repeat.py, allocator = allocator)
	case:
		rep = "no regular repeat"
	}
	if info.quilted.x || info.quilted.y {
		which := info.quilted.x && info.quilted.y ? "" : info.quilted.x ? " L/R" : " T/B"
		rep = fmt.aprintf("%s, quilted%s", rep, which, allocator = allocator)
	}
	if info.tilt != 0 {
		rep = fmt.aprintf("straightened %.1f°, %s", info.tilt * 180 / math.PI, rep, allocator = allocator)
	}
	if info.scale != {1, 1} && info.scale != {} {
		rep = fmt.aprintf("%s, stretched %.1f%% x %.1f%%", rep, (info.scale.x - 1) * 100, (info.scale.y - 1) * 100, allocator = allocator)
	}
	if info.single_repeat {
		rep = fmt.aprintf("%s (one repeat fits: seams joined without rebuilding)", rep, allocator = allocator)
	}
	if info.crop_w != src_w || info.crop_h != src_h {
		rep = fmt.aprintf("%s, cropped %dx%d -> %dx%d", rep, src_w, src_h, info.crop_w, info.crop_h, allocator = allocator)
	}
	if info.out_w > 0 && (info.out_w != info.fit_w || info.out_h != info.fit_h) {
		rep = fmt.aprintf("%s, resized to %dx%d", rep, info.out_w, info.out_h, allocator = allocator)
	}
	return rep
}

// Output name for a map: <stem>_tiled.png next to the original.
tiled_path :: proc(path: string, allocator := context.allocator) -> string {
	dir := filepath.dir(path)
	name := strings.concatenate({filepath.stem(path), "_tiled.png"}, context.temp_allocator)
	p, _ := filepath.join({dir, name}, allocator)
	return p
}

// ---------------------------------------------------------------------------
// Test helpers: derive a plausible material set from a colour texture, and
// a normal map from a height map (used to check that tiled maps agree).

height_from_colour :: proc(src: Image) -> Image {
	out := image_make(src.w, src.h, 1)
	for i in 0 ..< src.w * src.h {
		s := src.px[i * 4:][:3]
		l := 0.2126 * s[0] + 0.7152 * s[1] + 0.0722 * s[2]
		out.px[i * 4 + 0] = l; out.px[i * 4 + 1] = l; out.px[i * 4 + 2] = l; out.px[i * 4 + 3] = 1
	}
	return out
}

// Central differences with wrap-around; strength scales the slope.
normal_from_height :: proc(hmap: Image, strength: f32 = 4) -> Image {
	w, h := hmap.w, hmap.h
	out := image_make(w, h, 3)
	H :: #force_inline proc(img: Image, x, y: int) -> f32 {
		return img.px[(((y %% img.h) * img.w) + (x %% img.w)) * 4]
	}
	for y in 0 ..< h {
		for x in 0 ..< w {
			dx := (H(hmap, x + 1, y) - H(hmap, x - 1, y)) * 0.5 * strength
			dy := (H(hmap, x, y + 1) - H(hmap, x, y - 1)) * 0.5 * strength
			n := [3]f32{-dx, -dy, 1}
			n /= math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
			o := out.px[(y * w + x) * 4:][:4]
			o[0] = n.x * 0.5 + 0.5; o[1] = n.y * 0.5 + 0.5; o[2] = n.z * 0.5 + 0.5; o[3] = 1
		}
	}
	return out
}

// Mean angle in degrees between two normal maps.
normal_angle_diff :: proc(a, b: Image) -> f64 {
	sum: f64
	for i in 0 ..< a.w * a.h {
		p := a.px[i * 4:][:3]
		q := b.px[i * 4:][:3]
		u := [3]f32{p[0] * 2 - 1, p[1] * 2 - 1, p[2] * 2 - 1}
		v := [3]f32{q[0] * 2 - 1, q[1] * 2 - 1, q[2] * 2 - 1}
		d := clamp((u.x * v.x + u.y * v.y + u.z * v.z) / max(math.sqrt((u.x * u.x + u.y * u.y + u.z * u.z) * (v.x * v.x + v.y * v.y + v.z * v.z)), 1e-6), -1, 1)
		sum += f64(math.acos(d)) * 180 / math.PI
	}
	return sum / f64(max(a.w * a.h, 1))
}
