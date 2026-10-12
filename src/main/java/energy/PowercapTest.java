package energy;

/** Sanity check: measure package + DRAM energy while idle and while busy. */
public class PowercapTest {
    public static void main(String[] args) throws Exception {
        RaplMeter pkg = new RaplMeter("intel-rapl:0");
        RaplMeter dram = new RaplMeter("intel-rapl:0:2");

        measure("idle 1s", pkg, dram, () -> {
            try {
                Thread.sleep(1000);
            } catch (InterruptedException e) {
                throw new RuntimeException(e);
            }
        });

        measure("busy 1s (all cores)", pkg, dram, () -> {
            long end = System.nanoTime() + 1_000_000_000L;
            java.util.stream.IntStream.range(0, Runtime.getRuntime().availableProcessors())
                    .parallel()
                    .forEach(i -> {
                        double x = 0;
                        while (System.nanoTime() < end) x += Math.sqrt(x + i);
                    });
        });
    }

    private static void measure(String label, RaplMeter pkg, RaplMeter dram, Runnable work) throws Exception {
        long p0 = pkg.read(), d0 = dram.read(), t0 = System.nanoTime();
        work.run();
        long p1 = pkg.read(), d1 = dram.read(), t1 = System.nanoTime();

        double secs = (t1 - t0) / 1e9;
        double pj = pkg.joulesBetween(p0, p1), dj = dram.joulesBetween(d0, d1);
        System.out.printf("%-22s time=%.3fs  %s=%.2fJ (%.1fW)  %s=%.2fJ (%.1fW)%n",
                label, secs, pkg.name(), pj, pj / secs, dram.name(), dj, dj / secs);
    }
}
