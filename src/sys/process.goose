import std;
namespace web;

// Process services without importing the os stdlib (see src/sys/files.goose). Backed by
// native/posix/system.c.

// Mirror native/posix/constants.h (GW_ENV_*).
const ENV_UNSET = -1;
const ENV_TOO_LONG = -2;
// Environment values longer than this are refused. Config values are short by design.
const ENV_VALUE_MAX_BYTES = 256;

// Monotonic nanoseconds for deadlines. Used by the reactor; the value is not wall time.
extern "gw_clock_ns" fn clock_ns() -> i64;
// Wall-clock seconds since the Unix epoch, 0 when the clock is unavailable. Sessions use it for expiry.
extern "gw_unix_seconds" fn unix_seconds() -> i64;
// Copies an environment variable into value. Returns its length, ENV_UNSET or ENV_TOO_LONG.
extern "gw_getenv" fn getenv_into(name: const u8[:], value: u8[:]) -> i64;

// Worker processes (native/posix/process.c). fork gives the child a copy of this program's
// memory; the child must not use SQLite handles or other resources the parent opened.
extern "gw_fork" fn fork_process() -> i32;          // child: 0; parent: child pid; -1 on failure
extern "gw_getpid" fn process_id() -> i32;
extern "gw_cpu_count" fn cpu_count() -> i32;
extern "gw_kill" fn signal_process(pid: i32, signal: i32) -> i32;     // 0 on success
// Nonblocking reap: 0 while running, 1 when reaped, with status = exit code or 256 + signal.
extern "gw_wait_child" fn wait_child(pid: i32, status: i32&) -> i32;
// The stats record channel: "gw_pipe" creates it; records are read and written in server.goose,
// where the ServerStats type lives.
extern "gw_pipe" fn stats_pipe(read_end: i32&, write_end: i32&) -> i32;
