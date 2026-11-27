package tileit

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

main :: proc() {
	args := os.args[1:]
	// A single file argument (also what "Open with" / dropping a file on the
	// exe produces) opens the GUI with that file loaded.
	if len(args) == 1 && !strings.has_prefix(args[0], "-") {
		gui(args[0])
		return
	}
	// Hidden: drives the real GUI end to end and saves screenshots
	// (OUT_running.png mid-job, OUT.png with the result), then exits.
	if len(args) == 3 && args[0] == "--autotest" {
		gui(args[1], args[2])
		return
	}
	if len(args) > 0 do os.exit(cli(args))
	gui()
}

// ---------------------------------------------------------------------------
// CLI (headless use and testing)

USAGE :: `tileit [FILE]               open the GUI (optionally with FILE loaded)
tileit IN OUT [options]     make IN tileable, write OUT (.png)
  --mode quick|synth        quick = smooth the seams only; synth (default) also
                            rebuilds structure across the seams from texture patches
  --band B                  synth: half-width of rebuilt band, fraction of short side (default 0.06)
  --seed N                  synth: different seeds give different fills
  --crop N                  centre-crop to at most N x N first (e.g. 2048, 4096; 0 = off)
  --region X,Y,W,H          use only this rectangle of the input (overrides --crop)
  --repeat crop|stretch|off detect a regular repeat (bricks, tiles) and fit the
                            tile to whole repeats by cropping (default) or by
                            rescaling slightly (keeps the whole selection)
  --straighten on|off       rotate out a slight tilt (0.3-15 degrees; default on)
  --center F                trusted central fraction (default 0.65): the repeat is
                            measured there and synth copies only from there
  --flatten F               lighting flatten strength 0..1 (default 0)
  --scale S                 flatten/even blur size, fraction of short side (default 0.15)
  --even E                  even out local contrast 0..1 (default 0)
  --size S                  output size: input (default: same as the selection or
                            photo), fitted (as fitted to repeats), 1024, 2048, 4096
  --preview PATH            also write a 3x3 tiled preview
tileit --set FILE [options] tile a whole material set: finds FILE's siblings
                            (Color/Normal/Roughness/Height/AO/...) and writes
                            <name>_tiled.png next to each
tileit --make-test OUT [W H]  write a non-tileable test texture
tileit --selftest           check the FFT against a naive DFT
tileit --compare A B        mean/max pixel difference between two images
`

cli :: proc(args: []string) -> int {
	switch args[0] {
	case "--help", "-h":
		fmt.print(USAGE)
		return 0
	case "--selftest":
		return selftest()
	case "--compare":
		if len(args) < 3 { fmt.eprint(USAGE); return 2 }
		a, ok_a := image_load(args[1])
		b, ok_b := image_load(args[2])
		defer { image_destroy(&a); image_destroy(&b) }
		if !ok_a || !ok_b || a.w != b.w || a.h != b.h { fmt.eprintln("cannot compare (missing file or size mismatch)"); return 1 }
		sum, worst: f64
		for v, i in a.px {
			d := f64(abs(v - b.px[i])) * 255
			sum += d
			worst = max(worst, d)
		}
		fmt.printfln("mean abs diff %.3f, max %.0f (0..255 scale)", sum / f64(len(a.px)), worst)
		return 0
	case "--bluish":
		// Hidden diagnostic: share of pixels whose blue clearly exceeds red,
		// per tenth of the image height (finds colour drift in rebuilt bands).
		img, ok := image_load(args[1])
		if !ok do return 1
		defer image_destroy(&img)
		total := 0
		rows: [10]int
		for i in 0 ..< img.w * img.h {
			p := img.px[i * 4:][:3]
			if p[2] > p[0] + 0.04 && p[2] > p[1] {
				total += 1
				rows[min(i / img.w * 10 / img.h, 9)] += 1
			}
		}
		fmt.printfln("bluish pixels: %.3f%%  by tenth of height: %v", 100 * f64(total) / f64(img.w * img.h), rows)
		return 0
	case "--rotate":
		// Hidden test helper: rotate IN by DEG degrees (cropped inside), write OUT.
		if len(args) < 4 { fmt.eprintln("usage: --rotate IN OUT DEG"); return 2 }
		img, ok := image_load(args[1])
		if !ok do return 1
		defer image_destroy(&img)
		rot := rotate_for_test(img, f32(strconv.parse_f64(args[3]) or_else 0))
		defer image_destroy(&rot)
		return image_save_png(rot, args[2]) ? 0 : 1
	case "--make-test-set":
		if len(args) < 4 { fmt.eprintln("usage: --make-test-set ALBEDO OUT_DIR NAME"); return 2 }
		return cli_make_test_set(args[1], args[2], args[3])
	case "--check-normals":
		// Hidden test: does NORMAL match the normal derived from HEIGHT?
		if len(args) < 3 { fmt.eprintln("usage: --check-normals HEIGHT NORMAL"); return 2 }
		hm, ok_h := image_load(args[1])
		nm, ok_n := image_load(args[2])
		defer { image_destroy(&hm); image_destroy(&nm) }
		if !ok_h || !ok_n || hm.w != nm.w || hm.h != nm.h { fmt.eprintln("cannot load or size mismatch"); return 1 }
		derived := normal_from_height(hm)
		defer image_destroy(&derived)
		fmt.printfln("mean angle between normal map and normals derived from height: %.2f deg", normal_angle_diff(derived, nm))
		return 0
	case "--make-test":
		if len(args) < 2 { fmt.eprint(USAGE); return 2 }
		w, h := 512, 512
		if len(args) >= 4 {
			w, _ = strconv.parse_int(args[2])
			h, _ = strconv.parse_int(args[3])
		}
		img := make_test_texture(w, h)
		img.bits16 = len(args) >= 5 && args[4] == "16" // hidden: 16-bit test file
		defer image_destroy(&img)
		if !image_save_png(img, args[1]) { fmt.eprintln("could not write", args[1]); return 1 }
		fmt.printfln("wrote %s (%dx%d), seam score %.2f", args[1], w, h, seam_score(img))
		return 0
	}

	if args[0] == "--set" {
		if len(args) < 2 { fmt.eprint(USAGE); return 2 }
		params, _, opt_ok := parse_options(args[2:])
		if !opt_ok do return 2
		return cli_set(args[1], params)
	}

	if len(args) < 2 { fmt.eprint(USAGE); return 2 }
	params, preview, opt_ok := parse_options(args[2:])
	if !opt_ok do return 2

	src, ok := image_load(args[0])
	if !ok { fmt.eprintfln("could not load %s (%s)", args[0], load_error); return 1 }
	defer image_destroy(&src)

	// The file name decides how it's treated (a *_Normal map is re-normalised
	// and processed linearly, a colour map in log space, ...).
	_, kind, _ := classify_name(args[0])
	t0 := time.tick_now()
	outs, info := tile_material({{kind = kind, img = src}}, params)
	dst := outs[0]
	delete(outs)
	defer image_destroy(&dst)
	ms := time.duration_milliseconds(time.tick_since(t0))

	if !image_save_png(dst, args[1]) { fmt.eprintln("could not write", args[1]); return 1 }
	seed_note := info.synth_ran ? fmt.tprintf("; synth seed %d", params.seed) : ""
	fmt.printfln("%dx%d in %.0f ms; %s%s; seam score %.2f -> %.2f (1.0 = as smooth as the interior)",
		src.w, src.h, ms, describe_info(info, src.w, src.h), seed_note, seam_score(src), seam_score(dst))
	if preview != "" {
		rep := image_repeat(dst, 3)
		defer image_destroy(&rep)
		image_save_png(rep, preview)
	}
	return 0
}

