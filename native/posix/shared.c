/* Shared memory store (src/sys/shared.goose). One anonymous MAP_SHARED mapping is created before any fork,
   so every worker process sees the same key/value table, the same SSE ring and the same stream registry.

   Locks. The key/value table is split into stripes: at most GW_SHARED_STRIPES_MAX, a power of two, fewer when
   the store is small (each stripe keeps at least GW_SHARED_MIN_SLOTS_PER_STRIPE slots). Stripe s owns the
   contiguous slots [first, first + count) and one process-shared robust mutex. A key lives in stripe
   hash & (stripes - 1) and is probed only within that stripe, so calls on different stripes never wait for
   each other. The SSE ring and the stream registry each have their own lock.

   Timeouts. Every lock is taken with pthread_mutex_timedlock and a CLOCK_REALTIME deadline of
   lock_timeout_ms (ServerConfig.shared_lock_timeout_ms). A holder that is stopped or stalled makes the
   waiting call fail (-1, or 0 where the call has no failure value) after that wait, instead of stalling every
   worker. Each timed-out wait is counted in the header.

   Recovery. A process that dies holding a lock hands it to the next locker with EOWNERDEAD. That locker makes
   the mutex consistent and, for a stripe, drops the dirty slots of that stripe (the ring and the registry need
   no repair). Recoveries are counted in the header.

   Critical sections make no syscalls. The only loops are bounded: one stripe's probe, the ring records a
   message needs to make room, and the registry. The liveness checks of the stream registry (kill) run after
   the lock is released.

   Each function borrows its arguments for the call only and retains no Goose pointers. The mapping pointer is
   the store's own memory. */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include "constants.h"

typedef struct { uint8_t *data; int64_t len; } gw_bytes;

/* Mirrors src/sys/shared.goose. */
#define GW_SHARED_MIN_BYTES 262144
#define GW_SHARED_MAX_BYTES 268435456
#define GW_SHARED_KEY_BYTES 128
#define GW_SHARED_VALUE_BYTES 1024
#define GW_SHARED_TTL_MAX_MS 31536000000LL
#define GW_SHARED_STREAMS 2048
#define GW_SHARED_MAGIC_VALUE 0x47534832u
#define GW_SHARED_VERSION 2
#define GW_SHARED_RECORD_BYTES 16
#define GW_SHARED_SKIP_LEN 0xFFFFFFFFu
#define GW_SLOT_EMPTY 0
#define GW_SLOT_USED 1
#define GW_SLOT_TOMB 2
/* Stripes of the key/value table. Build with -DGW_SHARED_STRIPES_MAX=1 for one lock over the whole table,
   which is the baseline the contention test compares against. Must be a power of two. */
#ifndef GW_SHARED_STRIPES_MAX
#define GW_SHARED_STRIPES_MAX 16
#endif
#define GW_SHARED_MIN_SLOTS_PER_STRIPE 16
/* Mirrors ServerConfig.shared_lock_timeout_ms (DEFAULT, MIN 1, MAX 10000). */
#define GW_SHARED_LOCK_TIMEOUT_DEFAULT_MS 50
#define GW_SHARED_LOCK_TIMEOUT_MAX_MS 10000

typedef struct {
    uint8_t state;
    uint8_t dirty; /* set while a write is in progress; recovery drops such a slot */
    uint16_t key_len;
    uint16_t value_len;
    uint32_t reserved;
    int64_t expires_ms; /* CLOCK_MONOTONIC milliseconds; 0 means no expiry */
    uint8_t key[GW_SHARED_KEY_BYTES];
    uint8_t value[GW_SHARED_VALUE_BYTES];
} gw_slot;

/* One live event stream: the connection slot in the process that owns it. */
typedef struct {
    int32_t pid;
    int32_t slot;
    int32_t channel;
    int32_t used;
} gw_stream;

/* One stripe: a robust mutex and the slots it guards. */
typedef struct {
    pthread_mutex_t lock;
    uint64_t first;
    uint64_t count;
} gw_stripe;

/* The header sits at offset 0. Ring positions are monotonic byte offsets: physical = position % ring_bytes.
   A ring record is { uint32 len, int32 channel, int64 seq } followed by len bytes, padded to 8. A wrap
   leaves a skip record (len = GW_SHARED_SKIP_LEN) or, when fewer than 16 bytes remain, an implicit gap. */
