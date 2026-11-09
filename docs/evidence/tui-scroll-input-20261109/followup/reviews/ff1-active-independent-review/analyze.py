#!/usr/bin/env python3
"""Read-only audit of retained latency inputs and offline VT replay."""
import ast
import bisect
import datetime
import hashlib
import importlib.metadata
import json
from pathlib import Path
import re
import statistics
import sys

OUT = Path(__file__).resolve().parent
ART = OUT.parent
ROOT = ART / "paired-ff1-active-burst"
sys.path.insert(0, str(ART / "analysis-deps"))
import pyte

CONDITIONS = ["typing", "pageup", "pagedown", "wheelup", "wheeldown"]
SHAS = {"before":"ebcbe53ff38f8a60ce456bd20d8f05a9542f8deb7fa450400475505078fdb93b",
        "after":"1181f65f190aa4894aa6d1067448159cdd3acd4b06bf6eaf4af1223a078e4bd6"}
PROBE = "6f4332edf51fad53d73ebbcb1908f1bcb07b322a952583b413c2a5749a6b1428"
HISTORY = "b1d4d6fa6c3ffc1a1ee129bd2057d57f0460ee5ccc30b138e2dcaca7b584703b"
FIXTURES = {"test_tui_chat_owed_history.py":"1c71418a7fb85c958be82cb4b4a00ff6e374164debe65a1ab33affeeb096c928",
            "test_tui_fusion_recovery.py":"51a3675250ef38dfec902211bd3e4761063375bb16692837e73a1bdde28cf81a"}
TEXT = b"abcdefghijklmnopqrstuvwxyz012345"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def stats(values):
    if not values:
        return None
    v = sorted(values)
    return {"n":len(v),"min":v[0],"median":statistics.median(v),"p95":v[int((len(v)-1)*.95)],"max":v[-1]}


def interval(sends):
    return stats([(b["at"]-a["at"])*1000 for a,b in zip(sends,sends[1:])])


def close(a,b):
    return abs(a-b)<1e-8


helper = (ROOT / "mixed_probe.py").read_bytes()
assert sha(helper)==PROBE
node = next(n for n in ast.parse(helper).body if isinstance(n,ast.ClassDef) and n.name=="PlainText")
ns = {}
exec(compile(ast.Module(body=[node],type_ignores=[]),"<frozen PlainText>","exec"),ns)
order_bytes = (ROOT/"order.json").read_bytes()
order = json.loads(order_bytes)
keys = [(x["pair"],x["label"],x["condition"]) for x in order]
expected = {(p,l,c) for p in range(5) for l in SHAS for c in CONDITIONS}
assert len(keys)==len(set(keys))==50 and set(keys)==expected
original_summary_bytes = (ROOT/"paired-summary.json").read_bytes()
original_summary = json.loads(original_summary_bytes)
v1_bytes = (ROOT/"viewport-observations.json").read_bytes()
v1 = json.loads(v1_bytes)
v2_path = ROOT/"viewport-observations-v2.json"
v2 = json.loads(v2_path.read_text()) if v2_path.exists() else None
assert v2 is not None, "Final audit requires the separately retained v2 viewport observations"
v1_runs = {(r["pair"],r["label"],r["condition"]):r for r in v1["runs"]}
v2_runs = {(r["pair"],r["label"],r["condition"]):r for r in v2["runs"]} if v2 else {}
issues = []
if len(v1["runs"])!=50 or set(v1_runs)!=expected:
    issues.append("v1 viewport cohort differs from fixed 50-run roster")
if v2 and (len(v2["runs"])!=50 or set(v2_runs)!=expected):
    issues.append("v2 viewport cohort differs from fixed 50-run roster")