parse_options :: proc(args: []string) -> (params: Tile_Params, preview: string, ok: bool) {
	params = DEFAULT_PARAMS
	for i := 0; i < len(args); i += 1 {
		if i + 1 >= len(args) { fmt.eprintln("missing value for", args[i]); return }
		switch args[i] {
		case "--flatten": params.flatten = f32(strconv.parse_f64(args[i + 1]) or_else 0)
		case "--scale":   params.flatten_scale = f32(strconv.parse_f64(args[i + 1]) or_else 0.15)
		case "--even":    params.even = clamp(f32(strconv.parse_f64(args[i + 1]) or_else 0), 0, 1)
		case "--size":
			switch args[i + 1] {
			case "fitted": params.out_size = .Fitted
			case "input":  params.out_size = .Input
			case "1024", "1k", "1K": params.out_size = .S1K
			case "2048", "2k", "2K": params.out_size = .S2K
			case "4096", "4k", "4K": params.out_size = .S4K
			case: fmt.eprintln("--size takes fitted|input|1024|2048|4096"); return
			}
		case "--preview": preview = args[i + 1]
		case "--band":    params.band = f32(strconv.parse_f64(args[i + 1]) or_else 0.06)
		case "--seed":    params.seed = u32(strconv.parse_int(args[i + 1]) or_else 1)
		case "--crop":    params.crop = strconv.parse_int(args[i + 1]) or_else 0
		case "--region":
			parts := strings.split(args[i + 1], ",", context.temp_allocator)
			if len(parts) != 4 { fmt.eprintln("--region takes X,Y,W,H"); return }
			for p, k in parts do params.region[k] = strconv.parse_int(strings.trim_space(p)) or_else 0
		case "--center":  params.center = clamp(f32(strconv.parse_f64(args[i + 1]) or_else 0.65), 0.2, 1)
		case "--straighten":
			switch args[i + 1] {
			case "on", "auto": params.straighten = true
			case "off":        params.straighten = false
			case: fmt.eprintln("--straighten takes on|off"); return
			}
		case "--repeat":
			switch args[i + 1] {
			case "on", "auto", "crop": params.fit_repeat = true; params.stretch = false
			case "stretch":            params.fit_repeat = true; params.stretch = true
			case "off":                params.fit_repeat = false
			case: fmt.eprintln("--repeat takes crop|stretch|off"); return
			}
		case "--mode":
			switch args[i + 1] {
			case "quick": params.mode = .Quick
			case "synth": params.mode = .Synth
			case: fmt.eprintln("unknown mode", args[i + 1]); return
			}
		case: fmt.eprintln("unknown option", args[i]); return
		}
		i += 1
	}
	return params, preview, true
}

