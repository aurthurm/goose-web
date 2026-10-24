#include "../../native/posix/shared.c"
#include <assert.h>
#include <stdio.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* Native checks for the shared store: entries, expiry, counters, a full table, concurrent counters
   across processes, recovery from a worker that dies holding the lock, the SSE ring under wrap and
   lag, and the stream registry. */

#define K(text) bytes_text(text)
#define V(text) bytes_text(text)

static gw_bytes bytes_text(const char *text) {
    gw_bytes b = { (uint8_t *)text, (int64_t)strlen(text) };
    return b;
}

static gw_bytes buffer(uint8_t *data, int64_t len) {
    gw_bytes b = { data, len };
    return b;
}

static void sleep_ms(int ms) {
    struct timespec tick = {0, (long)ms * 1000000L};
    nanosleep(&tick, NULL);
}

static int64_t incr(const char *key, int64_t delta, int64_t ttl_ms, int64_t *value, int64_t *remaining) {
    return gw_shared_incr(K(key), delta, ttl_ms, value, remaining);
}

static void test_disabled_and_sizes(void) {
    assert(gw_shared_open(0) == 0 && gw_shared_enabled() == 0);
    assert(gw_shared_set(K("k"), V("v"), 0) == -1);
    assert(gw_shared_get(K("k"), buffer(NULL, 0)) == -1);
    assert(gw_shared_open(1024) < 0);
    assert(gw_shared_open(GW_SHARED_MAX_BYTES + 1) < 0);
    assert(gw_shared_open(GW_SHARED_MIN_BYTES) == 0 && gw_shared_enabled() == 1);
}

static void test_entries(void) {
    uint8_t out[GW_SHARED_VALUE_BYTES];
    assert(gw_shared_set(K("alpha"), V("one"), 0) == 1);
    assert(gw_shared_get(K("alpha"), buffer(out, sizeof(out))) == 3 && memcmp(out, "one", 3) == 0);
    /* A short buffer gets a truncated copy, and the true length is still reported. */
    assert(gw_shared_get(K("alpha"), buffer(out, 2)) == 3 && memcmp(out, "on", 2) == 0);
    assert(gw_shared_get(K("missing"), buffer(out, sizeof(out))) == -1);
    assert(gw_shared_set(K("alpha"), V("uno!"), 0) == 1);
    assert(gw_shared_get(K("alpha"), buffer(out, sizeof(out))) == 4);
    assert(gw_shared_delete(K("alpha")) == 1 && gw_shared_delete(K("alpha")) == 0);
    assert(gw_shared_get(K("alpha"), buffer(out, sizeof(out))) == -1);
    /* Refused: empty or oversized key, oversized value, ttl beyond the limit. */
    assert(gw_shared_set(K(""), V("v"), 0) == -1);
    char long_key[GW_SHARED_KEY_BYTES + 2];
    memset(long_key, 'k', sizeof(long_key) - 1);
    long_key[sizeof(long_key) - 1] = '\0';
    assert(gw_shared_set(K(long_key), V("v"), 0) == -1);
    uint8_t big[GW_SHARED_VALUE_BYTES + 1];
    memset(big, 'v', sizeof(big));
    assert(gw_shared_set(K("big"), buffer(big, sizeof(big)), 0) == -1);
    assert(gw_shared_set(K("big"), buffer(big, GW_SHARED_VALUE_BYTES), 0) == 1);
    assert(gw_shared_set(K("ttl"), V("v"), GW_SHARED_TTL_MAX_MS + 1) == -1);
    assert(gw_shared_set(K("ttl"), V("v"), -1) == -1);
}

static void test_expiry_and_counters(void) {
    uint8_t out[16];
    assert(gw_shared_set(K("short"), V("x"), 40) == 1);
    assert(gw_shared_get(K("short"), buffer(out, sizeof(out))) == 1);
    sleep_ms(80);
    assert(gw_shared_get(K("short"), buffer(out, sizeof(out))) == -1);

    int64_t value = -1, remaining = -1;
    assert(incr("c", 5, 0, &value, &remaining) == 1 && value == 5 && remaining == 0);
    assert(incr("c", 2, 0, &value, &remaining) == 1 && value == 7);
    /* A window opened with a ttl keeps its expiry on later increments. */
    assert(incr("w", 1, 60000, &value, &remaining) == 1 && value == 1);
    assert(remaining > 0 && remaining <= 60000);
    assert(incr("w", 1, 99999999, &value, &remaining) == 1 && value == 2);
    assert(remaining > 0 && remaining <= 60000);
    /* An expired window restarts from zero. */
    assert(incr("v", 1, 30, &value, &remaining) == 1 && value == 1);
    sleep_ms(60);
    assert(incr("v", 1, 30, &value, &remaining) == 1 && value == 1);
    /* Overflow and a non-counter value are refused. */
    assert(incr("o", INT64_MAX, 0, &value, &remaining) == 1);
    assert(incr("o", 1, 0, &value, &remaining) == -1);
    assert(gw_shared_set(K("text"), V("abc"), 0) == 1);
    assert(incr("text", 1, 0, &value, &remaining) == -1);
}