runs = []
pooled = {(l,c):[] for l in SHAS for c in CONDITIONS}
for pair,label,condition in keys:
    path = ROOT/f"pair-{pair:02d}-{label}-{condition}"/condition/"result.json"
    result_bytes = path.read_bytes()
    r = json.loads(result_bytes)
    capture = path.with_name("capture.ansi").read_bytes()
    records,sends = r["records"],r["sends"]
    typed = [s for s in sends if s["name"]=="type"]
    scroll = [s for s in sends if s["name"]==condition and condition!="typing"]
    lat = [(x["ack_at"]-x["sent_at"])*1000 for x in records[1:] if x["ack_at"] is not None]
    pooled[label,condition].extend(lat)
    decoder = ns["PlainText"]()
    offset = 0
    tail = b""
    boundary = max(len(x["prefix"].encode()) for x in records)-1
    acks = [None]*len(records)
    ends = []
    for chunk in r["chunks"]:
        payload = capture[offset:offset+chunk["bytes"]]
        offset += chunk["bytes"]
        ends.append(offset)
        text = tail+decoder.feed(payload)
        for i,record in enumerate(records):
            if acks[i] is None and record["sent_at"]<=chunk["at"] and record["prefix"].encode() in text:
                acks[i] = chunk["at"]
        tail = text[-boundary:]
    screen = pyte.Screen(150,45)
    stream = pyte.ByteStream(screen)
    previous = 0
    opened = False
    frames = []
    all_ends = []
    unpaired = 0
    for match in re.finditer(rb"\x1b\[\?7[lh]",capture):
        end = match.end()
        stream.feed(capture[previous:end])
        previous = end
        if match.group().endswith(b"l"):
            opened = True
            continue
        at = r["chunks"][bisect.bisect_left(ends,end)]["at"]
        ids = sorted({int(value) for line in screen.display for value in re.findall(r"\bRecord\s+(\d+)\b",line)})
        frame = {"at":at,"record_ids":ids}
        all_ends.append(frame)
        if not opened:
            unpaired += 1
            continue
        frames.append(frame)
        opened = False
    start,end = r["observation"]["phase_start"],r["observation"]["phase_end"]
    before = [f for f in frames if f["at"]<=start and f["record_ids"]]
    during_all = [f for f in frames if start<=f["at"]<=end]
    during = [f for f in during_all if f["record_ids"]]
    post = [f for f in frames if scroll and f["at"]>=scroll[-1]["returned"]]
    changes = sum(a["record_ids"]!=b["record_ids"] for a,b in zip(during,during[1:]))
    key = pair,label,condition
    old = v1_runs[key]
    new = v2_runs.get(key)
    checks = {
        "frozen_expected_binary":r["exe_sha256"]==r["exe_sha256_before"]==SHAS[label],
        "frozen_expected_helper":r["probe_sha256"]==sha(path.with_name("probe.py").read_bytes())==PROBE,
        "frozen_expected_fixtures":r["fixture_modules_sha256"]==FIXTURES and all(sha(path.with_name(name).read_bytes())==digest for name,digest in FIXTURES.items()),
        "frozen_expected_history":r["history_sha256"]==sha(path.with_name("history.json").read_bytes())==HISTORY,
        "800_by_8_history":r["messages"]==800 and r["lines_per_message"]==8,
        "32_exact_typed_bytes":len(typed)==32 and b"".join(bytes.fromhex(s["bytes"]) for s in typed)==TEXT,
        "33_expected_prefixes":len(records)==33 and all(x["prefix"]==records[0]["prefix"]+TEXT[:i].decode() for i,x in enumerate(records)),
        "all_writes_complete":all(s["written"]==len(bytes.fromhex(s["bytes"])) for s in sends),
        "all_acknowledged_and_causal":len(lat)==32 and min(lat)>=0 and r["unacknowledged"]==0,
        "acks_reproduced_from_capture":acks==[x["ack_at"] for x in records],
        "all_chunk_bytes_retained":offset==len(capture),
        "p95_matches_record_clocks":close(stats(lat)["p95"],r["latency"]["p95_ms"]),
        "clean_complete_echo_off":not r["errors"] and r["exit"]==0 and r["observation"]["complete"] is True and r["observation"]["echo_off"] is True,
        "profiling_off":not r["cpu_includes_sample_process"] and not r["allocation_sampling_enabled"],
        "positioning_count":sum(s["name"]=="position" for s in sends)=={"pagedown":200,"wheeldown":50}.get(condition,10),
        "v1_capture_digest":old["capture_sha256"]==sha(capture),
        "v1_all_marker_frames_reproduced":old["frames"]==all_ends,
    }
    if new:
        checks.update(v2_capture_digest=new["capture_sha256"]==sha(capture),
                      v2_paired_present_frames_reproduced=new["frames"]==frames,
                      v2_unpaired_marker_count=new["excluded_unpaired_wrap_enable_markers"]==unpaired,
                      v2_post_write_observed_count=new["observed_present_ends_after_last_scroll_return"]==len(post),
                      v2_during_change_count=new["during_record_set_changes"]==changes)
    issues += [f"{pair}/{label}/{condition}: {name}" for name,passed in checks.items() if not passed]
    row = {"pair":pair,"label":label,"condition":condition,"result":str(path.relative_to(ART)),
           "result_sha256":sha(result_bytes),"capture_sha256":sha(capture),"checks":checks,
           "latency_ms":stats(lat),"type_gaps_ms":interval(typed),"scroll_gaps_ms":interval(scroll),
           "scroll_writes":len(scroll),"actual_scroll_hz":(len(scroll)-1)/(scroll[-1]["at"]-scroll[0]["at"]) if len(scroll)>1 else None,
           "cpu_lifecycle_s":r["child_cpu_user_s"]+r["child_cpu_system_s"],"load_before":r["load_before"],"load_after":r["load_after"],
           "phase_start":start,"phase_end":end,"prefix_missing":r["unacknowledged"],"errors":r["errors"],
           "viewport":{"prephase_last":before[-1] if before else None,"during_first":during[0] if during else None,"during_last":during[-1] if during else None,
                       "during_present_count":len(during_all),"during_present_without_record_ids":len(during_all)-len(during),
                       "record_set_changes":changes,"record_min":min((i for f in during for i in f["record_ids"]),default=None),
                       "record_max":max((i for f in during for i in f["record_ids"]),default=None),
                       "observed_present_ends_after_last_scroll_return":len(post),"excluded_unpaired_enable_markers":unpaired,
                       "last_real_present_with_records":next((f for f in reversed(frames) if f["record_ids"]),None)}}
    runs.append(row)
    print(f"checked {pair}/{label}/{condition}",flush=True)

