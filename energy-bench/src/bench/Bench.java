package bench;

import java.io.BufferedWriter;
import java.io.PrintWriter;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.util.Locale;

/**
 * One JVM launch = one configuration (benchmark, construct, b, C), run `reps` times.
 * The first `warmup` repetitions are marked as warm-up; all repetitions are written to the CSV
 * (one line each), so the warm-up curve can be inspected in the pilot.
 *
 * Energy and time are read directly around the measured run only:
 *   RAPL read -> nanoTime -> [all batches] -> nanoTime -> RAPL read
 * JVM start-up, executor creation, checksum precomputation and CSV writing are outside that window.
 *
 * Example:
 *   sudo java -Xms2g -Xmx2g -XX:+AlwaysPreTouch -cp build bench.Bench \
 *     --benchmark A --construct vt --b 0.5 --C 100 --iters 650000 --out results.csv
 */
public final class Bench {
    static final String HEADER = "timestamp,session,launch_id,launch_no,benchmark,construct,b,C,threads,tasks,iters,"
            + "tcpu_ns,tblock_ns,rep,is_warmup,pkg_uj,dram_uj,time_ns,pkg_wrapped,dram_wrapped,checksum_ok,"
            + "task_errors,gc_count,gc_ms,pkg_temp_c,rapl_pkg,rapl_dram,java_version";

    public static void main(String[] argv) throws Exception {
        Args a = new Args(argv, 0);
        char benchmark = a.req("benchmark").toUpperCase(Locale.ROOT).charAt(0);
        String construct = a.req("construct");
        double b = a.d("b", Double.NaN);
        int c = a.i("C", -1);
        int iters = a.i("iters", -1);
        int tasks = a.i("tasks", 20_000);
        int reps = a.i("reps", 10);
        int warmup = a.i("warmup", 7);
        int cores = a.i("cores", 8);
        long tcpuNs = a.l("tcpu-ns", 1_000_000L);
        int port = a.i("port", 7777);
        String out = a.str("out", "results.csv");
        String session = a.str("session", "-");
        String launchId = a.str("launch-id", "-");
        int launchNo = a.i("launch-no", 0);
        boolean noRapl = a.flag("no-rapl");
        String raplRoot = a.str("rapl-root", "/sys/class/powercap");

        if (!(b >= 0 && b < 1)) throw new IllegalArgumentException("--b must be in [0, 1)");
        if (c < 1) throw new IllegalArgumentException("--C must be >= 1");
        if (iters < 1) throw new IllegalArgumentException("--iters must be >= 1 (calibrated value from pilot P2)");
        if (warmup >= reps) throw new IllegalArgumentException("--warmup must be smaller than --reps");

        long blockNs = Math.round(tcpuNs * b / (1.0 - b));
        InetSocketAddress server = benchmark == 'C'
                ? new InetSocketAddress(InetAddress.getLoopbackAddress(), port) : null;
        Work work = new Work(benchmark, iters, blockNs, server);

        Rapl rapl;
        try {
            rapl = noRapl ? Rapl.disabled() : Rapl.open(raplRoot);
        } catch (java.nio.file.AccessDeniedException e) {
            System.err.println("Cannot read " + e.getFile() + ": run with sudo (energy_uj is root-only).");
            System.exit(2);
            return;
        } catch (java.nio.file.NoSuchFileException e) {
            System.err.println("No RAPL domain at " + e.getFile() + " (wrong --rapl-root, or intel_rapl driver not loaded).");
            System.exit(2);
            return;
        }

        // Expected checksum of one run: sum over all tasks of the value of seed (task % SEEDS).
        long[] perSeed = new long[Work.SEEDS];
        long seedSum = 0;
        for (int s = 0; s < Work.SEEDS; s++) {
            perSeed[s] = work.cpu(Work.seedOf(s));
            seedSum += perSeed[s];
        }
        long expected = (long) (tasks / Work.SEEDS) * seedSum;
        for (int s = 0; s < tasks % Work.SEEDS; s++) expected += perSeed[s];

        Path outPath = Paths.get(out);
        boolean newFile = !Files.exists(outPath) || Files.size(outPath) == 0;
        boolean allOk = true;

        try (Runner runner = Runner.create(construct, work, cores, b);
             PrintWriter csv = new PrintWriter(new BufferedWriter(Files.newBufferedWriter(outPath,
                     StandardCharsets.UTF_8, StandardOpenOption.CREATE, StandardOpenOption.APPEND)))) {
            if (newFile) csv.println(HEADER);
            long[] slots = new long[Math.min(c, tasks)];

            for (int rep = 0; rep < reps; rep++) {
                double temp = Sensors.packageTempC();
                long[] gc0 = Sensors.gc();
                int err0 = runner.errors.get();

                // ---- measured window ----
                long[] e0 = rapl.read();
                long t0 = System.nanoTime();
                long sum = 0;
                for (int base = 0; base < tasks; base += c) {
                    int n = Math.min(c, tasks - base);
                    runner.runBatch(base, n, slots);
                    for (int i = 0; i < n; i++) sum += slots[i];
                }
                long t1 = System.nanoTime();
                long[] e1 = rapl.read();
                // -------------------------

                long[] gc1 = Sensors.gc();
                int taskErrors = runner.errors.get() - err0;
                boolean ok = sum == expected && taskErrors == 0;
                allOk &= ok;
                long[] pkg = Rapl.delta(e0[0], e1[0], rapl.pkgMax);
                long[] dram = Rapl.delta(e0[1], e1[1], rapl.dramMax);

                csv.println(String.join(",",
                        Instant.now().toString(), session, launchId, Integer.toString(launchNo),
                        String.valueOf(benchmark), construct, fmt(b), Integer.toString(c),
                        Integer.toString(runner.threads(c)), Integer.toString(tasks), Integer.toString(iters),
                        Long.toString(tcpuNs), Long.toString(blockNs), Integer.toString(rep),
                        rep < warmup ? "1" : "0",
                        Long.toString(pkg[0]), Long.toString(dram[0]), Long.toString(t1 - t0),
                        Long.toString(pkg[1]), Long.toString(dram[1]), ok ? "1" : "0",
                        Integer.toString(taskErrors), Long.toString(gc1[0] - gc0[0]), Long.toString(gc1[1] - gc0[1]),
                        Double.isNaN(temp) ? "" : String.format(Locale.ROOT, "%.1f", temp),
                        rapl.pkgDir, rapl.dramDir, System.getProperty("java.runtime.version")));
                csv.flush();

                System.out.printf(Locale.ROOT, "%s rep %2d%s  time %8.3f s  pkg %9.3f J  dram %8.3f J  checksum %s%n",
                        launchId, rep, rep < warmup ? " (warm-up)" : "          ", (t1 - t0) / 1e9,
                        pkg[0] / 1e6, dram[0] / 1e6, ok ? "ok" : "WRONG");
            }
        }
        System.exit(allOk ? 0 : 3);
    }

    static String fmt(double b) {
        return String.format(Locale.ROOT, "%.2f", b);
    }

    private Bench() {
    }
}