typedef struct {
    uint32_t magic;
    uint32_t version;
    uint64_t bytes;
    uint64_t slot_count;
    uint64_t stream_count;
    uint64_t table_offset;
    uint64_t streams_offset;
    uint64_t ring_offset;
    uint64_t ring_bytes;
    uint64_t stripe_count;
    int64_t lock_timeout_ms; /* a timed lock wait gives up after this long */
    int64_t timeouts;        /* timed lock waits that gave up (updated atomically) */
    int64_t recovered;       /* locks taken over from a dead owner (updated atomically) */
    uint64_t ring_write;     /* next position to write; everything below it is committed */
    uint64_t ring_oldest;    /* oldest position still intact; records below it were overwritten */
    int64_t ring_seq;        /* sequence number of the last committed record; 0 when none */
    int64_t ring_oldest_seq; /* sequence number of the record at ring_oldest */
    int64_t lost;            /* messages overwritten before a reader took them */
    pthread_mutex_t ring_lock;
    pthread_mutex_t streams_lock;
    gw_stripe stripes[GW_SHARED_STRIPES_MAX];
} gw_shared_header;

static gw_shared_header *shared_base = NULL;
static uint64_t shared_bytes = 0;
static int64_t lock_timeout_setting = GW_SHARED_LOCK_TIMEOUT_DEFAULT_MS;

static uint64_t align8(uint64_t n) { return (n + 7) & ~(uint64_t)7; }

static uint64_t round_up(uint64_t n, uint64_t unit) { return (n + unit - 1) / unit * unit; }

static gw_slot *table_of(gw_shared_header *h) { return (gw_slot *)((uint8_t *)h + h->table_offset); }
static gw_stream *streams_of(gw_shared_header *h) { return (gw_stream *)((uint8_t *)h + h->streams_offset); }
static uint8_t *ring_of(gw_shared_header *h) { return (uint8_t *)h + h->ring_offset; }
static uint64_t ring_capacity(gw_shared_header *h) { return h->ring_bytes; }

static int64_t monotonic_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int valid_key(gw_bytes key) { return key.len >= 1 && key.len <= GW_SHARED_KEY_BYTES && key.data != NULL; }

static uint64_t hash_key(const uint8_t *key, uint64_t len) {
    uint64_t h = 1469598103934665603ULL; /* FNV-1a, 64-bit */
    for (uint64_t i = 0; i < len; ++i) {
        h ^= key[i];
        h *= 1099511628211ULL;
    }
    return h;
}

static uint64_t stripe_of(gw_shared_header *h, uint64_t hv) { return hv & (h->stripe_count - 1); }

static int slot_expired(const gw_slot *s, int64_t now) { return s->expires_ms != 0 && now >= s->expires_ms; }

static void bump(int64_t *counter) { __atomic_fetch_add(counter, 1, __ATOMIC_RELAXED); }

/* Recovery after a dead owner of stripe s: a slot still marked dirty was being written. A slot that held a
   value becomes a tombstone; a dirty empty slot just clears its flag. Only the stripe's own slots are touched. */
static void recover_stripe(gw_shared_header *h, uint64_t s) {
    gw_slot *table = table_of(h);
    const gw_stripe *st = &h->stripes[s];
    for (uint64_t i = st->first; i < st->first + st->count; ++i) {
        if (!table[i].dirty) continue;
        if (table[i].state == GW_SLOT_USED) table[i].state = GW_SLOT_TOMB;
        table[i].dirty = 0;
    }
}

/* Takes lock within lock_timeout_ms. stripe is the stripe whose slots the lock guards, or -1 for the ring and
   the stream registry. Returns 0 with the lock held. Returns -1 after a timeout, or when the lock cannot be
   made consistent (then it is released and stays unusable). A dead previous owner is recovered here. */
static int timed_lock(gw_shared_header *h, pthread_mutex_t *lock, int64_t stripe) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    int64_t nanos = (int64_t)deadline.tv_nsec + h->lock_timeout_ms * 1000000LL;
    deadline.tv_sec += (time_t)(nanos / 1000000000LL);
    deadline.tv_nsec = (long)(nanos % 1000000000LL);
    int rc = pthread_mutex_timedlock(lock, &deadline);
    if (rc == 0) return 0;
    if (rc == EOWNERDEAD) {
        if (pthread_mutex_consistent(lock) != 0) {
            pthread_mutex_unlock(lock);
            return -1;
        }
        if (stripe >= 0) recover_stripe(h, (uint64_t)stripe);
        bump(&h->recovered);
        return 0;
    }
    if (rc == ETIMEDOUT) bump(&h->timeouts);
    return -1;
}