static void test_full_table(void) {
    char key[32];
    int stored = 0;
    for (int i = 0; i < 100000; ++i) {
        snprintf(key, sizeof(key), "fill-%d", i);
        if (gw_shared_set(K(key), V("payload"), 0) != 1) break;
        stored += 1;
    }
    assert(stored > 0 && stored < 100000);
    assert(gw_shared_set(K("one-more"), V("x"), 0) == 0);
    /* Deleting an entry frees its slot for a new key. */
    snprintf(key, sizeof(key), "fill-%d", 0);
    assert(gw_shared_delete(K(key)) == 1);
    assert(gw_shared_set(K("one-more"), V("x"), 0) == 1);
    /* Expired entries give their slots back without a delete. */
    for (int i = 0; i < stored; ++i) {
        snprintf(key, sizeof(key), "fill-%d", i);
        gw_shared_delete(K(key));
    }
    gw_shared_delete(K("one-more"));
    int shorts = 0;
    for (;;) {
        snprintf(key, sizeof(key), "short-%d", shorts);
        if (gw_shared_set(K(key), V("payload"), 20) != 1) break;
        shorts += 1;
    }
    assert(shorts > 0);
    assert(gw_shared_set(K("late"), V("x"), 0) == 0);
    sleep_ms(40);
    assert(gw_shared_set(K("late"), V("x"), 0) == 1);
    printf("  table holds %d entries of this size\n", stored);
}

/* A worker takes the lock while it is halfway through a write, then dies. The next locker must take over,
   drop the half-written entry and carry on. */
static void test_robust_recovery(void) {
    uint8_t out[16];
    assert(gw_shared_set(K("victim"), V("intact"), 0) == 1);
    uint64_t before = (uint64_t)shared_base->recovered;
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        int64_t now = monotonic_ms(), match, free_slot;
        assert(pthread_mutex_lock(&shared_base->lock) == 0);
        probe(shared_base, (const uint8_t *)"victim", 6, now, &match, &free_slot);
        assert(match >= 0);
        table_of(shared_base)[match].dirty = 1; /* the write has started and never finishes */
        raise(SIGKILL);
        _exit(1);
    }
    int status = 0;
    assert(waitpid(child, &status, 0) == child && WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL);
    assert(gw_shared_get(K("victim"), buffer(out, sizeof(out))) == -1);
    assert(shared_base->recovered == (int64_t)before + 1);
    assert(gw_shared_set(K("after"), V("ok"), 0) == 1);
    printf("  recovered the lock from a dead worker; interrupted entry dropped\n");
}