if any(a["phase_start"]>=b["phase_start"] for a,b in zip(runs,runs[1:])):
    issues.append("Execution order differs from monotonic phase start order")
comparisons = []
for condition in CONDITIONS:
    pairs = []
    for pair in range(5):
        b,a = [next(r for r in runs if (r["pair"],r["label"],r["condition"])==(pair,label,condition)) for label in SHAS]
        pairs.append({"pair":pair,"order":[l for p,l,c in keys if p==pair and c==condition],"before_p95_ms":b["latency_ms"]["p95"],"after_p95_ms":a["latency_ms"]["p95"],
                      "p95_delta_ms":a["latency_ms"]["p95"]-b["latency_ms"]["p95"],"before_cpu_s":b["cpu_lifecycle_s"],"after_cpu_s":a["cpu_lifecycle_s"],
                      "before_type_gap_ms":b["type_gaps_ms"]["median"],"after_type_gap_ms":a["type_gaps_ms"]["median"],
                      "before_scroll_hz":b["actual_scroll_hz"],"after_scroll_hz":a["actual_scroll_hz"],"before_load1":b["load_before"][0],"after_load1":a["load_before"][0]})
    g = {"condition":condition,"pairs":pairs,"pooled_descriptive_ms":{l:stats(pooled[l,condition]) for l in SHAS},
         "p95_lower_pairs":sum(p["p95_delta_ms"]<0 for p in pairs),"median_paired_p95_delta_ms":statistics.median(p["p95_delta_ms"] for p in pairs),
         "cpu_lower_pairs":sum(p["after_cpu_s"]<p["before_cpu_s"] for p in pairs)}
    declared = original_summary["comparisons"][condition]
    if not all(close(g["pooled_descriptive_ms"][l]["p95"],declared["pooled_descriptive_ms"][l]["p95"]) for l in SHAS) or g["p95_lower_pairs"]!=declared["p95_decreased_pairs"] or not close(g["median_paired_p95_delta_ms"],declared["median_paired_p95_delta_ms"]):
        issues.append(condition+": original aggregate differs from raw-clock reconstruction")
    comparisons.append(g)
