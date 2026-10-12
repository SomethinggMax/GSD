package bench;

import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;

/**
 * Pilot helpers (P1 and P2 in the test plan).
 *
 *   java -cp build bench.Calib rapl  [--rapl-root /sys/class/powercap]      (needs sudo)
 *   java -cp build bench.Calib k     --benchmark A|B [--target-ns 1000000] [--cores 8]
 *   java -cp build bench.Calib sleep [--tcpu-ns 1000000] [--n 300] [--socket 7777]
 */
public final class Calib {
    static volatile long sink;

    public static void main(String[] argv) throws Exception {
        if (argv.length == 0) {
            System.err.println("usage: Calib rapl|k|sleep [options]");
            System.exit(1);
        }
        Args a = new Args(argv, 1);
        switch (argv[0]) {
            case "rapl":
                rapl(a);
                break;
            case "k":
                k(a);
                break;
            case "sleep":
                sleep(a);
                break;
            default:
                System.err.println("unknown mode " + argv[0]);
                System.exit(1);
        }
    }

    // ------------------------------------------------------------------ P1: RAPL counter checks
    static void rapl(Args a) throws Exception {
        Rapl r = Rapl.open(a.str("rapl-root", "/sys/class/powercap"));
        System.out.println("package domain : " + r.pkgDir + "  max_energy_range_uj = " + r.pkgMax);
        System.out.println("dram domain    : " + r.dramDir + (r.dram == null ? "  (NOT AVAILABLE -> report package only)"
                : "  max_energy_range_uj = " + r.dramMax));

        long end = System.nanoTime() + 2_000_000_000L;
        long last = Rapl.readLong(r.pkg), first = last, lastChange = System.nanoTime(), t0 = lastChange;
        List<Long> gaps = new ArrayList<>();
        long reads = 0;
        while (System.nanoTime() < end) {
            long v = Rapl.readLong(r.pkg);
            reads++;
            if (v != last) {
                long now = System.nanoTime();
                gaps.add(now - lastChange);
                lastChange = now;
                last = v;
            }
        }
        double secs = (System.nanoTime() - t0) / 1e9;
        long[] g = gaps.stream().mapToLong(Long::longValue).toArray();
        Arrays.sort(g);
        System.out.printf(Locale.ROOT, "reads in 2 s   : %d (%.1f us per read)%n", reads, secs * 1e6 / reads);
        if (g.length > 1) {
            System.out.printf(Locale.ROOT, "counter updates: %d, interval median %.0f us, p5 %.0f us, p95 %.0f us%n",
                    g.length, g[g.length / 2] / 1e3, g[g.length / 20] / 1e3, g[g.length * 19 / 20] / 1e3);
        } else {
            System.out.println("counter updates: none seen -> check RAPL");
        }
        double watts = Rapl.delta(first, last, r.pkgMax)[0] / 1e6 / secs;
        System.out.printf(Locale.ROOT, "package power while polling (1 busy core): %.2f W%n", watts);
        System.out.printf(Locale.ROOT, "wrap-around after: %.0f s at 65 W (TDP i7-9700), %.0f s at the power above%n",
                r.pkgMax / 1e6 / 65.0, watts > 0 ? r.pkgMax / 1e6 / watts : Double.NaN);
    }

    // ------------------------------------------------------------------ P2: iteration count for t_cpu
    static void k(Args a) throws Exception {
        char bm = a.req("benchmark").toUpperCase(Locale.ROOT).charAt(0);
        long target = a.l("target-ns", 1_000_000L);
        int cores = a.i("cores", 8);
        int k = a.i("start", bm == 'B' ? 5_500 : 600_000);
        Work probe = new Work(bm, 1, 0, null);

        // Warm up long enough for the JIT and, for B, for G1 to grow the young generation to its steady
        // size: with a short warm-up B calibrates while eden still fits in the cache and runs slower later.
        long warmEnd = System.nanoTime() + a.l("warmup-sec", 8) * 1_000_000_000L;
        while (System.nanoTime() < warmEnd) measure(probe, bm, k, 100);
        for (int round = 1; round <= 15; round++) {
            long[] t = measure(probe, bm, k, 400);
            long med = t[t.length / 2];
            System.out.printf(Locale.ROOT, "round %2d  iters %8d  median %8.1f us%n", round, k, med / 1e3);
            if (Math.abs(med - target) < target * 0.005) break;
            k = (int) Math.max(1, Math.round((double) k * target / med));
        }
        long[] t = measure(probe, bm, k, 1000);
        System.out.printf(Locale.ROOT, "%nsingle thread  iters %d  median %.1f us  p10 %.1f us  p90 %.1f us%n",
                k, t[500] / 1e3, t[100] / 1e3, t[900] / 1e3);

        // Same iteration count with all cores busy: shows whether the frequency differs under full load.
        final int kk = k;
        long[][] per = new long[cores][];
        Thread[] ts = new Thread[cores];
        for (int i = 0; i < cores; i++) {
            final int id = i;
            ts[i] = new Thread(() -> per[id] = measure(probe, bm, kk, 300));
            ts[i].start();
        }
        for (Thread th : ts) th.join();
        long[] all = Arrays.stream(per).flatMapToLong(Arrays::stream).sorted().toArray();
        System.out.printf(Locale.ROOT, "%d threads      iters %d  median %.1f us  p10 %.1f us  p90 %.1f us%n",
                cores, k, all[all.length / 2] / 1e3, all[all.length / 10] / 1e3, all[all.length * 9 / 10] / 1e3);
        // Acceptance: t_cpu must not depend much on how many cores are busy, otherwise b differs per C.
        double slowdown = (double) all[all.length / 2] / t[500] - 1;
        System.out.printf(Locale.ROOT, "%s  %d threads vs 1 thread: %+.1f%% (limit +10%%)%n",
                slowdown <= 0.10 ? "OK  " : "FAIL", cores, 100 * slowdown);
        System.out.println();
        System.out.println("-> put this in config.env:  ITERS_" + (bm == 'B' ? "B" : "A") + "=" + k);
    }

