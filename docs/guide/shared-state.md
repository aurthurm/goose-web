# Sharing state between workers

This guide targets current `main`; the shared store is not in `v0.6.0`. Ordinary Goose globals
belong to one process. Starting four worker processes gives you four independent copies of
those globals, not four threads accessing the same map.

## Choose the right store

| Need | Use |
| --- | --- |
| Private settings or local caches | A namespaced per-worker global |
| Small volatile values/counters shared on one server | `web::shared_*` |
| Durable records and transactions | [SQLite](database.md), or an external service |
| Notifications to HTTP clients | [SSE](events-and-streaming.md) |
| Durable cross-host message delivery | A separate broker; not the shared event ring |

The shared store is allocated before workers fork. `ServerConfig.shared_store_bytes` is 1 MiB
by default; 0 disables it. The memory belongs to one running server instance and disappears on
restart. Calls outside a running server cannot use it.

## Store a bounded value

This handler fragment assumes the server is running with the store enabled:

```goose
fn write_banner(c: web::Ctx&) {
    if !web::shared_set("app:banner", "Maintenance at 22:00", 60000) {
        c.fail(web::HTTP_SERVICE_UNAVAILABLE, "store_unavailable", "Try again later");
        return;
    }
    c.no_content();
}

fn read_banner(c: web::Ctx&) {
    var value: u8[>..] = [];
    if !web::shared_get("app:banner", value) {
        c.fail(web::HTTP_NOT_FOUND, "banner_unavailable", "Banner is unavailable");
        return;
    }
    c.text(value[..]);
}
```

TTL is milliseconds; 0 retains a value until deletion, replacement or server restart. Check
return values. A failed get can mean missing/expired data, disabled storage or a timed-out lock;
it is not a reliable existence proof during a storage failure. Reads copy into application-owned
output. `shared_delete(key)` returns whether a live entry was removed.

`shared_incr(key, delta, ttl_ms)` atomically increments a counter and returns `value, ok`.
A new counter starts at zero; increments of an existing counter keep its original expiry, which
supports fixed windows. Do not implement an atomic increment as a get followed by a set.

## Capacity and lock behavior

Keys and values have fixed bounds, and a full stripe refuses a new key rather than evicting live
entries. Striped locks let unrelated keys proceed concurrently. Calls wait at most
`shared_lock_timeout_ms` (default 50 ms). On timeout, set/get return false, SSE publishing can
return -1, and rate limiting falls back to that worker's counters for that request.

`shared_stats()` reports `entries`, `capacity`, `stripes`, `timeouts`, `recoveries` and `ring_lost`.
Monitor timeouts and dropped ring messages; this store is not durable, replicated or unbounded.
For exact key/value/TTL limits and failure returns, see the [shared-store reference](../api.md#shared-store).
