package bench;

import java.util.HashMap;
import java.util.Map;

/** Minimal "--key value" / "--flag" parser. */
final class Args {
    private final Map<String, String> m = new HashMap<>();

    Args(String[] a, int from) {
        for (int i = from; i < a.length; i++) {
            if (!a[i].startsWith("--")) throw new IllegalArgumentException("unexpected argument: " + a[i]);
            String k = a[i].substring(2);
            if (i + 1 < a.length && !a[i + 1].startsWith("--")) {
                m.put(k, a[++i]);
            } else {
                m.put(k, "true");
            }
        }
    }

    String str(String k, String def) {
        return m.getOrDefault(k, def);
    }

    String req(String k) {
        String v = m.get(k);
        if (v == null) throw new IllegalArgumentException("missing --" + k);
        return v;
    }

    int i(String k, int def) {
        return m.containsKey(k) ? Integer.parseInt(m.get(k)) : def;
    }

    long l(String k, long def) {
        return m.containsKey(k) ? Long.parseLong(m.get(k)) : def;
    }

    double d(String k, double def) {
        return m.containsKey(k) ? Double.parseDouble(m.get(k)) : def;
    }

    boolean flag(String k) {
        return Boolean.parseBoolean(m.getOrDefault(k, "false"));
    }
}