static void unlock_stripe(gw_shared_header *h, uint64_t s) { pthread_mutex_unlock(&h->stripes[s].lock); }

/* Probes for key within stripe s, from its home slot. *match is the slot holding key (live or expired), or -1.
   *free_slot is the first slot a new entry may take (empty, tombstone or expired), or -1. A key sits in at
   most one slot: an expired entry stays where it is until reused, and expiry is permanent, so a later insert
   of the same key cannot land in another slot. The probe visits each slot of the stripe at most once. */
static void probe(gw_shared_header *h, uint64_t s, uint64_t hv, const uint8_t *key, uint64_t len, int64_t now,
                  int64_t *match, int64_t *free_slot) {
    gw_slot *table = table_of(h);
    const gw_stripe *st = &h->stripes[s];
    uint64_t n = st->count;
    uint64_t i = (hv >> 32) % n;
    *match = -1;
    *free_slot = -1;
    for (uint64_t step = 0; step < n; ++step) {
        uint64_t at = st->first + i;
        gw_slot *slot = &table[at];
        if (slot->state == GW_SLOT_EMPTY) {
            if (*free_slot < 0) *free_slot = (int64_t)at;
            break;
        }
        if (slot->state == GW_SLOT_TOMB || slot_expired(slot, now)) {
            if (*free_slot < 0) *free_slot = (int64_t)at;
        }
        if (slot->state == GW_SLOT_USED && slot->key_len == len && memcmp(slot->key, key, len) == 0) {
            *match = (int64_t)at;
            break;
        }
        i = (i + 1) % n;
    }
}

/* Locks the stripe that key hashes to and probes it. Returns the stripe (held), or -1 when the lock was not
   had in time. */
static int64_t lock_and_probe(gw_shared_header *h, gw_bytes key, int64_t now, int64_t *match, int64_t *free_slot) {
    uint64_t hv = hash_key(key.data, (uint64_t)key.len);
    uint64_t s = stripe_of(h, hv);
    if (timed_lock(h, &h->stripes[s].lock, (int64_t)s) != 0) return -1;
    probe(h, s, hv, key.data, (uint64_t)key.len, now, match, free_slot);
    return (int64_t)s;
}

/* Writes an entry in place. The dirty flag brackets the write, so a crash in the middle is detectable. */
static void write_slot(gw_slot *s, const uint8_t *key, uint64_t key_len, const uint8_t *value, uint64_t value_len, int64_t expires_ms) {
    s->dirty = 1;
    __sync_synchronize();
    memcpy(s->key, key, key_len);
    memcpy(s->value, value, value_len);
    s->key_len = (uint16_t)key_len;
    s->value_len = (uint16_t)value_len;
    s->expires_ms = expires_ms;
    s->state = GW_SLOT_USED;
    __sync_synchronize();
    s->dirty = 0;
}

/* ---- Lifecycle ----------------------------------------------------------------------------- */

/* Creates the store, replacing any earlier one. bytes = 0 removes it (the store is disabled).
   serve_config calls this before any fork, so workers inherit the mapping. Returns 0, or -1 when the
   size is out of range or the mapping or locks cannot be made. */