/* Four processes increment one counter 1000 times each: the total is exact only with a shared lock. */
static void test_cross_process_counter(void) {
    enum { CHILDREN = 4, PER_CHILD = 1000 };
    pid_t children[CHILDREN];
    for (int c = 0; c < CHILDREN; ++c) {
        children[c] = fork();
        assert(children[c] >= 0);
        if (children[c] == 0) {
            int64_t value = 0, remaining = 0;
            for (int i = 0; i < PER_CHILD; ++i) {
                if (incr("total", 1, 0, &value, &remaining) != 1) _exit(1);
            }
            _exit(0);
        }
    }
    for (int c = 0; c < CHILDREN; ++c) {
        int status = 0;
        assert(waitpid(children[c], &status, 0) == children[c] && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    }
    int64_t value = 0, remaining = 0;
    assert(incr("total", 0, 0, &value, &remaining) == 1 && value == CHILDREN * PER_CHILD);
    printf("  %d processes x %d increments = %lld\n", CHILDREN, PER_CHILD, (long long)value);
}

static uint8_t ring_payload[GW_SHARED_MIN_BYTES];

static void fill_message(uint8_t *data, int64_t len, int64_t index) {
    for (int64_t k = 0; k < len; ++k) data[k] = (uint8_t)((index * 31 + k) & 255);
    if (len >= 8) memcpy(data, &index, 8);
}

static int check_message(const uint8_t *data, int64_t len, int64_t index) {
    uint8_t expected[GW_SHARED_MIN_BYTES];
    fill_message(expected, len, index);
    return memcmp(expected, data, (size_t)len) == 0;
}

/* A reader that keeps up sees every message in order, across many wraps of the ring. */
static void test_ring_wraps(void) {
    int64_t position = 0, seq = 0;
    gw_shared_ring_head(&position, &seq);
    assert(seq == shared_base->ring_seq && position == (int64_t)shared_base->ring_write);
    int64_t lost_before = gw_shared_lost();
    uint8_t out[GW_SHARED_MIN_BYTES];
    for (int64_t i = 0; i < 2000; ++i) {
        int64_t len = 1 + (i * 7919) % 5000;
        fill_message(ring_payload, len, i);
        assert(gw_shared_ring_push((int32_t)(i % 3), buffer(ring_payload, len)) == i + 1);
        int32_t channel = -1;
        int64_t got = gw_shared_ring_read(&position, &seq, &channel, buffer(out, sizeof(out)));
        assert(got == len && channel == i % 3 && seq == i + 1);
        assert(check_message(out, len, i));
    }
    assert(gw_shared_lost() == lost_before);
    /* Nothing is left: the reader is caught up. A short buffer is refused without consuming. */
    int32_t channel = 0;
    assert(gw_shared_ring_read(&position, &seq, &channel, buffer(out, sizeof(out))) == 0);
    fill_message(ring_payload, 3000, 9999);
    assert(gw_shared_ring_push(4, buffer(ring_payload, 3000)) > 0);
    int64_t saved_position = position, saved_seq = seq;
    assert(gw_shared_ring_read(&position, &seq, &channel, buffer(out, 100)) == -1);
    assert(position == saved_position && seq == saved_seq);
    assert(gw_shared_ring_read(&position, &seq, &channel, buffer(out, sizeof(out))) == 3000 && channel == 4);
    /* A message larger than the ring can never fit. */
    assert(gw_shared_ring_push(0, buffer(ring_payload, GW_SHARED_MIN_BYTES)) == -1);
}

/* A reader that does not read is overwritten: it sees the newest messages in order, and the messages
   it missed are counted as lost. */
static void test_ring_lag(void) {
    int64_t position = 0, seq = 0;
    gw_shared_ring_head(&position, &seq);
    int64_t lost_before = gw_shared_lost();
    const int64_t total = 100;
    const int64_t base = seq;
    for (int64_t i = 0; i < total; ++i) {
        fill_message(ring_payload, 3000, i);
        assert(gw_shared_ring_push(7, buffer(ring_payload, 3000)) == base + i + 1);
    }
    uint8_t out[GW_SHARED_MIN_BYTES];
    int64_t received = 0, last = 0;
    int32_t channel = 0;
    for (;;) {
        int64_t got = gw_shared_ring_read(&position, &seq, &channel, buffer(out, sizeof(out)));
        if (got == 0) break;
        assert(got == 3000 && channel == 7);
        assert(seq > last);
        assert(check_message(out, 3000, seq - base - 1));
        last = seq;
        received += 1;
    }
    assert(last == base + total);
    assert(received < total && received > 0);
    assert(gw_shared_lost() - lost_before == total - received);
    printf("  lagging reader kept %lld of %lld messages, %lld counted lost\n",
           (long long)received, (long long)total, (long long)(total - received));
}

static void test_stream_registry(void) {
    assert(gw_shared_stream_add(1, 7) == 0);
    assert(gw_shared_stream_add(2, 7) == 0);
    assert(gw_shared_stream_add(3, 8) == 0);
    assert(gw_shared_stream_count(7) == 2 && gw_shared_stream_count(8) == 1 && gw_shared_stream_count(9) == 0);
    gw_shared_stream_remove(1);
    assert(gw_shared_stream_count(7) == 1);
    /* A process that exits without removing its stream stops counting once it is gone. */
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        _exit(gw_shared_stream_add(9, 7) == 0 ? 0 : 1);
    }
    int status = 0;
    assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    assert(gw_shared_stream_count(7) == 1);
    /* The registry is bounded: when it is full, a stream is refused until one is removed. */
    int added = 0;
    while (gw_shared_stream_add(100 + added, 50) == 0) added += 1;
    assert(added > 0 && added <= GW_SHARED_STREAMS);
    assert(gw_shared_stream_add(0, 50) == -1);
    gw_shared_stream_remove(100);
    assert(gw_shared_stream_add(0, 50) == 0);
    printf("  stream registry holds %d streams\n", GW_SHARED_STREAMS);
}

int main(void) {
    test_disabled_and_sizes();
    test_entries();
    test_expiry_and_counters();
    test_full_table();
    test_robust_recovery();
    test_cross_process_counter();
    test_ring_wraps();
    test_ring_lag();
    test_stream_registry();
    assert(gw_shared_open(0) == 0);
    puts("Shared store tests passed: entries, expiry, counters, full table, cross-process counter, "
         "lock recovery, ring wraps and lag, stream registry");
    return 0;
}
