package tileit

import "core:os"
import "core:sync"
import "core:thread"

MAX_CHUNKS :: 64

// Splits [0, count) into a number of contiguous chunks that depends only on
// count (never on the CPU), and runs fn on each chunk using a pool of threads.
// Because the chunking is fixed, per-chunk seeds and per-chunk partial sums
// give identical results on every machine. Blocks until all chunks finish.
parallel_for :: proc(count: int, data: rawptr, fn: proc(data: rawptr, begin, end, chunk: int), min_chunk := 256) {
	if count <= 0 do return
	chunks := clamp(count / max(min_chunk, 1), 1, MAX_CHUNKS)
	Shared :: struct {
		data:   rawptr,
		fn:     proc(data: rawptr, begin, end, chunk: int),
		count:  int,
		chunks: int,
		next:   int,
	}
	shared := Shared{data, fn, count, chunks, 0}
	run :: proc(s: ^Shared) {
		for {
			c := sync.atomic_add(&s.next, 1)
			if c >= s.chunks do return
			s.fn(s.data, s.count * c / s.chunks, s.count * (c + 1) / s.chunks, c)
		}
	}
	workers := clamp(os.get_processor_core_count(), 1, chunks)
	threads := make([]^thread.Thread, workers)
	defer delete(threads)
	for i in 1 ..< workers do threads[i] = thread.create_and_start_with_poly_data(&shared, run)
	run(&shared)
	for i in 1 ..< workers { thread.join(threads[i]); thread.destroy(threads[i]) }
}
