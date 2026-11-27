package tileit

// 16-bit PNG writer. stb_image_write only writes 8-bit PNGs, which throws away
// most of a 16-bit height map's precision (terracing in displacement). The
// PNG container is simple, and the compressor is below.

import "core:hash"
import "core:os"

png16_write :: proc(img: Image, path: string) -> bool {
	comp := clamp(img.channels, 1, 4)
	colour_type: u8
	switch comp {
	case 1: colour_type = 0 // grey
	case 2: colour_type = 4 // grey + alpha
	case 3: colour_type = 2 // RGB
	case:   colour_type = 6 // RGBA
	}
	bpp := comp * 2
	stride := img.w * bpp

	// Scanlines: filter byte + big-endian 16-bit samples. "Sub" filter
	// (difference to the pixel on the left) compresses smooth maps well.
	raw := make([]u8, (stride + 1) * img.h)
	defer delete(raw)
	row := make([]u8, stride)
	defer delete(row)
	for y in 0 ..< img.h {
		for x in 0 ..< img.w {
			s := img.px[(y * img.w + x) * 4:][:4]
			vals: [4]f32
			switch comp {
			case 1: vals[0] = s[0]
			case 2: vals[0], vals[1] = s[0], s[3]
			case:   for k in 0 ..< comp do vals[k] = s[k]
			}
			for k in 0 ..< comp {
				v := u16(clamp(vals[k], 0, 1) * 65535 + 0.5)
				row[x * bpp + k * 2] = u8(v >> 8)
				row[x * bpp + k * 2 + 1] = u8(v)
			}
		}
		line := raw[y * (stride + 1):][:stride + 1]
		line[0] = 1 // Sub
		for i in 0 ..< stride do line[1 + i] = row[i] - (i >= bpp ? row[i - bpp] : 0)
	}

	z := zlib_compress(raw)
	defer delete(z)

	out := make([dynamic]u8)
	defer delete(out)
	append(&out, 137, 80, 78, 71, 13, 10, 26, 10)
	be32 :: proc(buf: ^[dynamic]u8, v: u32) { append(buf, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)) }
	chunk :: proc(buf: ^[dynamic]u8, kind: string, data: []u8) {
		be32(buf, u32(len(data)))
		start := len(buf)
		append(buf, ..transmute([]u8)kind)
		append(buf, ..data)
		be32(buf, hash.crc32(buf[start:]))
	}
	ihdr: [13]u8
	ihdr[0], ihdr[1], ihdr[2], ihdr[3] = u8(img.w >> 24), u8(img.w >> 16), u8(img.w >> 8), u8(img.w)
	ihdr[4], ihdr[5], ihdr[6], ihdr[7] = u8(img.h >> 24), u8(img.h >> 16), u8(img.h >> 8), u8(img.h)
	ihdr[8] = 16 // bit depth
	ihdr[9] = colour_type
	// compression, filter method, interlace: all 0
	chunk(&out, "IHDR", ihdr[:])
	chunk(&out, "IDAT", z)
	chunk(&out, "IEND", nil)
	return os.write_entire_file(path, out[:]) == nil
}
// --- zlib/DEFLATE compressor (RFC 1950/1951): LZ77 with hash chains, one
// block with the fixed Huffman code. Not as tight as zlib -9, but small,
// dependency-free, and fine for texture PNGs.

@(private = "file")
Bits :: struct {
	out:  [dynamic]u8,
	acc:  u64,
	n:    uint,
}

@(private = "file")
put_bits :: #force_inline proc(b: ^Bits, v: u64, n: uint) {
	b.acc |= v << b.n
	b.n += n
	for b.n >= 8 {
		append(&b.out, u8(b.acc))
		b.acc >>= 8
		b.n -= 8
	}
}

