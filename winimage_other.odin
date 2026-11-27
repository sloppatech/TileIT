#+build !windows
package tileit

// No system decoder fallback outside Windows (see winimage.odin).
os_image_load :: proc(path: string) -> (img: Image, ok: bool) {
	return
}
