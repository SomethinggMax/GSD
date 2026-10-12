package energy;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;

/**
 * Reads a RAPL energy counter via Linux powercap (/sys/class/powercap).
 *
 * <p>The counter wraps to 0 after max_energy_range_uj (~262 kJ, ~46 min at 95 W). For runs of any
 * length, use {@link #start()} / {@link #stop()}: a background thread samples the counter
 * periodically so every wraparound is caught and accumulated.
 */
public class RaplMeter {
    public static final Duration DEFAULT_INTERVAL = Duration.ofSeconds(1);

    private final Path energyFile;
    private final long maxRange;
    private final String name;
    private final Duration interval;

    // Accumulation state, guarded by "this"
    private Thread sampler;
    private long last;
    private long totalUj;
    private long wraps;
    private Exception samplerError;

    /** @param domain e.g. "intel-rapl:0" (package), "intel-rapl:0:0" (core), "intel-rapl:0:2" (dram) */
    public RaplMeter(String domain) throws IOException {
        this(domain, DEFAULT_INTERVAL);
    }

    public RaplMeter(String domain, Duration interval) throws IOException {
        this(Path.of("/sys/class/powercap", domain), interval);
    }

    /** Reads from an arbitrary powercap-style directory (used for testing with a fake counter). */
    RaplMeter(Path dir, Duration interval) throws IOException {
        this.energyFile = dir.resolve("energy_uj");
        this.maxRange = readLong(dir.resolve("max_energy_range_uj"));
        this.name = Files.readString(dir.resolve("name")).trim();
        this.interval = interval;
    }

    public String name() {
        return name;
    }

    /** Current counter value in microjoules. */
    public long read() throws IOException {
        return readLong(energyFile);
    }

    /**
     * Energy in joules between two readings, correcting for at most one wraparound. Only safe when
     * the readings are less than one wrap period apart; use start()/stop() for long runs.
     */
    public double joulesBetween(long before, long after) {
        return deltaUj(before, after, maxRange) / 1_000_000.0;
    }

    /** Starts accumulating energy, sampling the counter every {@code interval}. */
    public synchronized void start() throws IOException {
        if (sampler != null) throw new IllegalStateException("already started");
        last = read();
        totalUj = 0;
        wraps = 0;
        samplerError = null;
        sampler = Thread.ofPlatform().daemon().name("rapl-" + name).start(this::sampleLoop);
    }

    /** Stops accumulating and returns the total energy in joules since {@link #start()}. */
    public double stop() throws IOException {
        Thread t;
        synchronized (this) {
            if (sampler == null) throw new IllegalStateException("not started");
            t = sampler;
            sampler = null;
        }
        t.interrupt();
        try {
            t.join();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        synchronized (this) {
            if (samplerError != null) throw new IOException("RAPL sampler failed; energy total is invalid", samplerError);
            sample(); // final reading
            return totalUj / 1_000_000.0;
        }
    }

    /** Number of counter wraparounds seen during the last start()/stop() run. */
    public synchronized long wraps() {
        return wraps;
    }

    private void sampleLoop() {
        while (!Thread.currentThread().isInterrupted()) {
            try {
                Thread.sleep(interval);
            } catch (InterruptedException e) {
                return;
            }
            synchronized (this) {
                try {
                    sample();
                } catch (Exception e) { // any failure means samples were missed
                    samplerError = e;
                    return;
                }
            }
        }
    }

    // Caller holds the lock.
    private void sample() throws IOException {
        long now = read();
        if (now < last) wraps++;
        totalUj += deltaUj(last, now, maxRange);
        last = now;
    }

    static long deltaUj(long before, long after, long maxRange) {
        return after >= before ? after - before : (maxRange - before) + after;
    }

    private static long readLong(Path p) throws IOException {
        return Long.parseLong(Files.readString(p).trim());
    }
}
