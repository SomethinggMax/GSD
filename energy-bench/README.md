# energy-bench

Harness voor de GSD-studie (Liebeton & van Zanten): energie en prestaties van virtual threads,
explicit threads, een fixed thread pool en ForkJoin, gemeten met Intel RAPL via powercap.
Alles draait vanuit de shell: Java zonder build-tool, plus een paar bash-scripts.

```
build.sh                 compileert src/ naar build/ (JDK 21+, op de server JDK 25)
config.env               alle parameters (iteraties, taken, launches, pauze, JVM-flags, seed)
src/bench/Bench.java     één JVM-launch: één configuratie, REPS repetities, één CSV-regel per repetitie
src/bench/Work.java      de taak: CPU-fase (A: rekenlus, B: string bouwen + hashen, C: rekenlus) + blokfase
src/bench/Runner.java    de vier constructs: explicit, pool, fj, vt
src/bench/Rapl.java      RAPL lezen via /sys/class/powercap, inclusief wrap-correctie
src/bench/EchoServer.java  lokale server voor benchmark C (antwoordt na t_block)
src/bench/Calib.java     pilot-hulp: RAPL-check, iteraties kalibreren, sleep/socket-nauwkeurigheid
src/bench/Plan.java      maakt de geshufflede launch-lijst (vaste seed)
scripts/run.sh           draait een launch-lijst; hervat zelf na crash of reboot
scripts/pilot.sh         pilot-stappen p1 t/m p5
scripts/experiment.sh    hoofdexperiment: alles in één keer, of per sessie
scripts/precheck.sh      controle vóór een sessie (--fix zet turbo uit, stopt update-timers, ...)
scripts/idle.sh          idle power meten
scripts/status.sh        voortgang bekijken tijdens een run
scripts/estimate.sh      machinetijd voor het hoofdexperiment, uit gemeten looptijden
scripts/setup-once.sh    eenmalige instellingen (geen suspend, sysctl's, JDK vastzetten)
scripts/restore.sh       na afloop: alle systeemwijzigingen terugdraaien (originele waarden staan in /var/lib/energy-bench)
```

## 1. Op de server zetten (eenmalig)

Via Max z'n repo (aanrader, dan staat de versie die je meet in git):

```bash
git clone <repo-url> && cd <repo>/energy-bench
```

Of rechtstreeks van je laptop via Tailscale:

```bash
scp -r energy-bench joost@rapl-server-joost:~/
```

Dan op de server:

```bash
cd ~/energy-bench
sudo apt install -y openjdk-25-jdk-headless     # als die er nog niet op staat
chmod +x build.sh scripts/*.sh
./build.sh
sudo ./scripts/setup-once.sh
sudo ./scripts/precheck.sh --fix
```

`precheck.sh` moet eindigen met `0 FAIL`. WARN-regels lees je even door; ze komen ook in de log van elke run.

## 2. Pilot

Lange stappen start je losgekoppeld van je SSH-sessie, zodat een weggevallen verbinding de run niet stopt:

```bash
sudo systemd-run --unit=pilot-p3 --working-directory="$PWD" ./scripts/pilot.sh p3
journalctl -fu pilot-p3                 # meekijken (Ctrl-C stopt alleen het meekijken)
./scripts/status.sh results/pilot/p3    # korte stand van zaken
```

| Stap | Commando | Duur | Daarna |
| --- | --- | --- | --- |
| P1 instrument | `sudo ./scripts/pilot.sh p1` | ~10 min | Kijk in `results/pilot/p1/rapl.txt`: heet het DRAM-domein `dram`, loopt de teller op, hoe vaak wordt hij bijgewerkt, wanneer wrapt hij? |
| P2 kalibratie | `sudo ./scripts/pilot.sh p2` | ~10 min | Zet `ITERS_A` en `ITERS_B` in `config.env` en haal het woord `PLACEHOLDER` weg. Kijk in `blocking.csv` naar `b_effective` per construct. |
| P3 smoke test | `sudo ./scripts/pilot.sh p3` | ~2 u | `results/pilot/p3/estimate.txt`: machinetijd per keuze, runs < 2 s, checksum-fouten. `failures.csv` moet leeg zijn. |
| P4 variantie | `sudo ./scripts/pilot.sh p4` | ~8–10 u | `results/pilot/p4/results.csv`: warm-up-curve (energie/tijd per `rep`), CV tussen launches, temperatuur per repetitie. |
| P5 JFR | `sudo ./scripts/pilot.sh p5` | ~15 min | `.jfr`-bestanden plus tellingen van pinning, park en GC-events; looptijd met en zonder JFR in `results.csv`. |

Commit `config.env` na P2 en na het beslismoment, zodat de gebruikte waarden in git staan.

## 3. Hoofdexperiment

Twee manieren, met dezelfde configuraties en dezelfde seed:

```bash
# alles in één geshufflede lijst  -> results/main-all
sudo systemd-run --unit=exp --working-directory="$PWD" ./scripts/experiment.sh all

# of per sessie: sessie k = launch k van elke configuratie  -> results/main-s01 ... main-s10
sudo systemd-run --unit=exp-s1 --working-directory="$PWD" ./scripts/experiment.sh session 1
```

Parameters overschrijven zonder `config.env` aan te passen (bijvoorbeeld na het beslismoment):

