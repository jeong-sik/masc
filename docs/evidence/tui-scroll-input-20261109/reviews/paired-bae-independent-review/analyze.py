#!/usr/bin/env python3
"""Read the fixed 50-run cohort; write derived review artifacts only."""
import datetime
import hashlib
import json
import pathlib
import statistics

OUT = pathlib.Path(__file__).resolve().parent
INPUT = OUT.parent / "paired-bae"
CONDITIONS = ["typing", "pageup", "pagedown", "wheelup", "wheeldown"]
LABELS = ["before", "after"]
SHAS = {
    "before": "ebcbe53ff38f8a60ce456bd20d8f05a9542f8deb7fa450400475505078fdb93b",
    "after": "85c7d5bc40b0b99de9bfd9492604f0c3b4176d7cd4f53d85a34d4bd5a1924139",
}
PROBE = "b43594f33f14edbe18d07eb98fac62e8a99c3803f74b0a04fd215ed0e0d30efd"
HISTORY = "b1d4d6fa6c3ffc1a1ee129bd2057d57f0460ee5ccc30b138e2dcaca7b584703b"
TEXT = b"abcdefghijklmnopqrstuvwxyz012345"
FIXTURES = {
    "test_tui_chat_owed_history.py": "1c71418a7fb85c958be82cb4b4a00ff6e374164debe65a1ab33affeeb096c928",
    "test_tui_fusion_recovery.py": "51a3675250ef38dfec902211bd3e4761063375bb16692837e73a1bdde28cf81a",
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stats(values):
    if not values:
        return None
    return {"n": len(values), "min": min(values), "median": statistics.median(values), "max": max(values)}


def gaps(sends):
    return [(b["at"] - a["at"]) * 1000 for a, b in zip(sends, sends[1:])]


rows = []
issues = []
raw_by_key = {}
order = json.loads((INPUT / "order.json").read_text())
order_keys = [(x["pair"], x["label"], x["condition"]) for x in order]
expected = {(i, label, condition) for i in range(5) for label in LABELS for condition in CONDITIONS}
if len(order_keys) != 50 or len(set(order_keys)) != 50 or set(order_keys) != expected:
    issues.append("Order log is not the exact fixed 50-run cohort")
for pair in range(5):
    for condition in CONDITIONS:
        for label in LABELS:
            path = INPUT / f"pair-{pair:02d}-{label}-{condition}" / condition / "result.json"
            if not path.exists():
                issues.append(f"Missing result {pair}/{label}/{condition}")
                continue
            data = json.loads(path.read_text())
            raw_by_key[pair, label, condition] = data
            sends, records = data["sends"], data["records"]
            typed = [x for x in sends if x["name"] == "type"]
            scrolled = [x for x in sends if x["name"] == condition and condition != "typing"]
            positions = [x for x in sends if x["name"] == "position"]
            acked = [r for r in records if r["ack_at"] is not None]
            values = [(r["ack_at"] - r["sent_at"]) * 1000 for r in records[1:] if r["ack_at"] is not None]
            ordered_values = sorted(values)
            recomputed_p95 = ordered_values[int((len(ordered_values)-1)*.95)] if ordered_values else None
            capture_bytes = (path.parent / "capture.ansi").stat().st_size
            row_issues = []
            checks = {
                "binary_hash_stable_and_expected": data["exe_sha256"] == data["exe_sha256_before"] == SHAS[label],
                "probe_hash_expected": data["probe_sha256"] == sha(path.parent / "probe.py") == PROBE,
                "fixture_copies_match_expected_hashes": data["fixture_modules_sha256"] == FIXTURES and all(sha(path.parent / name) == value for name, value in FIXTURES.items()),
                "same_retained_history": data["history_sha256"] == sha(path.parent / "history.json") == HISTORY,
                "same_history_shape": data["messages"] == 800 and data["lines_per_message"] == 8,
                "all_input_bytes_written": all(x["written"] == len(bytes.fromhex(x["bytes"])) for x in sends),
                "exact_typing_bytes_and_count": len(typed) == 32 and b"".join(bytes.fromhex(x["bytes"]) for x in typed) == TEXT,
                "all_expected_prefixes_observed": len(records) == len(acked) == 33 and data["latency"]["n"] == 32 and data["unacknowledged"] == 0,
                "ordered_prefixes_match_sent_text": len(records) == 33 and all(r["prefix"] == records[0]["prefix"] + TEXT[:i].decode() for i, r in enumerate(records)),
                "reported_p95_matches_raw_record_clocks": recomputed_p95 is not None and abs(recomputed_p95-data["latency"]["p95_ms"]) < 1e-8,
                "clock_order": all(r["ack_at"] is not None and r["ack_at"] >= r["sent_at"] for r in records),
                "capture_chunk_lengths_exact": sum(x["bytes"] for x in data["chunks"]) == capture_bytes,
                "condition_positioning": len(positions) == (100 if condition == "pagedown" else 10),
                "observation_complete_echo_off": data["observation"].get("complete") is True and data["observation"].get("echo_off") is True,
                "no_errors_clean_exit": not data["errors"] and data["exit"] == 0,
                "profiling_disabled": data["cpu_includes_sample_process"] is False and data["allocation_sampling_enabled"] is False,
            }
            row_issues += [key for key, ok in checks.items() if not ok]
            issues += [f"{pair}/{label}/{condition}: {key}" for key in row_issues]
            elapsed = (typed[-1]["at"] - typed[0]["at"]) if len(typed) > 1 else None
            row = {
                "pair": pair, "label": label, "condition": condition,
                "input_result": str(path.relative_to(OUT.parent)), "result_sha256": sha(path),
                "binary_sha256": data["exe_sha256"], "probe_sha256": data["probe_sha256"],
                "fixture_modules_sha256": data["fixture_modules_sha256"],
                "history_sha256": data["history_sha256"], "latency": data["latency"],
                "missing": data["unacknowledged"], "errors": data["errors"], "checks": checks,
                "type_gaps_ms": stats(gaps(typed)), "scroll_gaps_ms": stats(gaps(scrolled)),
                "scroll_events": len(scrolled), "typing_span_seconds": elapsed,
                "actual_scroll_hz": ((len(scrolled)-1)/(scrolled[-1]["at"]-scrolled[0]["at"])) if len(scrolled) > 1 else None,
                "child_cpu_lifecycle_seconds": data["child_cpu_user_s"] + data["child_cpu_system_s"],
                "wall_lifecycle_plus_analysis_seconds": data["wall_seconds"],
                "phase_start": data["observation"]["phase_start"], "phase_end": data["observation"]["phase_end"],
                "load_before": data["load_before"], "load_after": data["load_after"],
                "submitted_message_exact": data["observation"].get("submitted_message_exact"),
            }
            rows.append(row)

groups = []
for condition in CONDITIONS:
    pairs = []
    for pair in range(5):
        selected = {r["label"]: r for r in rows if r["pair"] == pair and r["condition"] == condition}
        if set(selected) != set(LABELS):
            continue
        before, after = selected["before"], selected["after"]
        b, a = before["latency"]["p95_ms"], after["latency"]["p95_ms"]
        pairs.append({"pair": pair, "execution_order": [label for p, label, c in order_keys if p == pair and c == condition],
                      "before_p95_ms": b, "after_p95_ms": a, "paired_p95_delta_ms": a-b,
                      "paired_p95_ratio": a/b, "p95_lower_after": a < b,
                      "before_cpu_lifecycle_seconds": before["child_cpu_lifecycle_seconds"],
                      "after_cpu_lifecycle_seconds": after["child_cpu_lifecycle_seconds"],
                      "paired_cpu_ratio": after["child_cpu_lifecycle_seconds"]/before["child_cpu_lifecycle_seconds"],
                      "before_load1": before["load_before"][0], "after_load1": after["load_before"][0],
                      "before_type_gap_median_ms": before["type_gaps_ms"]["median"], "after_type_gap_median_ms": after["type_gaps_ms"]["median"],
                      "before_scroll_hz": before["actual_scroll_hz"], "after_scroll_hz": after["actual_scroll_hz"]})
    groups.append({"condition": condition, "pairs": pairs,
                   "p95_lower_after_pairs": sum(p["p95_lower_after"] for p in pairs),
                   "before_run_p95_median_ms": statistics.median(p["before_p95_ms"] for p in pairs),
                   "after_run_p95_median_ms": statistics.median(p["after_p95_ms"] for p in pairs),
                   "paired_p95_delta_ms": stats([p["paired_p95_delta_ms"] for p in pairs]),
                   "paired_p95_ratio": stats([p["paired_p95_ratio"] for p in pairs]),
                   "paired_cpu_ratio": stats([p["paired_cpu_ratio"] for p in pairs]),
                   "before_max_key_latency_ms": max(r["latency"]["max_ms"] for r in rows if r["condition"] == condition and r["label"] == "before"),
                   "after_max_key_latency_ms": max(r["latency"]["max_ms"] for r in rows if r["condition"] == condition and r["label"] == "after")})

phase_starts = [raw_by_key[key]["observation"]["phase_start"] for key in order_keys]
if any(a >= b for a, b in zip(phase_starts, phase_starts[1:])):
    issues.append("Order log differs from observed monotonic phase-start order")
receipt_path = OUT.parent / "native-bae45a3e" / "receipt.json"
receipt = json.loads(receipt_path.read_text())
if receipt["sha256"] != SHAS["after"]:
    issues.append("Native artifact receipt hash differs from measured after binary")

result = {"reviewed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
          "scope": "Fixed 50-run paired-bae cohort; observational comparison of the two retained native binaries",
          "expected_runs": 50, "observed_runs": len(rows), "issues": issues,
          "expected_binary_sha256": SHAS, "expected_probe_sha256": PROBE, "expected_history_sha256": HISTORY,
          "after_native_receipt": {"file": str(receipt_path.relative_to(OUT.parent)), "sha256": sha(receipt_path),
                                   "source_sha": receipt["source_sha"], "workflow_sha": receipt["workflow_sha"],
                                   "binary_sha256": receipt["sha256"]},
          "order_sha256": sha(INPUT / "order.json"), "groups": groups, "runs": rows,
          "all_25_pairs_cpu_lower_after": all(p["paired_cpu_ratio"] < 1 for g in groups for p in g["pairs"]),
          "all_run_missing_count": sum(r["missing"] for r in rows),
          "actual_type_gap_run_medians_ms": stats([r["type_gaps_ms"]["median"] for r in rows]),
          "actual_type_gap_global_max_ms": max(r["type_gaps_ms"]["max"] for r in rows),
          "actual_scroll_rates_hz": stats([r["actual_scroll_hz"] for r in rows if r["actual_scroll_hz"] is not None]),
          "host_load1_endpoints": stats([v for r in rows for v in (r["load_before"][0], r["load_after"][0])]),
          "verdict": "PageUp latency shows an improvement direction (4/5 pairs); general mixed-scroll typing latency improvement is not established. Child process lifecycle CPU is lower in all 25 pairs.",
          "limitations": ["Independent repeat unit is a run/pair, not each of its 32 serially correlated keys.",
                          "The p95 estimator is the helper's lower empirical quantile at floor((n-1)*0.95); for n=32 it is the third-largest sample.",
                          "Requested input cadence is 50ms typing / 20ms scroll; actual rates are retained separately.",
                          "CPU covers TUI startup, history load, positioning, measured typing and teardown, not only the typing phase.",
                          "Wall time also includes helper shutdown and post-run analysis; do not interpret child_cpu/wall as phase CPU utilization.",
                          "High, changing host load and only five paired runs limit extrapolation and individual-change causal attribution.",
                          "PTY prefix emission is not physical terminal paint or proof of exact submitted/stored draft identity; these performance runs did not enable verify-submit."]}
(OUT / "observations.json").write_text(json.dumps(result, indent=2) + "\n")
lines = ["# Independent review of paired-bae", "", result["verdict"], "",
         f"Read-only analysis at {result['reviewed_at']}; fixed cohort 0..4 x before/after x five conditions. All 50 results are present.",
         "This is a derived review of the retained synthetic PTY captures. It is not a product edit, new TUI execution, CI result, or a claim about the operator's physical screen.", "",
         f"Helper SHA-256: `{PROBE}`. Before binary: `{SHAS['before']}`. After binary: `{SHAS['after']}`.",
         f"800 records x 8 lines, identical history `{HISTORY}`; 32 typed characters per run.", "",
         f"Integrity findings: {len(issues)}. Missing prefixes: {result['all_run_missing_count']}. Every run checks exact typed bytes, 33 ACKs, clean exit, stable binary, frozen helper/fixture copies, and capture chunk byte counts.", "",
         "## Pair-level latency and CPU", "", "Negative latency delta means lower latency after. CPU is the entire child lifecycle.", "",
         "| Condition | Median run p95 before / after (ms) | Pairs lower after | Median paired p95 delta (ms) | Median paired CPU ratio | Worst key before / after (ms) |",
         "| --- | --- | --- | --- | --- | --- |"]
for g in groups:
    lines.append(f"| {g['condition']} | {g['before_run_p95_median_ms']:.2f} / {g['after_run_p95_median_ms']:.2f} | {g['p95_lower_after_pairs']}/5 | {g['paired_p95_delta_ms']['median']:+.2f} | {g['paired_cpu_ratio']['median']:.3f} | {g['before_max_key_latency_ms']:.2f} / {g['after_max_key_latency_ms']:.2f} |")
lines += ["", "PageDown's median run p95 falls when summarized without pair identity, but its median paired delta is positive and only two pairs improve. Typing has the same direction ambiguity. Neither supports a general improvement claim.", "",
          "| Condition | Pair | Order | Before p95 | After p95 | Delta ms | Before / after CPU s | Before / after load1 | Before / after type-gap median ms | Before / after actual scroll Hz |",
          "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
for g in groups:
    for p in g["pairs"]:
        rates = f"{p['before_scroll_hz']:.2f} / {p['after_scroll_hz']:.2f}" if p["before_scroll_hz"] is not None else "none"
        lines.append(f"| {g['condition']} | {p['pair']} | {' -> '.join(p['execution_order'])} | {p['before_p95_ms']:.2f} | {p['after_p95_ms']:.2f} | {p['paired_p95_delta_ms']:+.2f} | {p['before_cpu_lifecycle_seconds']:.3f} / {p['after_cpu_lifecycle_seconds']:.3f} | {p['before_load1']:.1f} / {p['after_load1']:.1f} | {p['before_type_gap_median_ms']:.2f} / {p['after_type_gap_median_ms']:.2f} | {rates} |")
lines += ["", "## Environment, cadence and limits", ""]
lines += [f"- Run median typing gaps: {result['actual_type_gap_run_medians_ms']['min']:.2f}..{result['actual_type_gap_run_medians_ms']['max']:.2f} ms; largest observed gap {result['actual_type_gap_global_max_ms']:.2f} ms.",
          f"- Actual scroll rates: {result['actual_scroll_rates_hz']['min']:.2f}..{result['actual_scroll_rates_hz']['max']:.2f} Hz. 50Hz was requested, not achieved exactly.",
          f"- Host one-minute load endpoints: {result['host_load1_endpoints']['min']:.1f}..{result['host_load1_endpoints']['max']:.1f}. This is load average, not CPU percent."]
lines += ["- " + x for x in result["limitations"]]
lines += ["", "`observations.json` retains every run result digest, hash/denominator checks, gaps, CPU, host-load observations and all 25 paired comparisons. `analyze.py` reproduces these derived files from the fixed original result paths; it does not launch a TUI or write to the input captures."]
(OUT / "README.md").write_text("\n".join(lines) + "\n")
print(json.dumps({"runs": len(rows), "integrity_issues": issues,
                  "groups": [{k: g[k] for k in ("condition", "p95_lower_after_pairs", "paired_p95_delta_ms", "paired_cpu_ratio")} for g in groups],
                  "cadence": result["actual_scroll_rates_hz"], "host_load1": result["host_load1_endpoints"]}, indent=2))