scroll_runs = [r for r in runs if r["condition"]!="typing"]
receipt_bytes = (ART/"native-ff1cc770/receipt.json").read_bytes()
receipt = json.loads(receipt_bytes)
assert receipt["sha256"]==SHAS["after"]
result = {"reviewed_at":datetime.datetime.now(datetime.timezone.utc).isoformat(),"expected_runs":50,"observed_runs":len(runs),"issues":issues,
          "binary_sha256":SHAS,"helper_sha256":PROBE,"history_sha256":HISTORY,"order_sha256":sha(order_bytes),
          "native_receipt":{"sha256":sha(receipt_bytes),"source_sha":receipt["source_sha"],"workflow_sha":receipt["workflow_sha"]},
          "viewport_v1_sha256":sha(v1_bytes),"viewport_v2_sha256":sha(v2_path.read_bytes()) if v2 else None,
          "observer_source_sha256":sha((ART/"observe_viewports.py").read_bytes()),
          "pyte_version":importlib.metadata.version("pyte"),"wcwidth_version":importlib.metadata.version("wcwidth"),
          "comparisons":comparisons,"runs":runs,"cpu_lower_pairs":sum(g["cpu_lower_pairs"] for g in comparisons),
          "cpu_total_s":{l:sum(r["cpu_lifecycle_s"] for r in runs if r["label"]==l) for l in SHAS},
          "actual_type_gap_run_medians_ms":stats([r["type_gaps_ms"]["median"] for r in runs]),
          "actual_scroll_hz":stats([r["actual_scroll_hz"] for r in scroll_runs]),
          "host_load1_endpoints":stats([x for r in runs for x in (r["load_before"][0],r["load_after"][0])]),
          "viewport_summary":{"scroll_runs":40,"all_show_prephase_records":all(r["viewport"]["prephase_last"] for r in scroll_runs),
                              "all_show_record_set_changes":all(r["viewport"]["record_set_changes"]>0 for r in scroll_runs),
                              "all_have_observed_present_end_after_last_scroll_return":all(r["viewport"]["observed_present_ends_after_last_scroll_return"]>0 for r in scroll_runs),
                              "total_excluded_unpaired_markers":sum(r["viewport"]["excluded_unpaired_enable_markers"] for r in runs),
                              "during_presents_without_record_ids":sum(r["viewport"]["during_present_without_record_ids"] for r in runs)},
          "source_bound":{"terminal_rows":45,"fixed_chrome_rows":8,"maximum_page_rows":37,"minimum_fixture_content_rows":6400,
                          "maximum_observed_direction_writes":max(r["scroll_writes"] for r in scroll_runs),
                          "max_153_page_down_rows":153*37,"minimum_available_scroll_rows":6400-37,
                          "page_down_initial_pageup_writes":200,"wheel_down_initial_pageup_writes":50},
          "scope":"Installed eb4 snapshot versus ff1 upgrade, not C-only causal isolation. Five independent pairs per condition; 32 keys within each run are correlated.",
          "limits":["VT replay observes the emitted terminal text model, not physical paint. pyte Screen is an in-memory emulator; this does not validate every xterm/Ghostty extension.",
                    "Read-chunk timestamps are upper bounds on emission. A present end observed after a returned scroll write does not prove that write or all later writes were consumed.",
                    "Changing non-boundary Record sets supports actual viewport movement. It does not prove every scroll event changed a viewport or that movement was uniformly smooth.",
                    "CPU totals cover child startup, history reads, positioning, typing and teardown; positioning increased in this cohort, so old-cohort totals are not a causal comparator.",
                    "Earlier C normal-rate PageDown and burst/control results remain retained historical adverse evidence. They concern a different candidate; no normal-rate ff1 cohort was audited here.",
                    "Pooled p95 is descriptive. PageDown pooled p95 worsens despite a negative paired median; no uniform improvement or no-regression claim is supported.",
                    "Exact Unicode request verification, physical display, final installation CAS and live smoke are separate evidence layers."]}
(OUT/"observations.json").write_text(json.dumps(result,indent=2)+"\n")
lines = ["# Independent ff1 active-burst review","",result["scope"],"",
         f"Fixed cohort 50/50; integrity/replay discrepancies: {len(issues)}. All ACKs, frozen binaries/helper/history/fixtures and VT replay inputs were checked; no results were selected out.","",
         "## Latency and CPU","","| Condition | Pooled p95 before / after ms | Lower-p95 pairs | Median paired delta ms | CPU lower pairs |","| --- | --- | --- | --- | --- |"]
