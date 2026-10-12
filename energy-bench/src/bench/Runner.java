package bench;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ForkJoinPool;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * The four concurrency constructs. Each one runs a batch of n tasks (task indices base .. base+n-1),
 * writes each task's checksum value into out[0..n-1], and returns only when the whole batch is done.
 * The next batch starts only after the previous one has finished (closed batches, as in the report).
 */
abstract class Runner implements AutoCloseable {
    final Work work;
    final AtomicInteger errors = new AtomicInteger();

    Runner(Work work) {
        this.work = work;
    }

    abstract void runBatch(int base, int n, long[] out) throws InterruptedException;

    /** Number of platform worker threads this construct uses (for the CSV). */
    abstract int threads(int c);

    @Override
    public void close() {
    }

    final long safeTask(int taskIndex) {
        try {
            return work.run(taskIndex);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            errors.incrementAndGet();
            return Long.MIN_VALUE;
        } catch (Throwable t) {
            if (errors.getAndIncrement() < 5) {
                System.err.println("task " + taskIndex + " failed: " + t);
            }
            return Long.MIN_VALUE;
        }
    }

    /** Pool size from Goetz et al.: N = Ncpu * (1 + t_block / t_cpu) = Ncpu / (1 - b). */
    static int poolSize(int cores, double b) {
        return (int) Math.round(cores / (1.0 - b));
    }

    static Runner create(String construct, Work work, int cores, double b) {
        int n = poolSize(cores, b);
        switch (construct) {
            case "explicit":
                return new Explicit(work, n);
            case "pool":
                return new OnExecutor(work, Executors.newFixedThreadPool(n), n);
            case "fj":
                // Dedicated pool, parallelism = cores, no ManagedBlocker (typical use, see report 5.3)
                return new OnExecutor(work, new ForkJoinPool(cores), cores);
            case "vt":
                // Carriers = default scheduler parallelism = number of available processors
                return new OnExecutor(work, Executors.newVirtualThreadPerTaskExecutor(), cores);
            default:
                throw new IllegalArgumentException("construct must be explicit, pool, fj or vt");
        }
    }

    /** Explicit multithreading: per batch, start min(C, N) platform threads, split the tasks, join. */
    static final class Explicit extends Runner {
        final int n;

        Explicit(Work work, int n) {
            super(work);
            this.n = n;
        }

        @Override
        int threads(int c) {
            return Math.min(c, n);
        }

        @Override
        void runBatch(int base, int count, long[] out) throws InterruptedException {
            int t = Math.min(count, n);
            Thread[] ts = new Thread[t];
            for (int j = 0; j < t; j++) {
                final int first = j;
                ts[j] = new Thread(() -> {
                    for (int i = first; i < count; i += t) {
                        out[i] = safeTask(base + i);
                    }
                });
                ts[j].start();
            }
            for (Thread th : ts) th.join();
        }
    }

    /** Fixed thread pool, ForkJoinPool and virtual threads: submit every task, wait on a latch. */
    static final class OnExecutor extends Runner {
        final ExecutorService ex;
        final int threads;

        OnExecutor(Work work, ExecutorService ex, int threads) {
            super(work);
            this.ex = ex;
            this.threads = threads;
        }

        @Override
        int threads(int c) {
            return threads;
        }

        @Override
        void runBatch(int base, int count, long[] out) throws InterruptedException {
            CountDownLatch done = new CountDownLatch(count);
            for (int i = 0; i < count; i++) {
                final int idx = i;
                ex.execute(() -> {
                    try {
                        out[idx] = safeTask(base + idx);
                    } finally {
                        done.countDown();
                    }
                });
            }
            done.await();
        }

        @Override
        public void close() {
            ex.shutdown();
            try {
                ex.awaitTermination(1, TimeUnit.MINUTES);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
    }
}