```bash
sudo systemd-run --unit=exp --working-directory="$PWD" \
  --setenv=LAUNCHES=7 --setenv=WARMUP=5 --setenv=AXES_ONLY=B,C ./scripts/experiment.sh all
```

`AXES_ONLY=B,C` draait B en C alleen op C = 100 (alle b, RQ2) en b = 0 (alle C, RQ3); A blijft het volledige grid draaien.

**Gestopt?** (crash, stroom, reboot) Voer hetzelfde commando opnieuw uit. Launches in `done.txt` worden overgeslagen;
de rijen van een half afgemaakte launch gaan naar `aborted_rows.csv` en die launch draait opnieuw.
Is `config.env` intussen veranderd, dan weigert het script te hervatten (anders meet je half met andere instellingen).
Na een reboot staat turbo weer aan: `sudo ./scripts/precheck.sh --fix` eerst.

**Tijdens een run** niets zwaars op de server doen, ook niet `htop` laten openstaan. `status.sh` en `tail` zijn prima.

## 4. Output

Per run-map (`results/...`):

| Bestand | Inhoud |
| --- | --- |
| `results.csv` | één regel per repetitie (ook warm-up, met `is_warmup=1`) |
| `launches.csv` | per launch: exit code, starttijd, wandkloktijd |
| `failures.csv` | launches met checksum-fout (rc 3), time-out (rc 124/137) of crash |
| `idle.csv` | idle power: begin, elke 6 uur tijdens lange runs, einde |
| `precheck_*.txt`, `machine_state_*.txt` | machinestaat bij start en einde |
| `plan.tsv`, `config.env`, `settings.log` | precies wat er gedraaid is, in welke volgorde, met welke instellingen |

Kolommen van `results.csv`:

`timestamp, session, launch_id, launch_no, benchmark, construct, b, C, threads, tasks, iters, tcpu_ns, tblock_ns, rep, is_warmup,
pkg_uj, dram_uj, time_ns, pkg_wrapped, dram_wrapped, checksum_ok, task_errors, gc_count, gc_ms, pkg_temp_c, rapl_pkg, rapl_dram, java_version`

- `pkg_uj`/`dram_uj`: energie van de gemeten run in microjoule (`-1` als er geen DRAM-domein is).
- `time_ns`: wandkloktijd van de gemeten run (`System.nanoTime`).
- `threads`: platform-workers: N voor pool, min(C, N) voor explicit, 8 voor fj, 8 carriers voor vt.
- `gc_count`, `gc_ms`, `pkg_temp_c`: gelezen buiten het meetvenster, voor uitleg achteraf.

De harness middelt niets: één waarde per launch (gemiddelde van de bewaarde repetities) maak je in de analyse.

## 5. Keuzes in de code die in het report horen

- **Meetvenster:** RAPL lezen → `nanoTime` → alle batches → `nanoTime` → RAPL lezen. JVM-start, executor aanmaken, checksum vooraf berekenen en CSV schrijven vallen erbuiten.
- **Zelfde werk:** taak *i* gebruikt seed *i* mod 64. De verwachte checksum van een run wordt vóór de metingen berekend; elke repetitie wordt daartegen gecontroleerd (`checksum_ok`).
- **Batches:** een batch van C taken moet helemaal klaar zijn voor de volgende begint. Pool, fj en vt krijgen elke taak via `execute()` en wachten op een `CountDownLatch`; explicit start per batch min(C, N) threads die de taken om-en-om verdelen, en joint ze.
- **Executors** worden één keer per launch gemaakt, vóór de warm-up, en hergebruikt over de repetities.
- **ForkJoin:** eigen `ForkJoinPool(8)`, taken via `execute()`, geen `ManagedBlocker`.
- **Benchmark C:** per taak een nieuwe TCP-verbinding met 127.0.0.1. De client sluit met een RST (`SO_LINGER 0`), zodat 200.000 verbindingen per launch geen TIME_WAIT-sockets achterlaten. De server gebruikt één virtual thread per verbinding en draait de hele sessie mee (ook tijdens idle-metingen), dus zijn energie zit in alle metingen.
- **b = 0:** de blokfase wordt overgeslagen (ook in C).
- **Effectieve b:** `Thread.sleep` slaapt altijd iets langer dan gevraagd, en niet per se even lang op een virtual thread als op een platform thread. In een testomgeving sliep een virtual thread bij 0,333 ms ruim 0,1 ms langer dan een platform thread. P2 meet dit op de server. Valt het verschil groot uit, rapporteer dan per construct de effectieve b.
- **Benchmark B:** elke string wordt 4× met FNV-1a gehasht in plaats van één `String.hashCode()`. Met één hash alloceerde B ~2,4 GB/s per core en werd de CPU-fase op 8 threads 2,3× trager dan op 1 thread (contentie in cache/geheugen, geen GC-pauzes); nu ~360 MB/s per core en ~10% verschil. `Calib k` meldt FAIL als 8 threads meer dan 10% trager zijn dan 1.
- **Pool-grootte:** N = round(8 / (1 − b)) = 8, 11, 16, 32, 160.

## AI-gebruik

Deze harness is geschreven met hulp van Claude (Anthropic). De opdracht staat AI toe voor scripts die het
experiment automatiseren, mits het in de bijlage staat: tool, doel, omvang en welke bestanden.
