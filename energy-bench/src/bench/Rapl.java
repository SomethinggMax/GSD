package bench;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * Reads Intel RAPL energy counters through the Linux powercap interface (/sys/class/powercap).
 * The package domain must be called "package-0"; the DRAM domain is looked up by its name ("dram")
 * among the package's sub-domains, so we never rely on intel-rapl:0:2 being DRAM without checking.
 * energy_uj is root-only on current kernels, so run with sudo (or give read rights on the files).
 */
final class Rapl {
    final boolean enabled;
    final Path pkg;
    final Path dram;          // null when the CPU exposes no DRAM domain
    final long pkgMax;
    final long dramMax;
    final String pkgDir;
    final String dramDir;

    private Rapl(boolean enabled, Path pkg, Path dram, long pkgMax, long dramMax, String pkgDir, String dramDir) {
        this.enabled = enabled;
        this.pkg = pkg;
        this.dram = dram;
        this.pkgMax = pkgMax;
        this.dramMax = dramMax;
        this.pkgDir = pkgDir;
        this.dramDir = dramDir;
    }

    static Rapl disabled() {
        return new Rapl(false, null, null, 0, 0, "-", "-");
    }

    static Rapl open(String root) throws IOException {
        Path base = Paths.get(root, "intel-rapl:0");
        String name = readString(base.resolve("name"));
        if (!name.equals("package-0")) {
            throw new IOException(base + "/name is '" + name + "', expected 'package-0'");
        }
        Path pkgFile = base.resolve("energy_uj");
        long pkgMax = readLong(base.resolve("max_energy_range_uj"));
        readLong(pkgFile); // fail early (e.g. permission denied without sudo)

        Path dramDirPath = null;
        try (DirectoryStream<Path> ds = Files.newDirectoryStream(base, "intel-rapl:0:*")) {
            for (Path p : ds) {
                if (Files.exists(p.resolve("name")) && readString(p.resolve("name")).equals("dram")) {
                    dramDirPath = p;
                    break;
                }
            }
        }
        Path dramFile = null;
        long dramMax = 0;
        if (dramDirPath != null) {
            dramFile = dramDirPath.resolve("energy_uj");
            dramMax = readLong(dramDirPath.resolve("max_energy_range_uj"));
            readLong(dramFile);
        }
        return new Rapl(true, pkgFile, dramFile, pkgMax, dramMax, base.getFileName().toString(),
                dramDirPath == null ? "none" : dramDirPath.getFileName().toString());
    }

    /** Returns {package_uj, dram_uj}; -1 for a domain that is not available. */
    long[] read() throws IOException {
        if (!enabled) return new long[] {-1, -1};
        return new long[] {readLong(pkg), dram == null ? -1 : readLong(dram)};
    }

    /**
     * Energy between two counter readings, corrected for at most one wrap-around.
     * Returns {delta, wrapped(0/1)}; {-1, 0} when the domain is unavailable.
     */
    static long[] delta(long before, long after, long max) {
        if (before < 0 || after < 0) return new long[] {-1, 0};
        if (after >= before) return new long[] {after - before, 0};
        return new long[] {after + max - before, 1};
    }

    static String readString(Path p) throws IOException {
        return new String(Files.readAllBytes(p), StandardCharsets.US_ASCII).trim();
    }

    static long readLong(Path p) throws IOException {
        return Long.parseLong(readString(p));
    }
}
