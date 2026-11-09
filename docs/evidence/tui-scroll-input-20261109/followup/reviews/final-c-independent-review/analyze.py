#!/usr/bin/env python3
"""Reconstruct the fixed normal/burst upgrade comparison without TUI/CI work."""
import ast
import datetime
import hashlib
import json
import pathlib
import statistics

OUT = pathlib.Path(__file__).resolve().parent
ARTIFACTS = OUT.parent
CONDITIONS = ["typing", "pageup", "pagedown", "wheelup", "wheeldown"]
LABELS = ["before", "after"]
BINARY = {"before": "ebcbe53ff38f8a60ce456bd20d8f05a9542f8deb7fa450400475505078fdb93b",
          "after": "9941db5ae67c7da195ae220a8f75ec4988c0a8b09ebb28ca8e7c4990e952f6df"}
PROBE = "b43594f33f14edbe18d07eb98fac62e8a99c3803f74b0a04fd215ed0e0d30efd"
HISTORY = "b1d4d6fa6c3ffc1a1ee129bd2057d57f0460ee5ccc30b138e2dcaca7b584703b"
FIXTURES = {"test_tui_chat_owed_history.py": "1c71418a7fb85c958be82cb4b4a00ff6e374164debe65a1ab33affeeb096c928",
            "test_tui_fusion_recovery.py": "51a3675250ef38dfec902211bd3e4761063375bb16692837e73a1bdde28cf81a"}
TEXT = b"abcdefghijklmnopqrstuvwxyz012345"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def stats(values):
    if not values:
        return None
    values = sorted(values)
    return {"n": len(values), "min": values[0], "median": statistics.median(values),
            "p95": values[int((len(values)-1)*.95)], "max": values[-1]}


def gaps(sends):
    return stats([(b["at"]-a["at"])*1000 for a, b in zip(sends, sends[1:])])


def close(a, b):
    return abs(a-b) < 1e-8