// Tiles a whole material set found from one of its maps; writes
// <stem>_tiled.png next to each original.
cli_set :: proc(path: string, params: Tile_Params) -> int {
	set := find_material_set(path)
	defer material_set_destroy(&set)
	skipped := load_material_set(&set)
	defer delete(skipped)
	for s in skipped do fmt.eprintfln("skipped %s (could not load, or size differs)", s)
	if len(set) == 0 { fmt.eprintln("nothing to tile"); return 1 }

	t0 := time.tick_now()
	outs, info := tile_material(set[:], params)
	defer { for &o in outs do image_destroy(&o); delete(outs) }
	ms := time.duration_milliseconds(time.tick_since(t0))

	fmt.printfln("%d map(s), %dx%d, %.0f ms; %s", len(set), set[0].img.w, set[0].img.h, ms,
		describe_info(info, set[0].img.w, set[0].img.h))
	failed := false
	for m, i in set {
		dst := tiled_path(m.path, context.temp_allocator)
		ok := image_save_png(outs[i], dst)
		if !ok do failed = true
		fmt.printfln("  %-9s %s -> %s%s  seam %.2f -> %.2f", MAP_KIND_NAMES[m.kind], filepath.base(m.path),
			filepath.base(dst), ok ? "" : " (WRITE FAILED)", seam_score(m.img), seam_score(outs[i]))
	}
	return failed ? 1 : 0
}

// Hidden test helper: a fake but self-consistent material set from a colour
// texture (height = luminance, normal derived from that height).
cli_make_test_set :: proc(albedo_path, out_dir, name: string) -> int {
	src, ok := image_load(albedo_path)
	if !ok { fmt.eprintln("could not load", albedo_path); return 1 }
	defer image_destroy(&src)
	height := height_from_colour(src)
	defer image_destroy(&height)
	normal := normal_from_height(height)
	defer image_destroy(&normal)
	rough := image_clone(height)
	defer image_destroy(&rough)
	for &v, i in rough.px do if i % 4 != 3 do v = 1 - v
	files := [?]struct{ suffix: string, img: Image }{
		{"_Color.png", src}, {"_Height.png", height}, {"_NormalGL.png", normal}, {"_Roughness.png", rough},
	}
	for f in files {
		p, _ := filepath.join({out_dir, strings.concatenate({name, f.suffix}, context.temp_allocator)}, context.temp_allocator)
		if !image_save_png(f.img, p) { fmt.eprintln("could not write", p); return 1 }
		fmt.println("wrote", p)
	}
	return 0
}

selftest :: proc() -> int {
	worst: f64
	for n in ([]int{1, 2, 7, 8, 12, 64, 100, 127, 1000}) {
		plan := fft_plan_make(n)
		defer fft_plan_destroy(&plan)
		x := make([]complex64, n); defer delete(x)
		y := make([]complex64, n); defer delete(y)
		scratch := make([]complex64, fft_scratch_len(&plan)); defer delete(scratch)
		for i in 0 ..< n do x[i] = complex(f32(math.sin(f64(i) * 1.3)), f32(math.cos(f64(i * i) * 0.1)))
		copy(y, x)
		fft_forward(&plan, y, scratch)
		err: f64
		for k in 0 ..< n {
			ref: complex128
			for j in 0 ..< n {
				a := -2 * math.PI * f64(j * k % n) / f64(n)
				ref += complex128(x[j]) * complex(math.cos(a), math.sin(a))
			}
			err = max(err, abs(complex128(y[k]) - ref) / f64(n))
		}
		fft_inverse(&plan, y, scratch)
		for k in 0 ..< n do err = max(err, f64(abs(y[k] - x[k])))
		fmt.printfln("n=%4d  max error %.2e", n, err)
		worst = max(worst, err)
	}
	ok := worst < 1e-4

	// Map-name classification, using naming styles of common texture sites.
	Case :: struct { name, base: string, kind: Map_Kind, found: bool }
	cases := []Case{
		{"Bricks076C_2K_Color.png", "bricks076c_2k", .Albedo, true},
		{"Bricks076C_2K_NormalGL.png", "bricks076c_2k", .Normal, true},
		{"Bricks076C_2K_Roughness.jpg", "bricks076c_2k", .Roughness, true},
		{"Bricks076C_2K_Displacement.png", "bricks076c_2k", .Height, true},
		{"Bricks076C_2K_AmbientOcclusion.png", "bricks076c_2k", .AO, true},
		{"brick_wall_diff_2k.png", "brick_wall", .Albedo, true},
		{"brick_wall_nor_gl_2k.png", "brick_wall", .Normal, true},
		{"brick_wall_rough_2k.png", "brick_wall", .Roughness, true},
		{"brick_wall_arm_4k.png", "brick_wall", .Other, true},
		{"wood-basecolor.tga", "wood", .Albedo, true},
		{"wood-normal.tga", "wood", .Normal, true},
		{"wood-metallic.tga", "wood", .Metallic, true},
		{"T_Rock_N.png", "t_rock_n", .Albedo, false}, // single letters are too ambiguous
		{"sand.png", "sand", .Albedo, false},
		{"decorative.png", "decorative", .Albedo, false}, // "...col"-like words don't count without a separator
	}
	for c in cases {
		base, kind, found := classify_name(c.name)
		good := base == c.base && kind == c.kind && found == c.found
		if !good {
			fmt.printfln("classify %s: got (%s, %v, %v), want (%s, %v, %v)", c.name, base, kind, found, c.base, c.kind, c.found)
			ok = false
		}
	}
	fmt.printfln("classify: %d name cases checked", len(cases))

	// 16-bit PNG round trip through our writer and stb's reader, for each
	// channel count.
	for comp in 1 ..= 4 {
		img := image_make(257, 131, comp)
		img.bits16 = true
		seed: u32 = 12345
		for &v, i in img.px {
			seed = seed * 1664525 + 1013904223
			// Smooth ramp + noise, like a height map.
			v = clamp(f32(i % (257 * 4)) / f32(257 * 4) + f32(seed >> 20) / 4096 * 0.05, 0, 1)
		}
		path, _ := filepath.join({os.temp_directory(context.temp_allocator) or_else ".", "tileit_selftest16.png"}, context.temp_allocator)
		wrote := image_save_png(img, path)
		back, loaded := image_load(path)
		worst: f32
		if wrote && loaded && back.bits16 && back.w == img.w && back.h == img.h {
			for i in 0 ..< img.w * img.h {
				// Compare the channels the format stores.
				chans := comp == 1 ? []int{0} : comp == 2 ? []int{0, 3} : comp == 3 ? []int{0, 1, 2} : []int{0, 1, 2, 3}
				for c in chans do worst = max(worst, abs(img.px[i * 4 + c] - back.px[i * 4 + c]))
			}
		} else do worst = 1
		image_destroy(&img); image_destroy(&back)
		os.remove(path)
		good := worst <= 0.6 / 65535
		fmt.printfln("png16: %d channel(s) round trip, max error %.1e %s", comp, worst, good ? "ok" : "FAILED")
		if !good do ok = false
	}

	fmt.println(ok ? "selftest OK" : "selftest FAILED")
	return ok ? 0 : 1
}