for g in comparisons:
    b,a=[g["pooled_descriptive_ms"][l]["p95"] for l in SHAS]
    lines.append(f"| {g['condition']} | {b:.2f} / {a:.2f} | {g['p95_lower_pairs']}/5 | {g['median_paired_p95_delta_ms']:+.2f} | {g['cpu_lower_pairs']}/5 |")
lines += ["",f"Whole-child CPU totals: {result['cpu_total_s']['before']:.4f} -> {result['cpu_total_s']['after']:.4f}s, lower in {result['cpu_lower_pairs']}/25 pairs. PageDown pooled p95 worsens and must accompany the favorable paired median.","",
          "## Active viewport and observer correction","",
          "The corrected helper sends 200 PageUp writes before timed input for PageDown and 50 PageUp writes before timed input for WheelDown. These are injected writes, not directly observed page offsets. The actual maximum is 153 scroll writes, so the conservative page movement is 153*37=5661 rows, below the 6363-row minimum available span from 6400 fixture content rows. This replaces the obsolete 151-write bound; the emitted VT Record IDs provide additional observations away from records 0 and 799.",
          "The v1 observer counted unpaired autowrap-enable markers from cleanup as frames and retained stale alternate-screen content in pyte. The v2 observer pairs disable/enable markers and uses scroll write return time. This audit independently replays both versions, preserves the original v1 digest and compares the corrected v2 frames. Cleanup markers do not count as presents.",
          "[pyte's primary documentation](https://github.com/selectel/pyte/blob/master/docs/tutorial.rst) describes Screen as an in-memory terminal text buffer and Stream as its event decoder. This supports VT-model observation, not physical display measurement.","",
          "| Condition | Runs | During Record range | Every run changes Record set | Every run has observed present end after last write return |","| --- | --- | --- | --- | --- |"]
for condition in CONDITIONS:
    rr=[r for r in runs if r["condition"]==condition]
    lo=min(r["viewport"]["record_min"] for r in rr if r["viewport"]["record_min"] is not None)
    hi=max(r["viewport"]["record_max"] for r in rr if r["viewport"]["record_max"] is not None)
    lines.append(f"| {condition} | {len(rr)} | {lo}..{hi} | {all(r['viewport']['record_set_changes']>0 for r in rr)} | {all(r['viewport']['observed_present_ends_after_last_scroll_return']>0 for r in rr)} |")
lines += ["","## Every pair","","| Condition | Pair | Order | Before / after p95 | Delta ms | Before / after CPU s | Before / after type gap ms | Before / after scroll Hz | Before / after load1 |","| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
for g in comparisons:
    for p in g["pairs"]:
        hz=f"{p['before_scroll_hz']:.2f} / {p['after_scroll_hz']:.2f}" if p["before_scroll_hz"] is not None else "none"
        lines.append(f"| {g['condition']} | {p['pair']} | {' -> '.join(p['order'])} | {p['before_p95_ms']:.2f} / {p['after_p95_ms']:.2f} | {p['p95_delta_ms']:+.2f} | {p['before_cpu_s']:.3f} / {p['after_cpu_s']:.3f} | {p['before_type_gap_ms']:.2f} / {p['after_type_gap_ms']:.2f} | {hz} | {p['before_load1']:.1f} / {p['after_load1']:.1f} |")
lines += ["","## Claim limits",""]+["- "+x for x in result["limits"]]
lines += ["","`observations.json` includes all 50 run digests, raw ACK replay checks, v1/v2 VT comparisons, gaps, load and pair clusters. This is a derived review; source/helper files, raw results and original observations were not edited. `analyze.py` launches no product or CI operation."]
(OUT/"README.md").write_text("\n".join(lines)+"\n")
(OUT/"manifest.json").write_text(json.dumps({"files":[{"path":p.name,"bytes":p.stat().st_size,"sha256":sha(p.read_bytes())} for p in sorted(OUT.iterdir()) if p.is_file() and p.name!="manifest.json"]},indent=2)+"\n")
print(json.dumps({"runs":len(runs),"issues":issues,"v2_available":bool(v2),"viewport":result["viewport_summary"]}),flush=True)
