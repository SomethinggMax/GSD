#!/usr/bin/env bash
# Compiles the harness into ./build. Needs a JDK (javac) 21 or newer.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build
mkdir -p build
javac -encoding UTF-8 -Xlint:all -d build src/bench/*.java
echo "built: $(ls build/bench | wc -l) classes in ./build  ($(javac -version 2>&1 | tail -1))"