// ---------------------------------------------------------------------------
// GUI: two panes, drop a texture (or a whole material set) in, "Tile it",
// see the result tiled.

// A GPU texture showing one image; the image itself lives elsewhere.
Pane :: struct {
	tex:    rl.Texture2D,
	w, h:   int,
	loaded: bool,
}

pane_show :: proc(p: ^Pane, img: Image) {
	if p.loaded do rl.UnloadTexture(p.tex)
	bytes := image_to_rgba8(img, context.temp_allocator)
	p.tex = rl.LoadTextureFromImage(rl.Image{raw_data(bytes), i32(img.w), i32(img.h), 1, .UNCOMPRESSED_R8G8B8A8})
	rl.SetTextureFilter(p.tex, .BILINEAR)
	rl.SetTextureWrap(p.tex, .REPEAT)
	p.w, p.h = img.w, img.h
	p.loaded = true
}

pane_clear :: proc(p: ^Pane) {
	if p.loaded do rl.UnloadTexture(p.tex)
	p^ = {}
}

// One tiling run on a background thread, so the window stays responsive.
Job :: struct {
	maps:   []Material_Map, // private copies of the inputs (images only)
	params: Tile_Params,
	result: []Image,
	info:   Tile_Info,
	ms:     f64,
	done:   bool, // set atomically by the worker
	thread: ^thread.Thread,
}

App :: struct {
	set:           [dynamic]Material_Map, // inputs: albedo, normal, ...
	results:       []Image,               // outputs, same order; nil until tiled
	sel:           int,                   // which map the panes show
	input, output: Pane,
	params:        Tile_Params,
	last_params:   Tile_Params,
	tiles:         f32,
	tile_input:    bool,
	swap:          bool,
	job:           ^Job,
	rerun:         bool,     // params changed while a job was running
	pending_drop:  []string, // files dropped while a job was running
	status:        string,
	info:          Tile_Info, // crop/repeat decision of the last result
	drag:          enum { None, Creating, Moving }, // selection on the input pane
	drag_from:     [2]int,    // Creating: start corner; Moving: grab offset (image px)
	seed_text:     i32,       // value shown in the seed box (applied when editing ends)
	seed_editing:  bool,      // typing in the seed box: global shortcuts are off
}

set_status :: proc(app: ^App, format: string, args: ..any) {
	delete(app.status)
	app.status = fmt.aprintf(format, ..args)
}

clear_results :: proc(app: ^App) {
	for &r in app.results do image_destroy(&r)
	delete(app.results)
	app.results = nil
	pane_clear(&app.output)
}

show_selected :: proc(app: ^App) {
	if len(app.set) == 0 do return
	app.sel = clamp(app.sel, 0, len(app.set) - 1)
	pane_show(&app.input, app.set[app.sel].img)
	if app.results != nil do pane_show(&app.output, app.results[app.sel])
}

// One path: that file plus its siblings (by name). Several paths: exactly
// those files, grouped by kind.
load_input :: proc(app: ^App, paths: []string) {
	set := len(paths) == 1 ? find_material_set(paths[0]) : group_material_files(paths)
	skipped := load_material_set(&set)
	defer delete(skipped)
	if len(set) == 0 {
		material_set_destroy(&set)
		set_status(app, "Could not load %s (%s)", filepath.base(paths[0]), load_error)
		return
	}
	clear_results(app)
	material_set_destroy(&app.set)
	app.params.region = {} // a selection belongs to the previous image
	app.set = set
	// Show the map that was dropped, if it's in the set.
	app.sel = 0
	for m, i in app.set do if strings.equal_fold(filepath.base(m.path), filepath.base(paths[0])) do app.sel = i
	show_selected(app)

	kinds := make([dynamic]string, context.temp_allocator)
	for m in app.set do append(&kinds, MAP_KIND_NAMES[m.kind])
	extra := len(skipped) > 0 ? fmt.tprintf("  (skipped: %s)", strings.join(skipped[:], ", ", context.temp_allocator)) : ""
	base, _, _ := classify_name(app.set[0].path)
	set_status(app, "%s  %dx%d  %s  seam score %.2f%s  -  press Tile it (or Space)",
		base, app.set[0].img.w, app.set[0].img.h, strings.join(kinds[:], ", ", context.temp_allocator),
		seam_score(app.set[app.sel].img), extra)
}

