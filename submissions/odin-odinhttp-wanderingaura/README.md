# Odin + odin-http + SQLite

| | |
|---|---|
| Language | Odin `dev-2026-09` (official release tarball) |
| HTTP | [odin-http](https://github.com/laytan/odin-http) at `fac113f`, on Odin's `core:nbio` (io_uring), plus a small memory patch ([`patches/odin-http-pool.patch`](patches/odin-http-pool.patch)) |
| SQLite | 3.53.4 amalgamation, sha256-checked, compiled by `build.sh` and called through hand-written `foreign` bindings ([`sqlite.odin`](sqlite.odin)) |
| Deployment | **Direct**: listens on `HOST:PORT` (`0.0.0.0:80` on the box) with no Nginx |

## Running it

```bash
sudo bash install.sh   # Odin, clang, build tools
bash build.sh          # fetches the pinned odin-http and SQLite, builds bin/server
SQLITE_PATH=/path/to/feed.db JWT_SECRET=twelve-dollar-challenge HOST=0.0.0.0 PORT=80 bash start.sh
```

## Why direct

On one vCPU, Nginx takes CPU from the app and adds two socket hops to every request. Serving
directly means the server has to hold one keep-alive connection per k6 user. The patch below is
what makes that cheap. (k6 sends no `Accept-Encoding` header, so Nginx's gzip never applies
either way.)

## Design

- **Single thread, single SQLite connection.** One io_uring event loop
  (`Server_Opts.thread_count = 1`). SQLite is built with `SQLITE_THREADSAFE=0`, so it takes no
  mutexes.
- **SQLite settings.**
  - `locking_mode=EXCLUSIVE` is set before the WAL is first touched. The wal-index then lives in
    heap memory: there's no `-shm` file and no `fcntl` locking on each transaction.
  - WAL with `synchronous=NORMAL`. Writes are plain autocommit statements, so each one has
    committed before its response is sent.
  - `mmap_size=1 GiB` and a 32 MiB page cache.
- **Every request reads SQLite.** There are no response or query caches. The six statements
  are prepared once and reused. Column text is copied straight from SQLite into a preallocated
  output buffer.
- **The odin-http patch.**
  - Upstream gives each connection its own growing virtual arena: a 1 MiB reservation, which
    uses two memory mappings once committed. With Ubuntu's default `vm.max_map_count` of 65530,
    that limits the server to roughly 32k open connections.
  - The patch replaces it with a `Pool_Arena`. It borrows a 16 KiB block from a preallocated
    pool when a request starts and returns it once the response has been sent. Idle keep-alive
    connections hold no request memory and no mapping.
  - It also pre-sizes the connection map.
- **Memory is allocated once, at startup.**
  - Connection structs, scanner buffers (65,536 of each), request blocks, the output buffer and
    SQLite's page cache (`SQLITE_CONFIG_PAGECACHE`) all come from 2 MiB-aligned slabs.
  - The slabs are advised as huge pages and touched before listening, so serving doesn't
    page-fault or grow the heap.
- **Warm-up.** Before listening, full scans of the `posts` and `users` tables and of the three
  indexes the queries use fault the database pages in through SQLite's own mmap. Then each read
  statement runs 100 times. Startup takes about 0.1 s locally.
- **JWT.**
  - HS256 with SHA-NI when the CPU has it. The keyed HMAC state for `JWT_SECRET` is computed
    once and cloned per request; every token's signature is still verified.
  - Checks `alg`, `exp`, `sub` and `username` in the order the error messages need.
- **SIMD where it's cheap.**
  - JSON string escaping copies 16 bytes at a time when a chunk has no quote, backslash or
    control character.
  - Body length is counted in code points 16 bytes at a time, which matches SQLite's
    `length()` CHECK. Trimming uses the JavaScript `String.trim` whitespace set.
- **Build flags.** `-o:speed -microarch:native`, and `-march=native` for SQLite. This is safe
  because the binary is built on the machine it runs on.

## Measurements (local, not the droplet)

These were taken on a desktop CPU, with the server pinned to one core by `taskset` (for testing
only) and load sent over loopback. A droplet vCPU will be slower, and its network stack costs
more. The user/kernel split comes from the server's `/proc/<pid>/stat` under 4 parallel
keep-alive `ab` clients:

| Endpoint | req/s on one core | user µs/req | kernel µs/req |
|---|---:|---:|---:|
| `GET /feed` | 38.5k | 12.5 | 9.8 |
| `GET /posts/:id` | 62.7k | 3.3 | 8.9 |
| `GET /health` | 66.9k | 2.6 | 8.5 |

- **Where the time goes.** On the k6 request mix, about half the CPU is kernel time (socket
  syscalls and TCP). Most of the rest is SQLite running the feed query (20 index steps, each
  with a post lookup, a user lookup and a like count). Disk I/O is negligible: the database
  fits in memory, and WAL with `synchronous=NORMAL` only fsyncs at checkpoints.
- **WAL lookups.** While the WAL holds frames that haven't been checkpointed, SQLite's
  `walFindFrame` takes about 19% of user time on `/feed`. With an empty WAL, measured
  throughput was only about 3% higher, so automatic checkpoints are left at their default.
- **Connections.** 60,000 simultaneous keep-alive connections, each serving two requests,
  added 25 MB of RSS (279 → 304 MB). The process kept 49 memory mappings throughout.
- **k6.** `bench/load.js` at 15,000 users (30 s ramp, 60 s hold): 155,312 requests, 0 failed,
  p95 103 µs, p99 173 µs. The server used about 3% of its core.
  - At these user counts, one k6 machine runs out of ephemeral ports (about 28k per
    destination) before this server runs out of CPU.
- **Durability.** A post and a like survive `kill -9` right after their 201 responses.

## Layout

| File | Contents |
|---|---|
| `main.odin` | Environment, startup order, listening |
| `handlers.odin` | Routing, the five endpoints, error responses |
| `db.odin` | Pragmas, prepared statements, warm-up, queries |
| `jwt.odin` | HS256 verification |
| `json_out.odin`, `json_in.odin` | Response writer and SIMD escaping; body trim and length |
| `memory.odin` | Pre-touched slabs and the connection allocator |
| `sqlite.odin` | SQLite bindings |
| `patches/odin-http-pool.patch` | The pooled request arena for odin-http |
