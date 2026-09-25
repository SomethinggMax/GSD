n this study an analysis will be conducted on virtual threads, in
relation to the three established JVM concurrency constructs: Ex-
plicit Threading, Thread Pooling, and ForkJoin. The purpose is to
evaluate virtual threads and compare them to the three concur-
rency constructs with respect to their energy consumption and
performance. This study will be conducted from the point of view
of an application developer choosing a concurrency construct in
the context of server-side Java systems on a single-node Linux
platform.
Our main research question is: How do the energy consumption
and performance of Virtual Threads compare to the three known
JVM concurrency constructs, and how does this comparison change
across different workload conditions? To answer this, we have the
following sub-research questions: How similar are Virtual Threads
to the already established concurrency constructs in terms of energy
and performance? How do blocking ratio and concurrency level
affect virtual threads’ energy consumption and performance relative
to the already established constructs?
We will be using several metrics to evaluate our experiments.
First of all, to measure energy consumption we will be the RAPL. To
measure performance, we will use execution time as a proxy. Lastly,
we will be reporting the Energy-Delay Product to measure the trade-
off between energy and performance. The independent variables
for this study will be the blocking ratio and the concurrency level.
These variables will be systematically adjusted across a small set
of purpose-built synthetic benchmarks, rather than refactoring
real-world applications into all of our constructs.
We expect that a divergence between energy and performance
rankings will appear under certain blocking-ratio and concurrency
conditions. This would extend the findings of Pinto et al. 2014 [10]
to include virtual threads. This study aims to provide a guideline
for developers and to provide a deeper understanding of virtual
threads in the context of energy consumption and performance.