job_run :: proc(job: ^Job) {
	t0 := time.tick_now()
	job.result, job.info = tile_material(job.maps, job.params)
	job.ms = time.duration_milliseconds(time.tick_since(t0))
	sync.atomic_store(&job.done, true)
}

start_job :: proc(app: ^App) {
	if app.job != nil { app.rerun = true; return }
	if len(app.set) == 0 do return
	job := new(Job)
	job.maps = make([]Material_Map, len(app.set))
	for m, i in app.set do job.maps[i] = {kind = m.kind, img = image_clone(m.img)}
	job.params = app.params
	app.last_params = app.params
	sync.atomic_store(&synth_progress, 0)
	job.thread = thread.create_and_start_with_poly_data(job, job_run)
	app.job = job
	app.rerun = false
}

// Picks up a finished job, if any.
poll_job :: proc(app: ^App) {
	job := app.job
	if job == nil || !sync.atomic_load(&job.done) do return
	thread.join(job.thread)
	thread.destroy(job.thread)
	for &m in job.maps do image_destroy(&m.img)
	delete(job.maps)
	app.job = nil
	defer free(job)

	if app.pending_drop != nil {
		for &r in job.result do image_destroy(&r) // input is being replaced; result is stale
		delete(job.result)
		load_input(app, app.pending_drop)
		for p in app.pending_drop do delete(p)
		delete(app.pending_drop)
		app.pending_drop = nil
		return
	}
	clear_results(app)
	app.results = job.result // takes ownership
	app.info = job.info
	show_selected(app)
	src := app.set[app.sel].img
	// The seed only matters when Synth actually rebuilt a seam; say which one
	// it was then, so a result can be reproduced.
	mode := job.params.mode == .Quick ? "Quick" : job.info.synth_ran ? fmt.tprintf("Synth seed %d", job.params.seed) : "Synth"
	set_status(app, "%s %.1fs  %d map(s)  %s  seam %.2f -> %.2f  (Ctrl+S: save)",
		mode, job.ms / 1000, len(app.set),
		describe_info(job.info, src.w, src.h), seam_score(src), seam_score(app.results[app.sel]))
	if app.rerun || app.params != app.last_params do start_job(app)
}

// Asks for a file name for the shown map; the other maps of the set are saved
// into the same folder as <their name>_tiled.png.
save_output_as :: proc(app: ^App) {
	if app.results == nil do return
	path, ok := save_file_dialog(tiled_path(app.set[app.sel].path, context.temp_allocator))
	if !ok do return
	defer delete(path)
	dir := filepath.dir(path)
	saved, failed := 0, 0
	for m, i in app.set {
		dst := path
		if i != app.sel {
			name := strings.concatenate({filepath.stem(m.path), "_tiled.png"}, context.temp_allocator)
			dst, _ = filepath.join({dir, name}, context.temp_allocator)
		}
		if image_save_png(app.results[i], dst) do saved += 1
		else do failed += 1
	}
	if failed == 0 do set_status(app, "Saved %d map(s) to %s", saved, dir)
	else do set_status(app, "Saved %d, FAILED %d map(s) in %s", saved, failed, dir)
}

save_output :: proc(app: ^App) {
	if app.results == nil do return
	saved, failed := 0, 0
	for m, i in app.set {
		if image_save_png(app.results[i], tiled_path(m.path, context.temp_allocator)) do saved += 1
		else do failed += 1
	}
	dir := filepath.dir(app.set[0].path)
	if failed == 0 do set_status(app, "Saved %d map(s) as *_tiled.png in %s", saved, dir)
	else do set_status(app, "Saved %d, FAILED %d map(s) in %s", saved, failed, dir)
}

draw_pane :: proc(p: ^Pane, area: rl.Rectangle, tiles: int, hint: cstring) {
	rl.DrawRectangleRec(area, PANEL)
	rl.DrawRectangleLinesEx(area, 1, AMBER_DARK)
	if !p.loaded {
		draw_text_centred(string(hint), area.x + area.width / 2, area.y + area.height / 2, 20, AMBER_MID)
		return
	}
	iw, ih := f32(p.w * tiles), f32(p.h * tiles)
	pad: f32 = 12
	s := min((area.width - 2 * pad) / iw, (area.height - 2 * pad) / ih)
	dw, dh := iw * s, ih * s
	dest := rl.Rectangle{area.x + (area.width - dw) / 2, area.y + (area.height - dh) / 2, dw, dh}
	rl.DrawTexturePro(p.tex, {0, 0, iw, ih}, dest, {}, 0, rl.WHITE)
}

