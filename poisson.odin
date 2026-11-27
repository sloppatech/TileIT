package tileit

// Solver for A x = b, where A is the screened 5-point Laplacian restricted to
// a set of unknown pixels on a wrap-around grid (4 + screen on the diagonal,
// -1 per unknown neighbour; known neighbours are already folded into b).
// Used by the gradient-domain blend in synth.odin.
//
// Plain conjugate gradients, multithreaded, deterministic (fixed chunking
// and fixed-order reductions).

import "core:fmt"
_ :: fmt
import "core:math"
_ :: math

Mask_Grid :: struct {
	w, h:  int,
	cells: []i32, // pixel index of each unknown, ascending
	idx:   []i32, // pixel -> unknown index, -1 for fixed pixels
	// Screening weight: pulls x towards a data image (its weighted values go
	// into b). Bounds how far corrections spread (~1/sqrt(screen) pixels).
	screen: f32,
}

grid_make :: proc(w, h: int, cells: []i32, screen: f32 = 0) -> (G: Mask_Grid) {
	G.w, G.h = w, h
	G.screen = screen
	G.cells = make([]i32, len(cells))
	copy(G.cells, cells)
	G.idx = make([]i32, w * h)
	for &v in G.idx do v = -1
	for c, i in G.cells do G.idx[c] = i32(i)
	return
}

grid_destroy :: proc(G: ^Mask_Grid) {
	delete(G.cells); delete(G.idx)
	G^ = {}
}

@(private = "file")
wrapg :: #force_inline proc "contextless" (v, n: int) -> int {
	r := v % n
	return r < 0 ? r + n : r
}

@(private = "file")
apply_A :: #force_inline proc "contextless" (G: ^Mask_Grid, v: [][4]f32, i: int) -> [4]f32 {
	q := int(G.cells[i])
	x, y := q % G.w, q / G.w
	s := (4 + G.screen) * v[i]
	j := G.idx[y * G.w + wrapg(x + 1, G.w)]; if j >= 0 do s -= v[j]
	j = G.idx[y * G.w + wrapg(x - 1, G.w)];  if j >= 0 do s -= v[j]
	j = G.idx[wrapg(y + 1, G.h) * G.w + x];  if j >= 0 do s -= v[j]
	j = G.idx[wrapg(y - 1, G.h) * G.w + x];  if j >= 0 do s -= v[j]
	return s
}

@(private = "file")
CG :: struct {
	G:                 ^Mask_Grid,
	b, x, r, p, Ap:    [][4]f32,
	partial:           [MAX_CHUNKS][4]f64,
	alpha, beta:       [4]f32,
}

@(private = "file")
CHUNK :: 4096

@(private = "file")
sum_partials :: proc(S: ^CG) -> (s: [4]f64) {
	for &v in S.partial { s += v; v = {} } // fixed order: deterministic
	return
}

@(private = "file")
cg_residual :: proc(data: rawptr, begin, end, chunk: int) {
	S := (^CG)(data)
	acc: [4]f64
	for i in begin ..< end {
		r := S.b[i] - apply_A(S.G, S.x, i)
		S.r[i] = r
		S.p[i] = r
		for c in 0 ..< 4 do acc[c] += f64(r[c] * r[c])
	}
	S.partial[chunk] = acc
}

@(private = "file")
cg_matvec :: proc(data: rawptr, begin, end, chunk: int) {
	S := (^CG)(data)
	acc: [4]f64
	for i in begin ..< end {
		ap := apply_A(S.G, S.p, i)
		S.Ap[i] = ap
		for c in 0 ..< 4 do acc[c] += f64(S.p[i][c] * ap[c])
	}
	S.partial[chunk] = acc
}

@(private = "file")
cg_update :: proc(data: rawptr, begin, end, chunk: int) {
	S := (^CG)(data)
	acc: [4]f64
	for i in begin ..< end {
		S.x[i] += S.alpha * S.p[i]
		S.r[i] -= S.alpha * S.Ap[i]
		for c in 0 ..< 4 do acc[c] += f64(S.r[i][c] * S.r[i][c])
	}
	S.partial[chunk] = acc
}

@(private = "file")
cg_direction :: proc(data: rawptr, begin, end, chunk: int) {
	S := (^CG)(data)
	for i in begin ..< end do S.p[i] = S.r[i] + S.beta * S.p[i]
}

@(private = "file")
cg_bnorm :: proc(data: rawptr, begin, end, chunk: int) {
	S := (^CG)(data)
	acc: [4]f64
	for i in begin ..< end do for c in 0 ..< 4 do acc[c] += f64(S.b[i][c] * S.b[i][c])
	S.partial[chunk] = acc
}

// Conjugate gradients, warm-started from x. Stops when ‖r‖ < tol·‖b‖ for
// every colour channel, or after max_iters.
cg_solve :: proc(G: ^Mask_Grid, x, b: [][4]f32, max_iters: int, tol: f64) -> (iters: int) {
	n := len(G.cells)
	if n == 0 do return
	bufs := make([][4]f32, 3 * n)
	defer delete(bufs)
	S := CG{G = G, b = b, x = x, r = bufs[0:n], p = bufs[n:2 * n], Ap = bufs[2 * n:3 * n]}

	parallel_for(n, &S, cg_bnorm, CHUNK)
	bb := sum_partials(&S)
	parallel_for(n, &S, cg_residual, CHUNK)
	rs := sum_partials(&S)
	done :: proc(rs, bb: [4]f64, tol: f64) -> bool {
		for c in 0 ..< 3 do if rs[c] > tol * tol * bb[c] + 1e-20 do return false
		return true
	}
	for iters = 0; iters < max_iters && !done(rs, bb, tol); iters += 1 {
		parallel_for(n, &S, cg_matvec, CHUNK)
		pap := sum_partials(&S)
		for c in 0 ..< 4 do S.alpha[c] = pap[c] > 1e-30 ? f32(rs[c] / pap[c]) : 0
		parallel_for(n, &S, cg_update, CHUNK)
		rs_new := sum_partials(&S)
		for c in 0 ..< 4 do S.beta[c] = rs[c] > 1e-30 ? f32(rs_new[c] / rs[c]) : 0
		rs = rs_new
		parallel_for(n, &S, cg_direction, CHUNK)
	}
	when #config(TILEIT_TRACE, false) {
		fmt.printfln("  cg %8d unknowns: %4d iters, rel residual %.1e", n, iters, math.sqrt(rs[0] / max(bb[0], 1e-30)))
	}
	return
}

// Relative residual target. Against a fully converged solve (1e-6) this is
// within ~2/255 per pixel on a 2048² texture, which is invisible.
POISSON_TOL :: #config(TILEIT_TOL, 3e-5)

// Warm-started CG is enough here: the voted image is already close, and the
// screening term keeps the system well conditioned, so it converges quickly.
// (A coarse-to-fine cascade was tried for the unscreened version and was less
// accurate, because coarse cells straddle the band boundary.)
poisson_solve :: proc(G: ^Mask_Grid, x, b: [][4]f32) {
	cg_solve(G, x, b, 3000, POISSON_TOL)
}
