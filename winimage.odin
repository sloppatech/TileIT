#+build windows
package tileit

// Fallback image decoder using Windows' own GDI+ (flat C API).
//
// Why: raylib bundles its own copy of stb_image, compiled without JPEG
// support, and when both are linked the linker resolves stb's functions to
// raylib's copy - so stb can't read JPEGs inside tileit. Odin's core JPEG
// decoder doesn't do progressive JPEGs (which is what Unsplash and most web
// sources serve). GDI+ ships with every Windows and decodes them all
// (baseline, progressive, CMYK), plus TIFF and GIF.

import "core:sync"
import win "core:sys/windows"

foreign import gdiplus "system:gdiplus.lib"

@(private = "file")
Startup_Input :: struct {
	version:                    u32,
	debug_event_callback:       rawptr,
	suppress_background_thread: b32,
	suppress_external_codecs:   b32,
}

@(private = "file")
Rect :: struct { x, y, w, h: i32 }

@(private = "file")
Bitmap_Data :: struct {
	width, height: u32,
	stride:        i32,
	pixel_format:  i32,
	scan0:         rawptr,
	reserved:      uintptr,
}

@(private = "file")
PIXEL_FORMAT_32BPP_ARGB :: 0x0026200A // memory order: B, G, R, A
@(private = "file")
PIXEL_FORMAT_ALPHA :: 0x00040000
@(private = "file")
LOCK_READ :: 1

@(default_calling_convention = "system", private = "file")
foreign gdiplus {
	GdiplusStartup :: proc(token: ^uintptr, input: ^Startup_Input, output: rawptr) -> i32 ---
	GdipCreateBitmapFromFile :: proc(filename: win.LPCWSTR, bitmap: ^rawptr) -> i32 ---
	GdipGetImageWidth :: proc(image: rawptr, width: ^u32) -> i32 ---
	GdipGetImageHeight :: proc(image: rawptr, height: ^u32) -> i32 ---
	GdipGetImagePixelFormat :: proc(image: rawptr, format: ^i32) -> i32 ---
	GdipBitmapLockBits :: proc(bitmap: rawptr, rect: ^Rect, flags: u32, format: i32, data: ^Bitmap_Data) -> i32 ---
	GdipBitmapUnlockBits :: proc(bitmap: rawptr, data: ^Bitmap_Data) -> i32 ---
	GdipDisposeImage :: proc(image: rawptr) -> i32 ---
}

@(private = "file")
gdip_once: sync.Once
@(private = "file")
gdip_ok: bool

os_image_load :: proc(path: string) -> (img: Image, ok: bool) {
	sync.once_do(&gdip_once, proc() {
		token: uintptr
		input := Startup_Input{version = 1}
		gdip_ok = GdiplusStartup(&token, &input, nil) == 0
	})
	if !gdip_ok do return

	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	bmp: rawptr
	if GdipCreateBitmapFromFile(wpath, &bmp) != 0 || bmp == nil do return
	defer GdipDisposeImage(bmp)

	w, h: u32
	if GdipGetImageWidth(bmp, &w) != 0 || GdipGetImageHeight(bmp, &h) != 0 || w == 0 || h == 0 do return
	src_format: i32
	GdipGetImagePixelFormat(bmp, &src_format)
	has_alpha := src_format & PIXEL_FORMAT_ALPHA != 0

	rect := Rect{0, 0, i32(w), i32(h)}
	data: Bitmap_Data
	if GdipBitmapLockBits(bmp, &rect, LOCK_READ, PIXEL_FORMAT_32BPP_ARGB, &data) != 0 do return
	defer GdipBitmapUnlockBits(bmp, &data)

	img = image_make(int(w), int(h), has_alpha ? 4 : 3)
	for y in 0 ..< int(h) {
		row := ([^]u8)(uintptr(data.scan0) + uintptr(y * int(data.stride)))
		for x in 0 ..< int(w) {
			o := img.px[(y * int(w) + x) * 4:][:4]
			o[0] = f32(row[x * 4 + 2]) / 255
			o[1] = f32(row[x * 4 + 1]) / 255
			o[2] = f32(row[x * 4 + 0]) / 255
			o[3] = f32(row[x * 4 + 3]) / 255
		}
	}
	return img, true
}