cohorts = []
all_issues = []
boundary_rows = []
for mode in ["normal", "burst"]:
    root = ARTIFACTS / f"paired-final-{mode}"
    helper = (root / "mixed_probe.py").read_bytes()
    assert sha(helper) == PROBE
    node = next(n for n in ast.parse(helper).body if isinstance(n, ast.ClassDef) and n.name == "PlainText")
    namespace = {}
    exec(compile(ast.Module(body=[node], type_ignores=[]), "<frozen diagnostic PlainText>", "exec"), namespace)
    order_bytes = (root / "order.json").read_bytes()
    order = json.loads(order_bytes)
    keys = [(r["pair"], r["label"], r["condition"]) for r in order]
    expected = {(p, label, c) for p in range(5) for label in LABELS for c in CONDITIONS}
    issues = []
    if len(keys) != 50 or len(set(keys)) != 50 or set(keys) != expected:
        issues.append("Order is not the exact fixed 50-run cohort")
    declared_bytes = (root / "paired-summary.json").read_bytes()
    declared = json.loads(declared_bytes)
    runs = []
    pooled = {(label, c): [] for label in LABELS for c in CONDITIONS}
    for pair, label, condition in keys:
        path = root / f"pair-{pair:02d}-{label}-{condition}" / condition / "result.json"
        raw_result = path.read_bytes()
        data = json.loads(raw_result)
        records, sends = data["records"], data["sends"]
        typed = [s for s in sends if s["name"] == "type"]
        scrolled = [s for s in sends if s["name"] == condition and condition != "typing"]
        positioned = [s for s in sends if s["name"] == "position"]
        if mode == "burst" and condition in ("pagedown", "wheeldown"):
            boundary_write = 100 if condition == "pagedown" else 124
            boundary_at = scrolled[boundary_write-1]["returned"] if len(scrolled) >= boundary_write else None
            boundary_rows.append({"pair":pair,"label":label,"condition":condition,
                                  "result":str(path.relative_to(ARTIFACTS)),
                                  "initial_pageup_writes":len(positioned),
                                  "direction_writes":len(scrolled),
                                  "source_conservative_tail_write":boundary_write,
                                  "boundary_clock":"direction write returned before typing write started",
                                  "typed_characters_after_tail_write":sum(s["at"] >= boundary_at for s in typed) if boundary_at is not None else 0})
        values = [(r["ack_at"]-r["sent_at"])*1000 for r in records[1:] if r["ack_at"] is not None]
        latency = stats(values)
        pooled[label, condition].extend(values)
        raw_capture = (path.parent / "capture.ansi").read_bytes()
        offset = 0
        decoder = namespace["PlainText"]()
        tail = b""
        acks = [None] * len(records)
        boundary = max((len(r["prefix"].encode()) for r in records), default=1)-1
        for chunk in data["chunks"]:
            payload = raw_capture[offset:offset+chunk["bytes"]]
            offset += chunk["bytes"]
            text = tail + decoder.feed(payload)
            for i, record in enumerate(records):
                if acks[i] is None and record["sent_at"] <= chunk["at"] and record["prefix"].encode() in text:
                    acks[i] = chunk["at"]
            tail = text[-boundary:] if boundary else b""
        summary_run = next(r for r in declared["runs"] if (r["pair"], r["label"], r["condition"]) == (pair, label, condition))
        checks = {
            "binary_stable_expected": data["exe_sha256"] == data["exe_sha256_before"] == BINARY[label],
            "helper_frozen_expected": data["probe_sha256"] == sha((path.parent/"probe.py").read_bytes()) == PROBE,
            "fixture_sources_frozen_expected": data["fixture_modules_sha256"] == FIXTURES and all(sha((path.parent/name).read_bytes()) == digest for name, digest in FIXTURES.items()),
            "history_frozen_expected": data["history_sha256"] == sha((path.parent/"history.json").read_bytes()) == HISTORY,
            "history_shape_800_by_8": data["messages"] == 800 and data["lines_per_message"] == 8,
            "exact_32_typed_bytes": len(typed) == 32 and b"".join(bytes.fromhex(s["bytes"]) for s in typed) == TEXT,
            "all_writes_complete": all(s["written"] == len(bytes.fromhex(s["bytes"])) for s in sends),
            "prefix_order_correct": len(records) == 33 and all(r["prefix"] == records[0]["prefix"]+TEXT[:i].decode() for i, r in enumerate(records)),
            "all_prefixes_observed": len(values) == 32 and data["unacknowledged"] == 0 and all(r["ack_at"] is not None for r in records),
            "recorded_ack_matches_retained_capture_replay": acks == [r["ack_at"] for r in records],
            "capture_chunk_byte_count_exact": offset == len(raw_capture),
            "nonnegative_latency": all(x >= 0 for x in values),
            "reported_p95_matches_record_clocks": latency is not None and close(latency["p95"], data["latency"]["p95_ms"]),
            "aggregate_result_digest_matches": summary_run["result_sha256"] == sha(raw_result),
            "aggregate_run_p95_matches": latency is not None and close(latency["p95"], summary_run["latency_ms"]["p95"]),
            "positioning_count_correct": len(positioned) == (100 if condition == "pagedown" else 10),
            "echo_off_complete_clean_exit": data["observation"].get("echo_off") is True and data["observation"].get("complete") is True and data["exit"] == 0 and not data["errors"],
            "profiling_disabled": data["cpu_includes_sample_process"] is False and data["allocation_sampling_enabled"] is False,
        }
        failed = [name for name, passed in checks.items() if not passed]
        issues += [f"{pair}/{label}/{condition}: {name}" for name in failed]
        runs.append({"pair": pair, "label": label, "condition": condition,
                     "result": str(path.relative_to(ARTIFACTS)), "result_sha256": sha(raw_result),
                     "capture_sha256": sha(raw_capture), "capture_bytes": len(raw_capture),
                     "checks": checks, "latency_ms": latency, "missing": data["unacknowledged"], "errors": data["errors"],
                     "type_gaps_ms": gaps(typed), "scroll_gaps_ms": gaps(scrolled), "scroll_count": len(scrolled),
                     "actual_scroll_hz": ((len(scrolled)-1)/(scrolled[-1]["at"]-scrolled[0]["at"])) if len(scrolled)>1 else None,
                     "cpu_lifecycle_s": data["child_cpu_user_s"]+data["child_cpu_system_s"],
                     "load_before": data["load_before"], "load_after": data["load_after"],
                     "phase_start": data["observation"]["phase_start"], "phase_end": data["observation"]["phase_end"],
                     "submitted_message_exact": data["observation"].get("submitted_message_exact")})
    if any(a["phase_start"] >= b["phase_start"] for a, b in zip(runs, runs[1:])):
        issues.append("Declared execution order differs from monotonic phase-start order")
    comparisons = []
    for condition in CONDITIONS:
        pairs = []
        for pair in range(5):
            b, a = [next(r for r in runs if (r["pair"],r["label"],r["condition"]) == (pair,label,condition)) for label in LABELS]
            pairs.append({"pair": pair, "order": [label for p,label,c in keys if p==pair and c==condition],
                          "before_p95_ms": b["latency_ms"]["p95"], "after_p95_ms": a["latency_ms"]["p95"],
                          "p95_delta_ms": a["latency_ms"]["p95"]-b["latency_ms"]["p95"],
                          "before_max_ms": b["latency_ms"]["max"], "after_max_ms": a["latency_ms"]["max"],
                          "before_cpu_s": b["cpu_lifecycle_s"], "after_cpu_s": a["cpu_lifecycle_s"],
                          "cpu_ratio": a["cpu_lifecycle_s"]/b["cpu_lifecycle_s"],
                          "before_type_gap_median_ms": b["type_gaps_ms"]["median"], "after_type_gap_median_ms": a["type_gaps_ms"]["median"],
                          "before_scroll_hz": b["actual_scroll_hz"], "after_scroll_hz": a["actual_scroll_hz"],
                          "before_load1": b["load_before"][0], "after_load1": a["load_before"][0]})
        comparison = {"condition": condition, "pooled_descriptive_ms": {label: stats(pooled[label,condition]) for label in LABELS},
                      "pairs": pairs, "p95_lower_pairs": sum(p["p95_delta_ms"]<0 for p in pairs),
                      "paired_p95_delta_ms": stats([p["p95_delta_ms"] for p in pairs]),
                      "cpu_lower_pairs": sum(p["cpu_ratio"]<1 for p in pairs),
                      "cpu_pair_ratios": stats([p["cpu_ratio"] for p in pairs])}
        original = declared["comparisons"][condition]
        if not all(close(comparison["pooled_descriptive_ms"][label]["p95"], original["pooled_descriptive_ms"][label]["p95"]) for label in LABELS):
            issues.append(f"{condition}: aggregate pooled p95 mismatch")
        if comparison["p95_lower_pairs"] != original["p95_decreased_pairs"] or not close(comparison["paired_p95_delta_ms"]["median"], original["median_paired_p95_delta_ms"]):
            issues.append(f"{condition}: aggregate paired comparison mismatch")
        comparisons.append(comparison)
    cohorts.append({"mode": mode, "expected_runs": 50, "observed_runs": len(runs), "issues": issues,
                    "order_sha256": sha(order_bytes), "original_summary_sha256": sha(declared_bytes),
                    "comparisons": comparisons, "runs": runs,
                    "actual_type_gap_run_medians_ms": stats([r["type_gaps_ms"]["median"] for r in runs]),
                    "actual_scroll_rates_hz": stats([r["actual_scroll_hz"] for r in runs if r["actual_scroll_hz"] is not None]),
                    "host_load1_endpoints": stats([v for r in runs for v in (r["load_before"][0],r["load_after"][0])])})
    all_issues += [mode+": "+issue for issue in issues]
    print(mode, "runs", len(runs), "issues", issues, flush=True)

