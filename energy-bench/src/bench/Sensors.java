package bench;

import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

/** Side information that is read outside the measured window: CPU package temperature and GC counters. */
final class Sensors {
    private static final Path PKG_TEMP = findPackageTemp();

    /** Package temperature in degrees C from the coretemp hwmon driver, or NaN when unavailable. */
    static double packageTempC() {
        if (PKG_TEMP == null) return Double.NaN;
        try {
            return Rapl.readLong(PKG_TEMP) / 1000.0;
        } catch (Exception e) {
            return Double.NaN;
        }
    }

    /** {total collections, total collection time in ms} over all collectors of this JVM. */
    static long[] gc() {
        long count = 0, ms = 0;
        for (GarbageCollectorMXBean b : ManagementFactory.getGarbageCollectorMXBeans()) {
            count += Math.max(0, b.getCollectionCount());
            ms += Math.max(0, b.getCollectionTime());
        }
        return new long[] {count, ms};
    }

    private static Path findPackageTemp() {
        try (DirectoryStream<Path> ds = Files.newDirectoryStream(Paths.get("/sys/class/hwmon"))) {
            for (Path h : ds) {
                Path name = h.resolve("name");
                if (Files.exists(name) && Rapl.readString(name).equals("coretemp")) {
                    // temp1 is "Package id 0" on Intel desktop CPUs
                    Path t = h.resolve("temp1_input");
                    if (Files.exists(t)) return t;
                }
            }
        } catch (Exception ignored) {
            // no hwmon in containers / VMs
        }
        return null;
    }
}
