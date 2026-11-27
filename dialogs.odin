#+build windows
package tileit

// Native Open / Save As dialogs (Win32 common dialogs).

import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"
import rl "vendor:raylib"

@(private = "file")
ascii_w :: proc(s: string, allocator := context.temp_allocator) -> []u16 {
	out := make([]u16, len(s) + 1, allocator) // + terminating 0
	for c, i in transmute([]u8)s do out[i] = u16(c)
	return out
}

@(private = "file")
IMAGE_FILTER :: "Images (png, jpg, tga, bmp, psd, hdr)\x00*.png;*.jpg;*.jpeg;*.tga;*.bmp;*.psd;*.hdr\x00All files\x00*.*\x00"

// Lets the user pick one or more images. Returned paths are allocated.
open_files_dialog :: proc() -> (paths: [dynamic]string, ok: bool) {
	buf := make([]u16, 64 * 1024, context.temp_allocator)
	filter := ascii_w(IMAGE_FILTER)
	title := ascii_w("Open texture(s) - several maps of one material can be picked together")
	ofn := win.OPENFILENAMEW {
		lStructSize = size_of(win.OPENFILENAMEW),
		hwndOwner   = win.HWND(rl.GetWindowHandle()),
		lpstrFilter = cstring16(raw_data(filter)),
		lpstrFile   = raw_data(buf),
		nMaxFile    = u32(len(buf)),
		lpstrTitle  = cstring16(raw_data(title)),
		Flags       = win.OPEN_FLAGS_MULTI | win.OFN_NOCHANGEDIR,
	}
	if !win.GetOpenFileNameW(&ofn) do return
	// Either "full path\0\0", or "folder\0name1\0name2\0...\0\0".
	parts: [dynamic]string
	defer delete(parts)
	start := 0
	for i in 0 ..< len(buf) {
		if buf[i] != 0 do continue
		if i == start do break // double zero: end
		s, _ := win.utf16_to_utf8(buf[start:i], context.temp_allocator)
		append(&parts, s)
		start = i + 1
	}
	if len(parts) == 1 {
		append(&paths, strings.clone(parts[0]))
	} else if len(parts) > 1 {
		for name in parts[1:] {
			p, _ := filepath.join({parts[0], name}, context.allocator)
			append(&paths, p)
		}
	}
	return paths, len(paths) > 0
}

// Asks where to save; `suggested` is the initial file name/path. Allocated.
save_file_dialog :: proc(suggested: string) -> (path: string, ok: bool) {
	buf := make([]u16, 4096, context.temp_allocator)
	w := ([^]u16)(rawptr(win.utf8_to_wstring(suggested, context.temp_allocator)))
	for i := 0; i < len(buf) - 1 && w[i] != 0; i += 1 do buf[i] = w[i]
	filter := ascii_w("PNG image\x00*.png\x00")
	defext := ascii_w("png")
	title := ascii_w("Save tiled texture - other maps of the set go next to it")
	ofn := win.OPENFILENAMEW {
		lStructSize = size_of(win.OPENFILENAMEW),
		hwndOwner   = win.HWND(rl.GetWindowHandle()),
		lpstrFilter = cstring16(raw_data(filter)),
		lpstrFile   = raw_data(buf),
		nMaxFile    = u32(len(buf)),
		lpstrTitle  = cstring16(raw_data(title)),
		lpstrDefExt = cstring16(raw_data(defext)),
		Flags       = win.SAVE_FLAGS | win.OFN_NOCHANGEDIR,
	}
	if !win.GetSaveFileNameW(&ofn) do return
	s, _ := win.wstring_to_utf8(win.wstring(raw_data(buf)), -1, context.allocator)
	return s, true
}
