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
// Copies an environment variable into value. Returns its length, ENV_UNSET or ENV_TOO_LONG.
extern "gw_getenv" fn getenv_into(name: const u8[:], value: u8[:]) -> i64;
