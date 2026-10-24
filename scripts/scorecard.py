"""Turns the raw eval logs into Benchmarks/SCORECARD.md and a row in Benchmarks/history.csv (see accuracy.sh)."""
import csv, datetime, json, os, re, sys

out_dir, version = sys.argv[1], sys.argv[2]
names = {"everyday": "Everyday dictation", "grammar": "Grammar", "translate": "Hindi/Hinglish → English", "multilang": "Other languages", "audio": "Spoken clips"}
rows, failures, latency = [], {}, {}

def text_suite(key):
    log = open(os.path.join(out_dir, f"{key}.txt"), encoding="utf-8").read()
    total = re.search(r"GRAMMAR (\d+)/(\d+)", log)
    tags = re.findall(r"^  ([\w-]+): (\d+)/(\d+)$", log, re.M)
    ms = re.search(r"avg (\d+) ms", log)
    latency[key] = int(ms.group(1)) if ms else None
    fails = re.findall(r"^✗ #\d+ \[([\w-]+)\] (.*)\n    → \[\w+\] (.*)", log, re.M)
    failures[key] = fails
    return (int(total.group(1)), int(total.group(2))) if total else (0, 0), [(t, int(a), int(b)) for t, a, b in tags]

for key in ("everyday", "grammar", "translate", "multilang"):
    (ok, n), tags = text_suite(key)
    rows.append((key, ok, n, tags))

results = json.load(open("Benchmarks/results-freshflo.json")) if os.path.exists("Benchmarks/results-freshflo.json") else []
audio_ok = sum(1 for r in results if r["checksPassed"] == r["checksTotal"])
# Word error rate only where there's one exact expected sentence (translated clips have many right answers).
refs = {c["id"]: c.get("reference", "") for c in json.load(open("Benchmarks/cases.json"))}
scored = [r for r in results if refs.get(r["id"])]
wer = sum(r["wer"] for r in scored) / len(scored) if scored else 0
lat = sorted(r.get("latencyMs") or 0 for r in results)
latency["audio"] = lat[len(lat) // 2] if lat else None
failures["audio"] = [(r["id"], "", r["output"]) for r in results if r["checksPassed"] != r["checksTotal"]]
rows.append(("audio", audio_ok, len(results), []))

passed = sum(r[1] for r in rows)
total = sum(r[2] for r in rows)
overall = 100 * passed / total if total else 0
today = datetime.date.today().isoformat()

md = [f"# Freshflo accuracy · {version} · {today}", "", f"**Overall: {overall:.1f}%** ({passed}/{total} cases)", "",
      "| Suite | Passed | Score | Typical time |", "|---|---|---|---|"]
for key, ok, n, _ in rows:
    t = latency.get(key)
    md.append(f"| {names[key]} | {ok}/{n} | {100 * ok / n if n else 0:.0f}% | {f'{t} ms' if t else '–'} |")
md += ["", f"Spoken clips: mean word error rate {100 * wer:.1f}% (lower is better).", "", "## By category", "",
       "| Suite | Category | Passed |", "|---|---|---|"]
for key, _, _, tags in rows:
    for t, a, b in tags:
        md.append(f"| {names[key]} | {t} | {a}/{b}{' ⚠︎' if a < b else ''} |")
md += ["", "## What failed", ""]
for key, _, _, _ in rows:
    for tag, raw, got in failures.get(key, []):
        md.append(f"- **{names[key]} · {tag}** {raw[:90]}  \n  → {got[:160]}")
if not any(failures.values()):
    md.append("Nothing.")
open("Benchmarks/SCORECARD.md", "w", encoding="utf-8").write("\n".join(md) + "\n")

hist = "Benchmarks/history.csv"
new = not os.path.exists(hist)
with open(hist, "a", newline="") as f:
    w = csv.writer(f)
    if new:
        w.writerow(["date", "version", "overall", "everyday", "grammar", "translate", "multilang", "audio", "audio_wer", "audio_median_ms"])
    pct = {k: f"{100 * ok / n:.1f}" if n else "" for k, ok, n, _ in rows}
    w.writerow([today, version, f"{overall:.1f}", pct["everyday"], pct["grammar"], pct["translate"], pct["multilang"], pct["audio"], f"{100 * wer:.1f}", latency.get("audio") or ""])
print("\n".join(md[:12]))
print("\nSaved Benchmarks/SCORECARD.md and a row in Benchmarks/history.csv")