    static long[] measure(Work w, char bm, int k, int n) {
        long[] t = new long[n];
        long s = 0;
        for (int i = 0; i < n; i++) {
            long seed = Work.seedOf(i);
            long t0 = System.nanoTime();
            s += bm == 'B' ? Work.cpuB(seed, k) : Work.cpuA(seed, k);
            t[i] = System.nanoTime() - t0;
        }
        sink += s;
        Arrays.sort(t);
        return t;
    }

    // ------------------------------------------------------------------ P2: blocking-phase accuracy
    static void sleep(Args a) throws Exception {
        long tcpu = a.l("tcpu-ns", 1_000_000L);
        int n = a.i("n", 300);
        int port = a.i("socket", -1);
        double[] bs = {0.25, 0.5, 0.75, 0.95};
        System.out.println("b,target_us,kind,mean_us,median_us,p95_us,b_effective");
        for (double b : bs) {
            long tb = Math.round(tcpu * b / (1.0 - b));
            report(b, tb, tcpu, "sleep-platform", onPlatform(() -> sleeps(tb, n)));
            report(b, tb, tcpu, "sleep-virtual", onVirtual(() -> sleeps(tb, n)));
            if (port > 0) {
                InetSocketAddress addr = new InetSocketAddress(InetAddress.getLoopbackAddress(), port);
                report(b, tb, tcpu, "socket-platform", onPlatform(() -> calls(addr, tb, n)));
                report(b, tb, tcpu, "socket-virtual", onVirtual(() -> calls(addr, tb, n)));
            }
        }
    }

    interface Job {
        long[] run() throws Exception;
    }

    static long[] onPlatform(Job j) throws Exception {
        long[][] r = new long[1][];
        Exception[] e = new Exception[1];
        Thread t = Thread.ofPlatform().start(() -> {
            try {
                r[0] = j.run();
            } catch (Exception ex) {
                e[0] = ex;
            }
        });
        t.join();
        if (e[0] != null) throw e[0];
        return r[0];
    }

    static long[] onVirtual(Job j) throws Exception {
        long[][] r = new long[1][];
        Exception[] e = new Exception[1];
        Thread t = Thread.ofVirtual().start(() -> {
            try {
                r[0] = j.run();
            } catch (Exception ex) {
                e[0] = ex;
            }
        });
        t.join();
        if (e[0] != null) throw e[0];
        return r[0];
    }

    static long[] sleeps(long ns, int n) throws InterruptedException {
        for (int i = 0; i < 20; i++) Thread.sleep(Duration.ofNanos(ns));
        long[] t = new long[n];
        for (int i = 0; i < n; i++) {
            long t0 = System.nanoTime();
            Thread.sleep(Duration.ofNanos(ns));
            t[i] = System.nanoTime() - t0;
        }
        return t;
    }

    static long[] calls(InetSocketAddress addr, long ns, int n) throws Exception {
        for (int i = 0; i < 20; i++) Work.socketCall(addr, i, ns);
        long[] t = new long[n];
        for (int i = 0; i < n; i++) {
            long t0 = System.nanoTime();
            long echo = Work.socketCall(addr, i, ns);
            t[i] = System.nanoTime() - t0;
            if (echo != i) throw new IllegalStateException("echo mismatch");
        }
        return t;
    }

    static void report(double b, long target, long tcpu, String kind, long[] t) {
        long[] s = t.clone();
        Arrays.sort(s);
        double mean = Arrays.stream(s).average().orElse(Double.NaN);
        double med = s[s.length / 2];
        System.out.printf(Locale.ROOT, "%.2f,%.1f,%s,%.1f,%.1f,%.1f,%.3f%n", b, target / 1e3, kind,
                mean / 1e3, med / 1e3, s[s.length * 95 / 100] / 1e3, med / (med + tcpu));
    }

    private Calib() {
    }
}
