package bench;

import java.io.PrintWriter;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Random;
import java.util.Set;

/**
 * Generates the launch list (one line per JVM launch) as TSV, shuffled with a fixed seed.
 *
 *   --mode all          every configuration x every launch number, one shuffled list
 *   --mode session --session k
 *                       only launch number k of every configuration, shuffled with seed + k
 *
 * Grid options (defaults = the full design from the report):
 *   --benchmarks A,B,C  --constructs explicit,pool,fj,vt
 *   --blocking 0,0.25,0.5,0.75,0.95  --concurrency 10,100,1000,10000
 *   --workloads 0:100,0.95:100       explicit list of b:C pairs instead of the grid
 *   --axes-only B,C                  for these benchmarks keep only C = --axes-c (default 100) or b = --axes-b (default 0)
 *   --launches 10 --reps 10 --warmup 7 --seed 20261008 --out plan.tsv
 */
public final class Plan {
    public static void main(String[] argv) throws Exception {
        Args a = new Args(argv, 0);
        String mode = a.str("mode", "all");
        int launches = a.i("launches", 10);
        int session = a.i("session", 0);
        long seed = a.l("seed", 20261008L);
        int reps = a.i("reps", 10);
        int warmup = a.i("warmup", 7);
        List<String> benchmarks = list(a.str("benchmarks", "A,B,C"));
        List<String> constructs = list(a.str("constructs", "explicit,pool,fj,vt"));
        Set<String> axesOnly = new HashSet<>(list(a.str("axes-only", "")));
        double axesB = a.d("axes-b", 0.0);
        int axesC = a.i("axes-c", 100);

        List<double[]> workloads = new ArrayList<>();
        if (a.str("workloads", null) != null) {
            for (String w : list(a.str("workloads", ""))) {
                String[] p = w.split(":");
                workloads.add(new double[] {Double.parseDouble(p[0]), Double.parseDouble(p[1])});
            }
        } else {
            for (String b : list(a.str("blocking", "0,0.25,0.5,0.75,0.95"))) {
                for (String c : list(a.str("concurrency", "10,100,1000,10000"))) {
                    workloads.add(new double[] {Double.parseDouble(b), Double.parseDouble(c)});
                }
            }
        }
        if (warmup >= reps) throw new IllegalArgumentException("--warmup must be smaller than --reps");

        List<Integer> launchNos = new ArrayList<>();
        long shuffleSeed = seed;
        if (mode.equals("all")) {
            for (int l = 1; l <= launches; l++) launchNos.add(l);
        } else if (mode.equals("session")) {
            if (session < 1 || session > launches) throw new IllegalArgumentException("--session must be 1.." + launches);
            launchNos.add(session);
            shuffleSeed = seed + session;
        } else {
            throw new IllegalArgumentException("--mode must be all or session");
        }

        List<String> lines = new ArrayList<>();
        for (int l : launchNos) {
            for (String bm : benchmarks) {
                for (String cons : constructs) {
                    for (double[] w : workloads) {
                        double b = w[0];
                        int c = (int) w[1];
                        if (axesOnly.contains(bm) && !(c == axesC || b == axesB)) continue;
                        String bs = String.format(Locale.ROOT, "%.2f", b);
                        String id = String.format(Locale.ROOT, "%s-%s-b%s-C%d-L%02d", bm, cons, bs, c, l);
                        lines.add(String.join("\t", id, Integer.toString(l), bm, cons, bs,
                                Integer.toString(c), Integer.toString(reps), Integer.toString(warmup)));
                    }
                }
            }
        }
        Collections.shuffle(lines, new Random(shuffleSeed));

        String out = a.str("out", "plan.tsv");
        try (PrintWriter pw = new PrintWriter(Files.newBufferedWriter(Paths.get(out)))) {
            pw.println("launch_id\tlaunch_no\tbenchmark\tconstruct\tb\tC\treps\twarmup");
            for (String s : lines) pw.println(s);
        }
        System.out.println("wrote " + lines.size() + " launches to " + out + " (mode " + mode
                + (mode.equals("session") ? " " + session : "") + ", shuffle seed " + shuffleSeed + ")");
    }

    static List<String> list(String s) {
        if (s == null || s.isBlank()) return new ArrayList<>();
        return new ArrayList<>(Arrays.asList(s.trim().split("\\s*,\\s*")));
    }

    private Plan() {
    }
}