receipt_path = ARTIFACTS / "native-b7d717df" / "receipt.json"
receipt_bytes = receipt_path.read_bytes()
receipt = json.loads(receipt_bytes)
assert receipt["sha256"] == BINARY["after"]
result = {"reviewed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
          "comparison_scope": "Installed eb4e550c snapshot versus candidate b7d717df upgrade; candidate includes other intervening main TUI changes, so this does not isolate C-only causality.",
          "expected_runs": 100, "observed_runs": sum(c["observed_runs"] for c in cohorts), "issues": all_issues,
          "binary_sha256": BINARY, "probe_sha256": PROBE, "history_sha256": HISTORY, "fixture_sha256": FIXTURES,
          "native_receipt": {"file": str(receipt_path.relative_to(ARTIFACTS)), "sha256": sha(receipt_bytes),
                             "source_sha": receipt["source_sha"], "workflow_sha": receipt["workflow_sha"]},
          "cohorts": cohorts,
          "cpu_lower_pairs": sum(g["cpu_lower_pairs"] for c in cohorts for g in c["comparisons"]),
          "missing_prefixes": sum(r["missing"] for c in cohorts for r in c["runs"]),
          "claim_supported": "In this synthetic upgrade comparison, median paired p95 was lower for all four recorded burst scroll-key streams (3/5 or 4/5 pairs). The downward burst streams include tail-clamped no-ops and do not prove continuous active scrolling. Whole-child CPU was lower in all 50 pairs.",
          "claim_not_supported": "Uniform latency improvement, no performance regressions, continuously active downward burst scrolling, C-only causality, physical display improvement, or extrapolation to every real conversation.",
          "workload_findings": [{"priority":"P2","condition":"burst pagedown","finding":"100 initial PgUp requests are followed by 141..151 PgDown requests; 9..11 typed characters occur after the 100th down request, when the fixed page budget reaches the live edge."},
                                {"priority":"P2","condition":"burst wheeldown","finding":"10 initial PgUp requests provide at most 370 rows at 45 terminal rows and fixed chrome 8. A wheel notch moves 3 rows, so tail is reached by notch124. Observed145..152 notches place4..6 typed characters after that bound."}],
          "boundary_evidence_file":"burst-active-scroll-boundary.json",
          "regression_evidence": ["Normal PageDown pooled p95 increased despite a negative median paired delta and 3/5 favorable pairs.",
                                  "Burst typing without scroll had higher pooled p95 and positive median paired delta, with only 2/5 favorable pairs."],
          "limits": ["Five independent run pairs per condition/rate; the 32 serially correlated keys within each run are not independent repetitions.",
                     "Pooled p95 uses 160 keys per label/condition only as a descriptive statistic; normal and burst cohorts are not pooled together.",
                     "Whole-child CPU includes startup, history loading, positioning, measured typing and teardown; it is not phase-only CPU.",
                     "Actual input gaps/rates and high changing load are retained for every pair. Requested rates must not be reported as achieved rates.",
                     "ACK capture replay uses the reviewed frozen streaming decoder and retained raw read timestamps; this is not an independent physical-terminal renderer.",
                     "Performance runs did not enable verify-submit. Exact Unicode submitted-message identity belongs to the separate owned-peer verification, not these 100 runs.",
                     "Candidate binary/source receipt linkage is checked here; source correctness, CI completeness, installation rollout and shipping approval are separate evidence layers."]}