gui :: proc(initial_file := "", autotest_out := "") {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
	rl.InitWindow(1440, 900, "tileit")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)
	rl.SetExitKey(.KEY_NULL) // Esc clears the selection instead of quitting
	theme_apply()
	defer theme_unload()

	app := App{params = DEFAULT_PARAMS, tiles = 3}
	set_status(&app, "Drop a texture, or several maps of one material, into the window")
	defer if app.job != nil do thread.join(app.job.thread) // let a running job finish before exit
	if initial_file != "" do load_input(&app, {initial_file})

	// Autotest: start a job, capture mid-run, capture the result, switch to
	// the second map and capture again, quit.
	autotest := autotest_out != ""
	autotest_stem := strings.trim_suffix(autotest_out, ".png")
	frame, phase := 0, 0

	for !rl.WindowShouldClose() {
		free_all(context.temp_allocator)
		poll_job(&app)

		shot: cstring
		quit := false
		if autotest {
			frame += 1
			switch {
			case phase == 0 && frame == 3 && len(app.set) > 0:
				// Exercise the selection path: an off-centre selection.
				img := app.set[0].img
				app.params.region = {img.w / 8, img.h / 6, img.w * 5 / 8, img.h * 5 / 8}
			case phase == 0 && frame == 5:
				start_job(&app); phase = 1
			case phase == 1 && app.job != nil && sync.atomic_load(&synth_progress) > 0.2:
				shot = fmt.ctprintf("%s_running.png", autotest_stem); phase = 2
			case phase >= 1 && phase <= 2 && app.job == nil && app.results != nil:
				shot = strings.clone_to_cstring(autotest_out, context.temp_allocator)
				phase = 3
				if len(app.set) < 2 do quit = true
			case phase == 3:
				app.sel = (app.sel + 1) % len(app.set); show_selected(&app); phase = 4
				// Also show disabled controls in the second capture.
				app.params.mode = .Quick
				app.params.fit_repeat = false
			case phase == 4:
				shot = fmt.ctprintf("%s_map2.png", autotest_stem); quit = true
			}
		}

		if rl.IsFileDropped() {
			files := rl.LoadDroppedFiles()
			if files.count > 0 {
				paths := make([]string, files.count)
				for i in 0 ..< int(files.count) do paths[i] = strings.clone(string(files.paths[i]))
				if app.job != nil {
					for p in app.pending_drop do delete(p)
					delete(app.pending_drop)
					app.pending_drop = paths
					set_status(&app, "Will load %s when the current run finishes", filepath.base(paths[0]))
				} else {
					load_input(&app, paths)
					for p in paths do delete(p)
					delete(paths)
				}
			}
			rl.UnloadDroppedFiles(files)
		}

		// Keyboard shortcuts - not while typing in the seed box, where digits,
		// Enter and Esc belong to the box.
		keys := !app.seed_editing
		ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
		if keys && (rl.IsKeyPressed(.SPACE) || rl.IsKeyPressed(.ENTER)) do start_job(&app)
		if keys && ctrl && rl.IsKeyPressed(.S) do save_output(&app)
		// Tab / number keys switch the map shown.
		if keys && len(app.set) > 1 {
			if rl.IsKeyPressed(.TAB) { app.sel = (app.sel + 1) % len(app.set); show_selected(&app) }
			for k in 0 ..< min(len(app.set), 9) {
				if rl.IsKeyPressed(rl.KeyboardKey(int(rl.KeyboardKey.ONE) + k)) { app.sel = k; show_selected(&app) }
			}
		}

		// Re-run automatically once a control is released.
		if app.results != nil && app.job == nil && app.params != app.last_params && !rl.IsMouseButtonDown(.LEFT) do start_job(&app)

		sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
		bar: f32 = 12 + 4 * (ROW_H + 8) + 6
		foot: f32 = 34

		rl.BeginDrawing()
		rl.ClearBackground(BLACK)

		// FILE: files and algorithm.
		r := row_start(12, "FILE")
		if row_button(&r, "Tile it", len(app.set) > 0) do start_job(&app)
		if row_button(&r, "Open...") {
			if paths, ok := open_files_dialog(); ok {
				if app.job != nil {
					for p in app.pending_drop do delete(p)
					delete(app.pending_drop)
					app.pending_drop = paths[:]
				} else {
					load_input(&app, paths[:])
					for p in paths do delete(p)
					delete(paths)
				}
			}
		}
		if row_button(&r, len(app.set) > 1 ? "Save all" : "Save", app.results != nil) do save_output(&app)
		if row_button(&r, "Save as...", app.results != nil) do save_output_as(&app)
		row_space(&r, 24)
		mode := i32(app.params.mode)
		row_choice(&r, {"Quick", "Synth"}, &mode)
		app.params.mode = Mode(mode)
		synth := app.params.mode == .Synth
		row_slider(&r, "Band", fmt.tprintf("%.2f", app.params.band), &app.params.band, 0.02, 0.2, 120, synth)
		// Seed: shows the current one; type your own and press Enter.
		if !app.seed_editing do app.seed_text = i32(app.params.seed)
		if row_value(&r, "Seed", &app.seed_text, 0, 99_999_999, &app.seed_editing, 120, synth) {
			app.params.seed = u32(max(app.seed_text, 0))
		}
		if row_button(&r, "New seed", synth && !app.seed_editing) do app.params.seed += 1

		// VIEW: preview options and the map switcher.
		r = row_start(12 + (ROW_H + 8), "VIEW")
		row_slider(&r, "Preview", fmt.tprintf("%dx%d", int(app.tiles), int(app.tiles)), &app.tiles, 1, 6, 120)
		app.tiles = math.round(app.tiles)
		row_check(&r, "Swap sides", &app.swap)
		row_check(&r, "Tile input too", &app.tile_input)
		row_space(&r, 14)
		row_label(&r, "Output", AMBER)
		{
			size := i32(app.params.out_size)
			row_choice(&r, {"Fitted", "Input", "1K", "2K", "4K"}, &size)
			app.params.out_size = Out_Size(size)
		}
		if len(app.set) > 1 {
			row_space(&r, 14)
			names := make([dynamic]string, context.temp_allocator)
			for m in app.set do append(&names, MAP_KIND_NAMES[m.kind])
			sel := i32(app.sel)
			if row_choice(&r, names[:], &sel) { app.sel = int(sel); show_selected(&app) }
		}

		// FIT: what part of the photo is used, and how it is fitted.
		r = row_start(12 + 2 * (ROW_H + 8), "FIT")
		{
			// Presets make a centred square selection of that size (which can
			// then be dragged around); Full clears the selection.
			sizes := [4]int{0, 1024, 2048, 4096}
			current: i32 = -1
			reg := app.params.region
			if reg[2] == 0 do current = 0
			else if len(app.set) > 0 {
				img := app.set[0].img
				for s, i in sizes[1:] do if reg[2] == min(s, img.w) && reg[3] == min(s, img.h) do current = i32(i + 1)
			}
			picked := current
			row_label(&r, "Crop")
			if row_choice(&r, {"Full", "1K", "2K", "4K"}, &picked, len(app.set) > 0) {
				img := app.set[0].img
				if picked == 0 do app.params.region = {}
				else {
					s := sizes[picked]
					cw, ch := min(s, img.w), min(s, img.h)
					app.params.region = {(img.w - cw) / 2, (img.h - ch) / 2, cw, ch}
				}
			}
		}
		row_space(&r, 10)
		row_check(&r, "Fit to repeat", &app.params.fit_repeat)
		{
			fit := i32(app.params.stretch ? 1 : 0)
			row_choice(&r, {"Crop", "Stretch"}, &fit, app.params.fit_repeat)
			app.params.stretch = fit == 1
		}
		row_space(&r, 10)
		row_check(&r, "Straighten", &app.params.straighten)
		row_slider(&r, "Trusted centre", fmt.tprintf("%d%%", int(app.params.center * 100 + 0.5)), &app.params.center, 0.4, 1, 120)
		app.params.center = math.round(app.params.center * 20) / 20 // 5% steps

		// TONE: colour evening, and the selection readout.
		r = row_start(12 + 3 * (ROW_H + 8), "TONE")
		row_slider(&r, "Flatten", fmt.tprintf("%.2f", app.params.flatten), &app.params.flatten, 0, 1, 120)
		row_slider(&r, "Even contrast", fmt.tprintf("%.2f", app.params.even), &app.params.even, 0, 1, 120)
		row_slider(&r, "Scale", fmt.tprintf("%.2f", app.params.flatten_scale), &app.params.flatten_scale, 0.02, 0.5, 120)
		row_space(&r, 10)
		if app.params.region[2] > 0 {
			row_label(&r, fmt.tprintf("Selection %d x %d at %d,%d   right-click clears",
				app.params.region[2], app.params.region[3], app.params.region[0], app.params.region[1]))
		} else if app.input.loaded {
			row_label(&r, "Drag on the input to select a part")
		}
		// Separator between toolbar and panes.
		rl.DrawRectangleRec({12, bar - 8, sw - 24, 1}, AMBER_DARK)

		// Panes
		half := (sw - 36) / 2
		left := rl.Rectangle{12, bar, half, sh - bar - foot - 8}
		right := rl.Rectangle{24 + half, bar, half, sh - bar - foot - 8}
		in_rect, out_rect := left, right
		if app.swap do in_rect, out_rect = right, left
		draw_pane(&app.input, in_rect, app.tile_input ? int(app.tiles) : 1, "Drop a texture or material set here")
		if app.input.loaded && !app.tile_input {
			// Where the image sits in its pane (same fit as draw_pane).
			iw, ih := f32(app.input.w), f32(app.input.h)
			sc := min((in_rect.width - 24) / iw, (in_rect.height - 24) / ih)
			ox := in_rect.x + (in_rect.width - iw * sc) / 2
			oy := in_rect.y + (in_rect.height - ih * sc) / 2
			img_rect := rl.Rectangle{ox, oy, iw * sc, ih * sc}
			to_screen :: proc(r: [4]int, ox, oy, sc: f32) -> rl.Rectangle {
				return {ox + f32(r[0]) * sc, oy + f32(r[1]) * sc, f32(r[2]) * sc, f32(r[3]) * sc}
			}

			// --- Selection: drag to draw, drag inside to move, right-click clears.
			mouse := rl.GetMousePosition()
			mx := clamp(int((mouse.x - ox) / sc), 0, app.input.w)
			my := clamp(int((mouse.y - oy) / sc), 0, app.input.h)
			has_sel := app.params.region[2] > 0
			sel_screen := to_screen(app.params.region, ox, oy, sc)
			over_img := rl.CheckCollisionPointRec(mouse, img_rect)
			over_sel := has_sel && rl.CheckCollisionPointRec(mouse, sel_screen)
			if rl.IsMouseButtonPressed(.LEFT) && over_img {
				if over_sel {
					app.drag = .Moving
					app.drag_from = {mx - app.params.region[0], my - app.params.region[1]}
				} else {
					app.drag = .Creating
					app.drag_from = {mx, my}
				}
			}
			if app.drag != .None && rl.IsMouseButtonDown(.LEFT) {
				switch app.drag {
				case .Creating:
					x0, y0 := min(app.drag_from.x, mx), min(app.drag_from.y, my)
					w_, h_ := abs(mx - app.drag_from.x), abs(my - app.drag_from.y)
					if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) {
						// Square, growing from the start corner.
						s := max(w_, h_)
						w_, h_ = s, s
						x0 = mx < app.drag_from.x ? app.drag_from.x - s : app.drag_from.x
						y0 = my < app.drag_from.y ? app.drag_from.y - s : app.drag_from.y
						x0, y0 = clamp(x0, 0, app.input.w), clamp(y0, 0, app.input.h)
						w_, h_ = min(w_, app.input.w - x0), min(h_, app.input.h - y0)
					}
					app.params.region = {x0, y0, w_, h_}
				case .Moving:
					r := app.params.region
					r[0] = clamp(mx - app.drag_from.x, 0, app.input.w - r[2])
					r[1] = clamp(my - app.drag_from.y, 0, app.input.h - r[3])
					app.params.region = r
				case .None:
				}
			}
			if app.drag != .None && rl.IsMouseButtonReleased(.LEFT) {
				// A plain click (no real drag) outside the selection clears it.
				if app.drag == .Creating && (app.params.region[2] < 16 || app.params.region[3] < 16) {
					app.params.region = {}
				}
				app.drag = .None
			}
			if over_img && rl.IsMouseButtonPressed(.RIGHT) do app.params.region = {}
			if !app.seed_editing && rl.IsKeyPressed(.ESCAPE) && app.params.region[2] > 0 do app.params.region = {}
			rl.SetMouseCursor(app.drag == .Moving || (app.drag == .None && over_sel) ? .RESIZE_ALL : over_img ? .CROSSHAIR : .DEFAULT)

			// --- Overlays.
			has_sel = app.params.region[2] > 0
			used := has_sel ? app.params.region : [4]int{0, 0, app.input.w, app.input.h}
			if has_sel {
				// Dim everything outside the selection.
				s := to_screen(used, ox, oy, sc)
				dim := rl.Color{0, 0, 0, 165}
				rl.DrawRectangleRec({img_rect.x, img_rect.y, img_rect.width, s.y - img_rect.y}, dim)
				rl.DrawRectangleRec({img_rect.x, s.y + s.height, img_rect.width, img_rect.y + img_rect.height - s.y - s.height}, dim)
				rl.DrawRectangleRec({img_rect.x, s.y, s.x - img_rect.x, s.height}, dim)
				rl.DrawRectangleRec({s.x + s.width, s.y, img_rect.x + img_rect.width - s.x - s.width, s.height}, dim)
				rl.DrawRectangleLinesEx(s, 2, AMBER) // your selection
			}
			// Trusted centre of the used part: thin outline.
			cw, ch := f32(used[2]) * app.params.center, f32(used[3]) * app.params.center
			cx0 := f32(used[0]) + (f32(used[2]) - cw) / 2
			cy0 := f32(used[1]) + (f32(used[3]) - ch) / 2
			rl.DrawRectangleLinesEx({ox + cx0 * sc, oy + cy0 * sc, cw * sc, ch * sc}, 1, AMBER_DIM)
			// Region the last result was made from (selection + whole repeats).
			if app.results != nil && (app.info.crop_w != app.input.w || app.info.crop_h != app.input.h) {
				r := [4]int{app.info.crop_x, app.info.crop_y, app.info.crop_w, app.info.crop_h}
				rl.DrawRectangleLinesEx(to_screen(r, ox, oy, sc), 2, WHITE) // what was actually used
			}
		}
		draw_pane(&app.output, out_rect, int(app.tiles), app.input.loaded && app.job == nil ? "Press \"Tile it\" (or Space)" : "")

		if app.job != nil {
			// Dim the old result and show progress on top.
			rl.DrawRectangleRec(out_rect, {0, 0, 0, 200})
			cx := out_rect.x + out_rect.width / 2
			cy := out_rect.y + out_rect.height / 2
			label := app.job.params.mode == .Quick ? "Working..." : "Rebuilding seams..."
			draw_text_centred(label, cx, cy - 30, 24, AMBER)
			if app.job.params.mode == .Synth {
				p := sync.atomic_load(&synth_progress)
				// Plain amber bar: outline, fill, percentage.
				bw: f32 = 320
				rl.DrawRectangleLinesEx({cx - bw / 2, cy, bw, 18}, 1, AMBER_MID)
				rl.DrawRectangleRec({cx - bw / 2 + 3, cy + 3, (bw - 6) * clamp(p, 0, 1), 12}, AMBER)
				draw_text_centred(fmt.tprintf("%d%%", int(p * 100)), cx, cy + 34, FONT_SIZE, AMBER_BRIGHT)
			}
		}

		// Status bar.
		rl.DrawRectangleRec({0, sh - foot, sw, foot}, PANEL)
		rl.DrawRectangleRec({0, sh - foot, sw, 1}, AMBER_DARK)
		draw_text(app.status, 14, sh - foot + (foot - FONT_SIZE) / 2, FONT_SIZE, AMBER)
		if shot != nil {
			rlgl.DrawRenderBatchActive() // flush queued draws so the capture is this frame
			rl.TakeScreenshot(shot)
		}
		rl.EndDrawing()
		if quit do break
	}
}
