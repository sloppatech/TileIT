package tileit

// Minimal complex FFT: iterative radix-2 for power-of-two sizes, Bluestein's
// chirp-z algorithm for everything else (textures are often 1000px, 1536px, ...).
// Periodic-plus-smooth needs the DFT at the image's exact size, so padding is
// not an option.

import "core:math"
import "core:os"
import "core:thread"

Fft_Plan :: struct {
	n:         int,
	pow2:      bool,
	m:         int,          // radix-2 working size (n itself, or Bluestein padding)
	tw:        []complex64,  // exp(-2πik/m), k in [0, m/2)
	rev:       []i32,        // bit reversal permutation for size m
	chirp:     []complex64,  // Bluestein: exp(-iπk²/n), len n
	chirp_fft: []complex64,  // Bluestein: FFT of the conjugate chirp kernel, len m
}

is_pow2 :: proc(n: int) -> bool { return n > 0 && (n & (n - 1)) == 0 }

next_pow2 :: proc(n: int) -> int {
	m := 1
	for m < n do m <<= 1
	return m
}

fft_plan_make :: proc(n: int) -> (p: Fft_Plan) {
	p.n = n
	p.pow2 = is_pow2(n)
	p.m = p.pow2 ? n : next_pow2(2 * n - 1)
	m := p.m

	p.tw = make([]complex64, max(m / 2, 1))
	for k in 0 ..< m / 2 {
		a := -2.0 * math.PI * f64(k) / f64(m)
		p.tw[k] = complex(f32(math.cos(a)), f32(math.sin(a)))
	}
	p.rev = make([]i32, m)
	bits := 0
	for (1 << uint(bits)) < m do bits += 1
	for i in 0 ..< m {
		r := 0
		for b in 0 ..< bits do if i & (1 << uint(b)) != 0 do r |= 1 << uint(bits - 1 - b)
		p.rev[i] = i32(r)
	}

	if !p.pow2 {
		p.chirp = make([]complex64, n)
		for k in 0 ..< n {
			// k² mod 2n keeps the angle small, so f64 stays accurate for big n.
			kk := (k * k) % (2 * n)
			a := -math.PI * f64(kk) / f64(n)
			p.chirp[k] = complex(f32(math.cos(a)), f32(math.sin(a)))
		}
		p.chirp_fft = make([]complex64, m)
		p.chirp_fft[0] = conj(p.chirp[0])
		for k in 1 ..< n {
			c := conj(p.chirp[k])
			p.chirp_fft[k] = c
			p.chirp_fft[m - k] = c
		}
		radix2(p.chirp_fft, p.tw, p.rev)
	}
	return
}

fft_plan_destroy :: proc(p: ^Fft_Plan) {
	delete(p.tw); delete(p.rev); delete(p.chirp); delete(p.chirp_fft)
	p^ = {}
}

// Scratch needed by fft_forward/fft_inverse for this plan.
fft_scratch_len :: proc(p: ^Fft_Plan) -> int { return p.pow2 ? 0 : p.m }

@(private)
radix2 :: proc(a: []complex64, tw: []complex64, rev: []i32) {
	n := len(a)
	for i in 0 ..< n {
		j := int(rev[i])
		if i < j do a[i], a[j] = a[j], a[i]
	}
	for size := 2; size <= n; size *= 2 {
		half := size / 2
		step := n / size
		for start := 0; start < n; start += size {
			for k in 0 ..< half {
				t := a[start + k + half] * tw[k * step]
				u := a[start + k]
				a[start + k] = u + t
				a[start + k + half] = u - t
			}
		}
	}
}

// In-place, unnormalised forward DFT of len(data) == p.n.
fft_forward :: proc(p: ^Fft_Plan, data: []complex64, scratch: []complex64) {
	if p.pow2 {
		radix2(data, p.tw, p.rev)
		return
	}
	n, m := p.n, p.m
	a := scratch[:m]
	for k in 0 ..< n do a[k] = data[k] * p.chirp[k]
	for k in n ..< m do a[k] = 0
	radix2(a, p.tw, p.rev)
	for k in 0 ..< m do a[k] = conj(a[k] * p.chirp_fft[k]) // conj trick: inverse via forward
	radix2(a, p.tw, p.rev)
	inv_m := 1.0 / f32(m)
	for k in 0 ..< n do data[k] = conj(a[k]) * p.chirp[k] * complex(inv_m, 0)
}

// In-place inverse DFT, normalised by 1/n.
fft_inverse :: proc(p: ^Fft_Plan, data: []complex64, scratch: []complex64) {
	for &v in data do v = conj(v)
	fft_forward(p, data, scratch)
	inv_n := 1.0 / f32(p.n)
	for &v in data do v = conj(v) * complex(inv_n, 0)
}

// ---------------------------------------------------------------------------
// 2D transform over a w*h row-major buffer, rows/columns split across threads.

@(private)
Fft2_Job :: struct {
	buf:          []complex64,
	w, h:         int,
	plan:         ^Fft_Plan,
	inverse:      bool,
	columns:      bool,
	begin, end:   int,
}

@(private)
fft2_worker :: proc(job: ^Fft2_Job) {
	scratch := make([]complex64, fft_scratch_len(job.plan))
	defer delete(scratch)
	if !job.columns {
		for y in job.begin ..< job.end {
			row := job.buf[y * job.w:][:job.w]
			if job.inverse do fft_inverse(job.plan, row, scratch)
			else do fft_forward(job.plan, row, scratch)
		}
	} else {
		col := make([]complex64, job.h)
		defer delete(col)
		for x in job.begin ..< job.end {
			for y in 0 ..< job.h do col[y] = job.buf[y * job.w + x]
			if job.inverse do fft_inverse(job.plan, col, scratch)
			else do fft_forward(job.plan, col, scratch)
			for y in 0 ..< job.h do job.buf[y * job.w + x] = col[y]
		}
	}
}

@(private)
fft2_pass :: proc(buf: []complex64, w, h: int, plan: ^Fft_Plan, inverse, columns: bool) {
	count := columns ? w : h
	workers := clamp(os.get_processor_core_count(), 1, 32)
	workers = min(workers, max(count / 16, 1))
	jobs := make([]Fft2_Job, workers)
	threads := make([]^thread.Thread, workers)
	defer { delete(jobs); delete(threads) }
	for i in 0 ..< workers {
		jobs[i] = {buf, w, h, plan, inverse, columns, count * i / workers, count * (i + 1) / workers}
	}
	for i in 1 ..< workers do threads[i] = thread.create_and_start_with_poly_data(&jobs[i], fft2_worker)
	fft2_worker(&jobs[0])
	for i in 1 ..< workers { thread.join(threads[i]); thread.destroy(threads[i]) }
}

fft2 :: proc(buf: []complex64, w, h: int, row_plan, col_plan: ^Fft_Plan, inverse := false) {
	fft2_pass(buf, w, h, row_plan, inverse, false)
	fft2_pass(buf, w, h, col_plan, inverse, true)
}