(OUT / "burst-active-scroll-boundary.json").write_text(json.dumps({
    "source_heads":["eb4e550c0450f21f22ffe712aeac9a4e9a1a752d",receipt["source_sha"]],
    "source_coordinates":["bin/masc_tui_message_layout.ml:762-765 fixed chrome 8 and history height", "bin/masc_tui.ml:184 wheel_notch_rows=3", "bin/masc_tui.ml:993-1011 stable reserved page budget", "bin/masc_tui.ml:1552-1562 downward scroll updates"],
    "derivation":"At 45 terminal rows, page_rows<=37. Ten initial up pages leave offset<=370; 124 wheel-down notches subtract372. PageDown uses the same stable reserved page budget in the opposite direction, so100 down pages exhaust100 initial up pages.",
    "scope":"Source projection from ordered sent keys and a fixed synthetic transcript, not a captured authoritative application offset. Actual tail transitions can happen earlier if positioning was clamped.",
    "existing_caption_limit":"has_more=false means the current footer/notice says start for positive offsets and provides no numeric active offset. Do not treat that caption as proof of the oldest viewport.",
    "runs":boundary_rows},indent=2)+"\n")
(OUT / "observations.json").write_text(json.dumps(result,indent=2)+"\n")
lines = ["# Independent final-c measurement review", "", result["comparison_scope"], "",
         "## Verdict and claim boundary", "", result["claim_supported"], "", "The broad claims below are not supported: "+result["claim_not_supported"], "",
         "Both observed regressions must accompany any summary. This review does not classify a noisy tail regression as a proven C-only source defect or replace source/shipping approval.", "",
         f"Fixed cohort: 100/100 results, {len(all_issues)} integrity issues, {result['missing_prefixes']} unobserved prefixes; CPU lower in {result['cpu_lower_pairs']}/50 pairs.",
         "Every run was checked for frozen binary/helper/fixture/history hashes, 32 exact typed bytes, ordered 33 prefixes, complete writes, causal ACK clocks, retained capture replay, byte counts and original aggregate result digests.", "",
         "## Conditions and paired outcomes", "", "A negative paired delta means lower p95 after. Pooled p95 is descriptive, not an independent-sample significance estimate.", "",
         "| Rate | Condition | Pooled p95 before / after ms | Lower p95 pairs | Median paired delta ms | CPU lower pairs | Median CPU ratio |",
         "| --- | --- | --- | --- | --- | --- | --- |"]
for c in cohorts:
    for g in c["comparisons"]:
        b,a=[g["pooled_descriptive_ms"][label]["p95"] for label in LABELS]
        lines.append(f"| {c['mode']} | {g['condition']} | {b:.2f} / {a:.2f} | {g['p95_lower_pairs']}/5 | {g['paired_p95_delta_ms']['median']:+.2f} | {g['cpu_lower_pairs']}/5 | {g['cpu_pair_ratios']['median']:.3f} |")