int32_t gw_shared_open(int64_t bytes) {
    if (shared_base != NULL) {
        munmap(shared_base, (size_t)shared_bytes);
        shared_base = NULL;
        shared_bytes = 0;
    }
    if (bytes == 0) return 0;
    if (bytes < GW_SHARED_MIN_BYTES || bytes > GW_SHARED_MAX_BYTES) return -1;
    uint64_t total = (uint64_t)bytes;
    uint64_t header_bytes = round_up(sizeof(gw_shared_header), 64);
    uint64_t streams_bytes = (uint64_t)GW_SHARED_STREAMS * sizeof(gw_stream);
    if (total < header_bytes + streams_bytes + sizeof(gw_slot) * GW_SHARED_MIN_SLOTS_PER_STRIPE) return -1;
    uint64_t avail = total - header_bytes - streams_bytes;
    uint64_t ring_bytes = (avail / 4) & ~(uint64_t)7;
    uint64_t table_bytes = avail - ring_bytes;
    uint64_t slot_count = table_bytes / sizeof(gw_slot);
    if (slot_count < GW_SHARED_MIN_SLOTS_PER_STRIPE) return -1;
    uint64_t stripes = GW_SHARED_STRIPES_MAX;
    while (stripes > 1 && slot_count / stripes < GW_SHARED_MIN_SLOTS_PER_STRIPE) stripes /= 2;
    void *memory = mmap(NULL, (size_t)total, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (memory == MAP_FAILED) return -1;
    gw_shared_header *h = memory;
    h->magic = GW_SHARED_MAGIC_VALUE;
    h->version = GW_SHARED_VERSION;
    h->bytes = total;
    h->slot_count = slot_count;
    h->stream_count = GW_SHARED_STREAMS;
    h->table_offset = header_bytes + streams_bytes;
    h->streams_offset = header_bytes;
    h->ring_bytes = ring_bytes;
    h->ring_offset = h->table_offset + slot_count * sizeof(gw_slot);
    h->stripe_count = stripes;
    h->lock_timeout_ms = lock_timeout_setting;
    h->timeouts = 0;
    h->recovered = 0;
    h->ring_write = 0;
    h->ring_oldest = 0;
    h->ring_seq = 0;
    h->ring_oldest_seq = 1;
    h->lost = 0;
    pthread_mutexattr_t attr;
    if (pthread_mutexattr_init(&attr) != 0) { munmap(memory, (size_t)total); return -1; }
    int ok = pthread_mutexattr_setpshared(&attr, PTHREAD_PROCESS_SHARED) == 0 &&
             pthread_mutexattr_setrobust(&attr, PTHREAD_MUTEX_ROBUST) == 0 &&
             pthread_mutex_init(&h->ring_lock, &attr) == 0 &&
             pthread_mutex_init(&h->streams_lock, &attr) == 0;
    for (uint64_t s = 0; ok && s < stripes; ++s) {
        h->stripes[s].first = s * slot_count / stripes;
        h->stripes[s].count = (s + 1) * slot_count / stripes - h->stripes[s].first;
        ok = pthread_mutex_init(&h->stripes[s].lock, &attr) == 0;
    }
    pthread_mutexattr_destroy(&attr);
    if (!ok) { munmap(memory, (size_t)total); return -1; }
    shared_base = h;
    shared_bytes = total;
    return 0;
}

int32_t gw_shared_enabled(void) { return shared_base != NULL ? 1 : 0; }

/* Sets how long a lock wait may last, in milliseconds (1..10000). Applies to this store now and to the next
   one opened. Returns 0, or -1 when out of range. */
int32_t gw_shared_set_lock_timeout(int64_t ms) {
    if (ms < 1 || ms > GW_SHARED_LOCK_TIMEOUT_MAX_MS) return -1;
    lock_timeout_setting = ms;
    if (shared_base != NULL) shared_base->lock_timeout_ms = ms;
    return 0;
}

/* ---- Key/value entries ---------------------------------------------------------------------- */

/* 1 stored, 0 when the key's stripe has no room for a new key, -1 when refused (no store, bad key or value,
   bad ttl) or the stripe lock could not be had in time. ttl_ms 0 keeps the entry until it is deleted or
   replaced. */
int32_t gw_shared_set(gw_bytes key, gw_bytes value, int64_t ttl_ms) {
    if (shared_base == NULL || !valid_key(key) || value.len < 0 || value.len > GW_SHARED_VALUE_BYTES) return -1;
    if (ttl_ms < 0 || ttl_ms > GW_SHARED_TTL_MAX_MS) return -1;
    gw_shared_header *h = shared_base;
    int64_t now = monotonic_ms();
    int64_t match, free_slot;
    int64_t s = lock_and_probe(h, key, now, &match, &free_slot);
    if (s < 0) return -1;
    int32_t status = 0;
    int64_t at = match >= 0 ? match : free_slot;
    if (at >= 0) {
        write_slot(&table_of(h)[at], key.data, (uint64_t)key.len, value.data, (uint64_t)value.len,
                   ttl_ms > 0 ? now + ttl_ms : 0);
        status = 1;
    }
    unlock_stripe(h, (uint64_t)s);
    return status;
}

/* The value length, copying min(length, out.len) bytes into out. -1 when the key is absent, expired,
   the store is off or the stripe lock could not be had in time. A length above out.len means the copy was
   truncated. */
int64_t gw_shared_get(gw_bytes key, gw_bytes out) {
    if (shared_base == NULL || !valid_key(key) || out.len < 0) return -1;
    gw_shared_header *h = shared_base;
    int64_t now = monotonic_ms();
    int64_t match, free_slot;
    int64_t s = lock_and_probe(h, key, now, &match, &free_slot);
    if (s < 0) return -1;
    if (match < 0 || slot_expired(&table_of(h)[match], now)) { unlock_stripe(h, (uint64_t)s); return -1; }
    const gw_slot *slot = &table_of(h)[match];
    int64_t length = slot->value_len;
    int64_t copy = length < out.len ? length : out.len;
    if (copy > 0) memcpy(out.data, slot->value, (size_t)copy);
    unlock_stripe(h, (uint64_t)s);
    return length;
}

/* 1 when a live entry was removed, 0 when there was none, -1 when refused or the stripe lock timed out. */
int32_t gw_shared_delete(gw_bytes key) {
    if (shared_base == NULL || !valid_key(key)) return -1;
    gw_shared_header *h = shared_base;
    int64_t now = monotonic_ms();
    int64_t match, free_slot;
    int64_t s = lock_and_probe(h, key, now, &match, &free_slot);
    if (s < 0) return -1;
    int32_t removed = 0;
    if (match >= 0 && !slot_expired(&table_of(h)[match], now)) {
        table_of(h)[match].state = GW_SLOT_TOMB;
        removed = 1;
    }
    unlock_stripe(h, (uint64_t)s);
    return removed;
}

/* Adds delta to a counter under the stripe lock. A missing or expired key starts from 0 and gets ttl_ms (0:
   no expiry); an existing counter keeps its expiry, so a fixed window ends when it was opened. The
   counter is stored as a native 8-byte integer. Writes *value (the new count) and *remaining_ms (time
   until expiry, 0 when none). Returns 1, 0 when the stripe is full, or -1 when refused, on overflow, or when
   the stripe lock timed out. */
int32_t gw_shared_incr(gw_bytes key, int64_t delta, int64_t ttl_ms, int64_t *value, int64_t *remaining_ms) {
    if (shared_base == NULL || !valid_key(key) || ttl_ms < 0 || ttl_ms > GW_SHARED_TTL_MAX_MS) return -1;
    gw_shared_header *h = shared_base;
    int64_t now = monotonic_ms();
    int64_t match, free_slot;
    int64_t s = lock_and_probe(h, key, now, &match, &free_slot);
    if (s < 0) return -1;
    int live = match >= 0 && !slot_expired(&table_of(h)[match], now);
    if (!live && match < 0 && free_slot < 0) { unlock_stripe(h, (uint64_t)s); return 0; }
    if (live && table_of(h)[match].value_len != sizeof(int64_t)) { unlock_stripe(h, (uint64_t)s); return -1; }
    gw_slot *slot;
    int64_t current = 0;
    int64_t expires;
    if (live) {
        slot = &table_of(h)[match];
        memcpy(&current, slot->value, sizeof(int64_t));
        expires = slot->expires_ms;
    } else {
        slot = &table_of(h)[match >= 0 ? match : free_slot];
        expires = ttl_ms > 0 ? now + ttl_ms : 0;
    }
    int32_t status = 1;
    if ((delta > 0 && current > INT64_MAX - delta) || (delta < 0 && current < INT64_MIN - delta)) {
        status = -1;
    } else {
        int64_t next = current + delta;
        uint8_t bytes[sizeof(int64_t)];
        memcpy(bytes, &next, sizeof(int64_t));
        write_slot(slot, key.data, (uint64_t)key.len, bytes, sizeof(int64_t), expires);
        *value = next;
        *remaining_ms = expires > 0 ? expires - now : 0;
    }
    unlock_stripe(h, (uint64_t)s);
    return status;
}

/* ---- SSE ring -------------------------------------------------------------------------------- */

static int lock_ring(gw_shared_header *h) { return timed_lock(h, &h->ring_lock, -1); }
static void unlock_ring(gw_shared_header *h) { pthread_mutex_unlock(&h->ring_lock); }

static void ring_write_header(gw_shared_header *h, uint64_t phys, uint32_t len, int32_t channel, int64_t seq) {
    uint8_t *at = ring_of(h) + phys;
    memcpy(at, &len, 4);
    memcpy(at + 4, &channel, 4);
    memcpy(at + 8, &seq, 8);
}

static void ring_read_header(gw_shared_header *h, uint64_t phys, uint32_t *len, int32_t *channel, int64_t *seq) {
    const uint8_t *at = ring_of(h) + phys;
    memcpy(len, at, 4);
    memcpy(channel, at + 4, 4);
    memcpy(seq, at + 8, 8);
}

/* Moves ring_oldest past its record, or past a wrap gap. The record's sequence number is kept as
   ring_oldest_seq, so a reader that fell behind can count what it missed. */
static void ring_drop_oldest(gw_shared_header *h) {
    uint64_t phys = h->ring_oldest % ring_capacity(h);
    uint64_t rest = ring_capacity(h) - phys;
    if (rest < GW_SHARED_RECORD_BYTES) { h->ring_oldest += rest; return; }
    uint32_t len;
    int32_t channel;
    int64_t seq;
    ring_read_header(h, phys, &len, &channel, &seq);
    if (len == GW_SHARED_SKIP_LEN) { h->ring_oldest += rest; return; }
    h->ring_oldest += align8(GW_SHARED_RECORD_BYTES + len);
    h->ring_oldest_seq = seq + 1;
}

/* Makes room for the span up to end by dropping records from the oldest end. At most one step per record
   in the ring, so the loop is bounded by the ring size. */
static void ring_reserve(gw_shared_header *h, uint64_t end) {
    while (end - h->ring_oldest > ring_capacity(h)) ring_drop_oldest(h);
}

/* Appends one message to the ring and returns its sequence number (1, 2, ...), or -1 when it cannot
   fit at all (larger than the ring, or no store) or the ring lock timed out. Older messages are overwritten,
   never waited for. */
int64_t gw_shared_ring_push(int32_t channel, gw_bytes bytes) {
    if (shared_base == NULL || bytes.len < 0 || bytes.len > (int64_t)GW_SHARED_MAX_BYTES) return -1;
    uint64_t need = align8(GW_SHARED_RECORD_BYTES + (uint64_t)bytes.len);
    gw_shared_header *h = shared_base;
    if (need > ring_capacity(h)) return -1;
    if (lock_ring(h) != 0) return -1;
    uint64_t pos = h->ring_write;
    uint64_t phys = pos % ring_capacity(h);
    uint64_t rest = ring_capacity(h) - phys;
    if (rest < need) {
        /* Wrap: the tail of the ring becomes a gap, committed before the record is written. */
        ring_reserve(h, pos + rest);
        if (rest >= GW_SHARED_RECORD_BYTES) ring_write_header(h, phys, GW_SHARED_SKIP_LEN, 0, 0);
        pos += rest;
        h->ring_write = pos;
        phys = 0;
    }
    ring_reserve(h, pos + need);
    ring_write_header(h, phys, (uint32_t)bytes.len, channel, h->ring_seq + 1);
    if (bytes.len > 0) memcpy(ring_of(h) + phys + GW_SHARED_RECORD_BYTES, bytes.data, (size_t)bytes.len);
    h->ring_seq += 1;
    h->ring_write = pos + need;
    int64_t seq = h->ring_seq;
    unlock_ring(h);
    return seq;
}

/* Where a new reader starts: the current end of the ring, so it sees only messages pushed later. When the
   ring lock cannot be had in time, the position is -1: the reader adopts the end at its first successful read
   (gw_shared_ring_read), so it still skips the messages published before it started. */
void gw_shared_ring_head(int64_t *position, int64_t *seq) {
    *position = 0;
    *seq = 0;
    if (shared_base == NULL) return;
    gw_shared_header *h = shared_base;
    if (lock_ring(h) != 0) { *position = -1; return; }
    *position = (int64_t)h->ring_write;
    *seq = h->ring_seq;
    unlock_ring(h);
}

/* Reads the next message after the reader's position into out and returns its length, writing its
   channel and sequence number and advancing *position and *seq. Returns 0 when caught up, and -1 when
   out is too small (nothing is consumed), when there is no store, or when the ring lock timed out (nothing
   is consumed; try again). A reader that fell behind skips to the oldest intact message and adds the
   messages it missed to the lost count. A reader with position -1 (see gw_shared_ring_head) starts at the
   current end and returns 0. */
int64_t gw_shared_ring_read(int64_t *position, int64_t *seq, int32_t *channel, gw_bytes out) {
    if (shared_base == NULL || out.len < 0) return -1;
    gw_shared_header *h = shared_base;
    if (lock_ring(h) != 0) return -1;
    if (*position < 0) {
        *position = (int64_t)h->ring_write;
        *seq = h->ring_seq;
        unlock_ring(h);
        return 0;
    }
    if ((uint64_t)*position < h->ring_oldest) {
        if (h->ring_oldest_seq - 1 > *seq) h->lost += h->ring_oldest_seq - 1 - *seq;
        *position = (int64_t)h->ring_oldest;
        *seq = h->ring_oldest_seq - 1;
    }
    for (;;) {
        if ((uint64_t)*position >= h->ring_write) { unlock_ring(h); return 0; }
        uint64_t phys = (uint64_t)*position % ring_capacity(h);
        uint64_t rest = ring_capacity(h) - phys;
        if (rest < GW_SHARED_RECORD_BYTES) { *position += (int64_t)rest; continue; }
        uint32_t len;
        int32_t record_channel;
        int64_t record_seq;
        ring_read_header(h, phys, &len, &record_channel, &record_seq);
        if (len == GW_SHARED_SKIP_LEN) { *position += (int64_t)rest; continue; }
        if ((int64_t)len > out.len) { unlock_ring(h); return -1; }
        if (len > 0) memcpy(out.data, ring_of(h) + phys + GW_SHARED_RECORD_BYTES, len);
        *position += (int64_t)align8(GW_SHARED_RECORD_BYTES + len);
        *seq = record_seq;
        *channel = record_channel;
        unlock_ring(h);
        return (int64_t)len;
    }
}

/* Messages overwritten before some reader took them, summed over all readers. 0 when the store is off or the
   ring lock timed out. */
int64_t gw_shared_lost(void) {
    if (shared_base == NULL) return 0;
    gw_shared_header *h = shared_base;
    if (lock_ring(h) != 0) return 0;
    int64_t lost = h->lost;
    unlock_ring(h);
    return lost;
}

/* ---- Stream registry ------------------------------------------------------------------------- */

static int lock_streams(gw_shared_header *h) { return timed_lock(h, &h->streams_lock, -1); }
static void unlock_streams(gw_shared_header *h) { pthread_mutex_unlock(&h->streams_lock); }

static int process_alive(int32_t pid) {
    if (pid == (int32_t)getpid()) return 1;
    return kill((pid_t)pid, 0) == 0 || errno == EPERM;
}

static int64_t free_stream(gw_shared_header *h) {
    gw_stream *streams = streams_of(h);
    for (uint64_t i = 0; i < h->stream_count; ++i) {
        if (!streams[i].used) return (int64_t)i;
    }
    return -1;
}

/* Clears entries of processes that no longer exist: a crashed worker never removes its streams. kill() is a
   syscall, so the pids are copied out under the lock, checked with the lock released, and then an entry is
   cleared only if it still holds the same dead pid. Lock waits are bounded as usual; when one times out the
   pass is abandoned and the registry stays as it was. */
static void prune_dead_streams(gw_shared_header *h) {
    int32_t pids[GW_SHARED_STREAMS];
    uint8_t dead[GW_SHARED_STREAMS];
    uint64_t n = h->stream_count;
    if (lock_streams(h) != 0) return;
    gw_stream *streams = streams_of(h);
    for (uint64_t i = 0; i < n; ++i) pids[i] = streams[i].used ? streams[i].pid : 0;
    unlock_streams(h);
    for (uint64_t i = 0; i < n; ++i) dead[i] = pids[i] != 0 && !process_alive(pids[i]);
    if (lock_streams(h) != 0) return;
    streams = streams_of(h);
    for (uint64_t i = 0; i < n; ++i) {
        if (dead[i] && streams[i].used && streams[i].pid == pids[i]) streams[i].used = 0;
    }
    unlock_streams(h);
}

/* Records that connection slot of this process streams channel. Returns 0 when recorded, -1 when the
   registry is full (after pruning dead processes), the lock timed out, or there is no store. */
int32_t gw_shared_stream_add(int32_t slot, int32_t channel) {
    if (shared_base == NULL) return -1;
    gw_shared_header *h = shared_base;
    if (lock_streams(h) != 0) return -1;
    if (free_stream(h) < 0) {
        unlock_streams(h);
        prune_dead_streams(h);
        if (lock_streams(h) != 0) return -1;
    }
    int64_t at = free_stream(h);
    if (at < 0) { unlock_streams(h); return -1; }
    gw_stream *streams = streams_of(h);
    streams[at].pid = (int32_t)getpid();
    streams[at].slot = slot;
    streams[at].channel = channel;
    streams[at].used = 1;
    unlock_streams(h);
    return 0;
}

/* Forgets the stream of connection slot in this process. A timed-out wait leaves the entry in place; it stays
   counted until this process exits (the timeout is in the stats). */
void gw_shared_stream_remove(int32_t slot) {
    if (shared_base == NULL) return;
    gw_shared_header *h = shared_base;
    if (lock_streams(h) != 0) return;
    gw_stream *streams = streams_of(h);
    int32_t pid = (int32_t)getpid();
    for (uint64_t i = 0; i < h->stream_count; ++i) {
        if (streams[i].used && streams[i].pid == pid && streams[i].slot == slot) {
            streams[i].used = 0;
            break;
        }
    }
    unlock_streams(h);
}

/* Number of live streams on channel in every process that shares the store. -1 when the registry lock timed
   out. The liveness checks run with the lock released. */
int64_t gw_shared_stream_count(int32_t channel) {
    if (shared_base == NULL) return 0;
    gw_shared_header *h = shared_base;
    if (lock_streams(h) != 0) return -1;
    gw_stream *streams = streams_of(h);
    int32_t pids[GW_SHARED_STREAMS];
    uint64_t n = h->stream_count;
    for (uint64_t i = 0; i < n; ++i) {
        pids[i] = streams[i].used && streams[i].channel == channel ? streams[i].pid : 0;
    }
    unlock_streams(h);
    int64_t count = 0;
    for (uint64_t i = 0; i < n; ++i) {
        if (pids[i] != 0 && process_alive(pids[i])) count += 1;
    }
    return count;
}

/* ---- Stats ----------------------------------------------------------------------------------- */

/* Store counters for web::shared_stats. capacity, stripes, timeouts and recoveries are read without a lock.
   entries counts the live entries, taking each stripe lock in turn, and ring_lost is the ring's lost count.
   Either is -1 when its lock could not be had in time. All are 0 when the store is off. */
void gw_shared_stats(int64_t *entries, int64_t *capacity, int64_t *stripes, int64_t *timeouts,
                     int64_t *recoveries, int64_t *ring_lost) {
    *entries = 0;
    *capacity = 0;
    *stripes = 0;
    *timeouts = 0;
    *recoveries = 0;
    *ring_lost = 0;
    if (shared_base == NULL) return;
    gw_shared_header *h = shared_base;
    *capacity = (int64_t)h->slot_count;
    *stripes = (int64_t)h->stripe_count;
    *timeouts = __atomic_load_n(&h->timeouts, __ATOMIC_RELAXED);
    *recoveries = __atomic_load_n(&h->recovered, __ATOMIC_RELAXED);
    int64_t now = monotonic_ms();
    int64_t live = 0;
    for (uint64_t s = 0; s < h->stripe_count; ++s) {
        if (timed_lock(h, &h->stripes[s].lock, (int64_t)s) != 0) { live = -1; break; }
        const gw_slot *table = table_of(h);
        for (uint64_t i = h->stripes[s].first; i < h->stripes[s].first + h->stripes[s].count; ++i) {
            if (table[i].state == GW_SLOT_USED && !slot_expired(&table[i], now)) live += 1;
        }
        unlock_stripe(h, s);
    }
    *entries = live;
    if (lock_ring(h) == 0) {
        *ring_lost = h->lost;
        unlock_ring(h);
    } else {
        *ring_lost = -1;
    }
}
