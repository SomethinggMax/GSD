package bench;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.time.Duration;

/**
 * One task = a CPU phase with a fixed iteration count, followed by a blocking phase.
 *
 * Benchmark A: arithmetic loop (xorshift) + Thread.sleep
 * Benchmark B: build a short string from a few fields and hash it with FNV-1a (allocates -> GC pressure) + Thread.sleep
 * Benchmark C: same arithmetic loop as A + a real TCP call to a local echo server that replies after the delay
 *
 * At b = 0 the blocking phase is skipped (blockNs == 0).
 * Every task returns a checksum value that only depends on its task index, so the sum over a run
 * is known in advance and proves that every construct did exactly the same work.
 */
final class Work {
    /** Number of distinct seeds; task i uses seed (i % SEEDS). Expected checksum is precomputed from these. */
    static final int SEEDS = 64;

    final char benchmark;
    final int iters;
    final long blockNs;
    final InetSocketAddress server;

    Work(char benchmark, int iters, long blockNs, InetSocketAddress server) {
        if ("ABC".indexOf(benchmark) < 0) throw new IllegalArgumentException("benchmark must be A, B or C");
        if (benchmark == 'C' && blockNs > 0 && server == null) throw new IllegalArgumentException("benchmark C needs a server");
        this.benchmark = benchmark;
        this.iters = iters;
        this.blockNs = blockNs;
        this.server = server;
    }

    static long seedOf(int taskIndex) {
        return (taskIndex % SEEDS) * 0x9E3779B97F4A7C15L + 1;
    }

    long cpu(long seed) {
        return benchmark == 'B' ? cpuB(seed, iters) : cpuA(seed, iters);
    }

    /** Serial dependency chain: cannot be vectorised or skipped by the JIT because the result is used. */
    static long cpuA(long seed, int iters) {
        long x = seed;
        for (int i = 0; i < iters; i++) {
            x ^= x << 13;
            x ^= x >>> 7;
            x ^= x << 17;
            x += i;
        }
        return x;
    }

    /** FNV-1a passes over each string in benchmark B. */
    static final int HASH_ROUNDS = 4;

    /**
     * Builds a short request-like string and hashes it. The strings are stored in a small array with a
     * variable index so escape analysis cannot remove the allocations (this benchmark exists to add GC pressure).
     * Each string is hashed HASH_ROUNDS times with FNV-1a so the allocation rate stays moderate (~360 MB/s per
     * core). With a single String.hashCode() it was ~2.4 GB/s per core, and at 8 threads the cores slowed each
     * other down through cache/memory contention: the CPU phase took 2.3x longer than on one thread.
     */
    static long cpuB(long seed, int iters) {
        String[] keep = new String[8];
        StringBuilder sb = new StringBuilder(64);
        long h = seed;
        for (int i = 0; i < iters; i++) {
            sb.setLength(0);
            sb.append("user=").append(seed & 0xFFFF).append(";item=").append(i).append(";qty=").append(i & 15);
            String s = sb.toString();
            keep[i & 7] = s;
            for (int r = 0; r < HASH_ROUNDS; r++) {
                for (int j = 0; j < s.length(); j++) h = (h ^ s.charAt(j)) * 0x100000001B3L;
            }
        }
        for (String s : keep) {
            if (s != null) h += s.length();
        }
        return h;
    }

    /** Runs one complete task (CPU phase, then blocking phase) and returns its checksum value. */
    long run(int taskIndex) throws Exception {
        long seed = seedOf(taskIndex);
        long v = cpu(seed);
        if (blockNs > 0) {
            if (benchmark == 'C') {
                long echo = socketCall(server, seed, blockNs);
                if (echo != seed) throw new IOException("echo mismatch: sent " + seed + " got " + echo);
            } else {
                Thread.sleep(Duration.ofNanos(blockNs));
            }
        }
        return v;
    }

    /**
     * One request: connect, send (token, delay), read the echoed token, close.
     * The client closes with SO_LINGER=0 (RST) so 200k connections per launch leave no TIME_WAIT sockets
     * behind; otherwise the ephemeral port range would run out.
     */
    static long socketCall(InetSocketAddress addr, long token, long delayNs) throws IOException {
        try (Socket s = new Socket()) {
            s.setTcpNoDelay(true);
            s.connect(addr, 10_000);
            s.setSoTimeout(60_000);
            DataOutputStream out = new DataOutputStream(new BufferedOutputStream(s.getOutputStream(), 16));
            out.writeLong(token);
            out.writeLong(delayNs);
            out.flush();
            long echo = new DataInputStream(new BufferedInputStream(s.getInputStream(), 8)).readLong();
            s.setSoLinger(true, 0);
            return echo;
        }
    }
}