// Huffman codes are sent most-significant bit first.
@(private = "file")
put_code :: #force_inline proc(b: ^Bits, code: u32, n: uint) {
	r: u32
	for i in 0 ..< n do r |= ((code >> i) & 1) << (n - 1 - i)
	put_bits(b, u64(r), n)
}

@(private = "file")
put_litlen :: proc(b: ^Bits, v: int) {
	switch {
	case v < 144: put_code(b, u32(0x30 + v), 8)
	case v < 256: put_code(b, u32(0x190 + v - 144), 9)
	case v < 280: put_code(b, u32(v - 256), 7)
	case:         put_code(b, u32(0xC0 + v - 280), 8)
	}
}

@(private = "file")
LEN_BASE := [29]int{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
@(private = "file")
LEN_EXTRA := [29]uint{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
@(private = "file")
DIST_BASE := [30]int{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
@(private = "file")
DIST_EXTRA := [30]uint{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}

@(private = "file")
put_match :: proc(b: ^Bits, length, dist: int) {
	li := 28
	for li > 0 && LEN_BASE[li] > length do li -= 1
	put_litlen(b, 257 + li)
	put_bits(b, u64(length - LEN_BASE[li]), LEN_EXTRA[li])
	di := 29
	for di > 0 && DIST_BASE[di] > dist do di -= 1
	put_code(b, u32(di), 5)
	put_bits(b, u64(dist - DIST_BASE[di]), DIST_EXTRA[di])
}

zlib_compress :: proc(data: []u8, allocator := context.allocator) -> []u8 {
	WINDOW :: 32768
	HASH_BITS :: 15
	MAX_CHAIN :: 48
	b := Bits{out = make([dynamic]u8, allocator)}
	append(&b.out, 0x78, 0x01) // zlib header: deflate, 32K window
	put_bits(&b, 1, 1)         // BFINAL
	put_bits(&b, 1, 2)         // BTYPE = fixed Huffman

	head := make([]i32, 1 << HASH_BITS)
	prev := make([]i32, WINDOW)
	defer { delete(head); delete(prev) }
	for &h in head do h = -1
	hash3 :: #force_inline proc(d: []u8, i: int) -> int {
		v := u32(d[i]) | u32(d[i + 1]) << 8 | u32(d[i + 2]) << 16
		return int((v * 2654435761) >> (32 - HASH_BITS))
	}
	n := len(data)
	i := 0
	insert :: #force_inline proc(d: []u8, head, prev: []i32, i: int) {
		h := hash3(d, i)
		prev[i % WINDOW] = head[h]
		head[h] = i32(i)
	}
	for i < n {
		best_len, best_dist := 0, 0
		if i + 2 < n {
			cand := int(head[hash3(data, i)])
			max_len := min(258, n - i)
			for steps := 0; cand >= 0 && i - cand <= WINDOW - 1 && steps < MAX_CHAIN; steps += 1 {
				l := 0
				for l < max_len && data[cand + l] == data[i + l] do l += 1
				if l > best_len { best_len, best_dist = l, i - cand }
				if l == max_len do break
				nxt := int(prev[cand % WINDOW])
				if nxt >= cand do break
				cand = nxt
			}
		}
		if best_len >= 3 {
			put_match(&b, best_len, best_dist)
			for k in 0 ..< best_len {
				if i + k + 2 < n do insert(data, head, prev, i + k)
			}
			i += best_len
		} else {
			put_litlen(&b, int(data[i]))
			if i + 2 < n do insert(data, head, prev, i)
			i += 1
		}
	}
	put_litlen(&b, 256) // end of block
	if b.n > 0 do put_bits(&b, 0, 8 - b.n)

	// Adler-32, big-endian.
	s1, s2: u32 = 1, 0
	for v in data { s1 = (s1 + u32(v)) % 65521; s2 = (s2 + s1) % 65521 }
	adler := s2 << 16 | s1
	append(&b.out, u8(adler >> 24), u8(adler >> 16), u8(adler >> 8), u8(adler))
	return b.out[:]
}