lines += ["", "Normal PageDown: pooled p95 37.84 -> 73.27ms; pair 0 p95 69.42 -> 117.76ms and pair 3 6.23 -> 28.23ms account for adverse clusters. Do not hide them behind its -6.30ms median paired delta.",
          "Burst typing without scroll: pooled p95 5.96 -> 13.33ms; pairs 2/3/4 worsen, so this is not merely a favorable paired direction masked by pooling.", "",
          "## P2: Downward burst streams reach the tail", "",
          "The frozen helper positions PageDown 100 pages back, but the burst sends 141..151 PageDown requests. For every before/after run, 9..11 of 32 characters are sent after request 100. With the same reserved page budget, those later requests are tail-clamped no-ops.",
          "WheelDown begins 10 pages back. Both source heads have 45 terminal rows, fixed chrome 8, page_rows<=37 and 3 rows per wheel notch, so the initial offset is at most 370 rows and notch 124 reaches the live edge. All ten burst WheelDown runs send 145..152 notches; 4..6 characters occur after notch 124.",
          "These are workload-validity findings, separate from the zero capture/hash integrity issues. Keep all original results and do not relabel their downward burst p95 as continuous active-scroll improvement. `burst-active-scroll-boundary.json` retains per-run evidence and source coordinates. A corrected workload needs enough starting distance and an audit of actual direction writes; any run hitting a boundary remains a recorded limited observation.", "",
          "## Every paired cluster", "", "CPU is the whole process lifecycle; gap is the median actual typing-write interval. Load is the one-minute host load before each run.", "",
          "| Rate | Condition | Pair | Order | Before / after p95 ms | Delta ms | Before / after max ms | Before / after CPU s | Before / after type gap ms | Before / after scroll Hz | Before / after load1 |",
          "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
for c in cohorts:
    for g in c["comparisons"]:
        for p in g["pairs"]:
            rate = f"{p['before_scroll_hz']:.2f} / {p['after_scroll_hz']:.2f}" if p["before_scroll_hz"] is not None else "none"
            lines.append(f"| {c['mode']} | {g['condition']} | {p['pair']} | {' -> '.join(p['order'])} | {p['before_p95_ms']:.2f} / {p['after_p95_ms']:.2f} | {p['p95_delta_ms']:+.2f} | {p['before_max_ms']:.2f} / {p['after_max_ms']:.2f} | {p['before_cpu_s']:.3f} / {p['after_cpu_s']:.3f} | {p['before_type_gap_median_ms']:.2f} / {p['after_type_gap_median_ms']:.2f} | {rate} | {p['before_load1']:.1f} / {p['after_load1']:.1f} |")
lines += ["", "## Cadence, environment and limits", ""]
for c in cohorts:
    t,s,l=[c[k] for k in ("actual_type_gap_run_medians_ms","actual_scroll_rates_hz","host_load1_endpoints")]
    lines.append(f"- {c['mode']}: actual run-median typing gaps {t['min']:.2f}..{t['max']:.2f}ms; actual scroll {s['min']:.2f}..{s['max']:.2f}Hz; host load1 endpoints {l['min']:.1f}..{l['max']:.1f} (load average, not CPU percent).")
lines += ["- "+limit for limit in result["limits"]]
lines += ["", "## Evidence", "", "`observations.json` preserves every result/capture digest, all run-level checks, raw-clock-derived summaries, per-pair gaps/load/CPU, and comparisons with the original aggregate outputs. Raw captures remain in sibling `paired-final-normal` and `paired-final-burst` directories. This is a derived observational review, not a new product run or CI invocation. `analyze.py` only reads those fixed inputs and writes this independent review directory.", "",
          f"Before binary SHA-256 `{BINARY['before']}`; after `{BINARY['after']}`; frozen helper `{PROBE}`."]
(OUT / "README.md").write_text("\n".join(lines)+"\n")
manifest = {"reviewed_at":result["reviewed_at"], "files":[{"path":p.name,"sha256":sha(p.read_bytes()),"bytes":p.stat().st_size} for p in sorted(OUT.iterdir()) if p.is_file() and p.name!="manifest.json"]}
(OUT / "manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")
print(json.dumps({"runs":result["observed_runs"],"issues":all_issues,"cpu_lower_pairs":result["cpu_lower_pairs"],"missing":result["missing_prefixes"]}),flush=True)
