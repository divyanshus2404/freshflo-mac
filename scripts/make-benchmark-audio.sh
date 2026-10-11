#!/bin/bash
# Renders each benchmark case's script to Benchmarks/audio/<id>.m4a with a macOS voice.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Benchmarks/audio
python3 -I - <<'PY'
import json, subprocess, os
for case in json.load(open("Benchmarks/cases.json")):
    if "speak" not in case:
        continue
    aiff = f"Benchmarks/audio/{case['id']}.aiff"
    m4a = f"Benchmarks/audio/{case['id']}.m4a"
    if os.path.exists(m4a):
        continue
    subprocess.run(["say", "-v", case.get("voice", "Samantha"), "-o", aiff, case["speak"]], check=True)
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", aiff, m4a], check=True)
    os.remove(aiff)
    print("rendered", m4a)
PY
