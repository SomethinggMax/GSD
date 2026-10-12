package bench;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.time.Duration;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Local server for benchmark C. Per connection: read (token, delayNs), wait delayNs, send token back,
 * then wait until the client closes. The client closes first with RST, so neither side keeps TIME_WAIT
 * sockets. One virtual thread per connection keeps the server identical for every construct under test.
 *
 * Usage: java -Xmx256m -cp build bench.EchoServer [port] [backlog]
 * The listen backlog is capped by net.core.somaxconn; set that to >= 16384 (scripts/setup-once.sh),
 * otherwise 10,000 simultaneous connects (virtual threads, C = 10000) can overflow the queue and SYNs get retried after 1 s.
 */
public final class EchoServer {
    static final AtomicLong served = new AtomicLong();
    static final AtomicLong failed = new AtomicLong();

    public static void main(String[] a) throws Exception {
        int port = a.length > 0 ? Integer.parseInt(a[0]) : 7777;
        int backlog = a.length > 1 ? Integer.parseInt(a[1]) : 16384;
        try (ServerSocket ss = new ServerSocket()) {
            ss.setReuseAddress(true);
            ss.bind(new InetSocketAddress(InetAddress.getLoopbackAddress(), port), backlog);
            System.out.println("READY echo server on 127.0.0.1:" + port + " backlog " + backlog);
            System.out.flush();
            Thread stats = new Thread(() -> {
                while (true) {
                    try {
                        Thread.sleep(600_000);
                    } catch (InterruptedException e) {
                        return;
                    }
                    System.out.println(java.time.Instant.now() + " served=" + served.get() + " failed=" + failed.get());
                    System.out.flush();
                }
            });
            stats.setDaemon(true);
            stats.start();
            while (true) {
                Socket s = ss.accept();
                Thread.ofVirtual().start(() -> handle(s));
            }
        }
    }

    static void handle(Socket s) {
        try (s) {
            s.setTcpNoDelay(true);
            InputStream raw = s.getInputStream();
            DataInputStream in = new DataInputStream(new BufferedInputStream(raw, 16));
            long token = in.readLong();
            long delayNs = in.readLong();
            if (delayNs > 0) Thread.sleep(Duration.ofNanos(delayNs));
            DataOutputStream out = new DataOutputStream(s.getOutputStream());
            out.writeLong(token);
            out.flush();
            served.incrementAndGet();
            try {
                raw.read(); // returns -1 / throws "Connection reset" once the client has closed
            } catch (IOException ignored) {
                // expected: client closes with RST
            }
        } catch (Exception e) {
            if (failed.getAndIncrement() < 5) System.err.println("connection failed: " + e);
        }
    }

    private EchoServer() {
    }
}
