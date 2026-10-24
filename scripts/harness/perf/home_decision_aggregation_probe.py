#!/usr/bin/env python3
"""Compare exact-source Home aggregation with an installed OCaml interpreter.

Example:
  python3 scripts/harness/perf/home_decision_aggregation_probe.py \
    --before-ref <40-character-sha> --output-dir /tmp/home-aggregation-new

Requires existing ocaml, ocamlfind, mtime and mtime.clock.os. No build is run.
The generated probe copies source types and aggregation expressions; it only
recreates their enclosing module. Results are median/worst batch means, not
per-call percentiles, complete Home projection, native TUI or live-agent proof.
"""

import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys


HOME = "bin/masc_tui_home.ml"
TYPES = "bin/masc_tui_types.ml"
ASKS = "lib/tui_decode_asks.ml"
SCOPE = ("Exact extracted Home decision aggregation under the OCaml interpreter; "
         "not complete Home projection, native frame timing, terminal paint, "
         "live-agent scale, installed performance or a latency target verdict")
BENCHMARK = r"""let installation title declaration id =
  Home_request (Home_question {Masc.Tui_decode_asks.ak_asker =
    Ask_installation {ai_title=title;ai_declaration_id=declaration};ak_id=id})
let keeper_ask name id = Home_request (Home_question
  {Masc.Tui_decode_asks.ak_asker=Ask_keeper name;ak_id=id})
let apply f rows =
  let count = List.length rows in
  let a=count/5 and b=count*2/5 and c=count*3/5 and d=count*4/5 in
  f (List.take a rows) (List.take (b-a) (List.drop a rows))
    (List.take (c-b) (List.drop b rows)) (List.take (d-c) (List.drop c rows))
    (List.drop d rows)
let check name rows =
  let previous=apply before rows and candidate=apply after rows in
  if previous<>candidate then failwith ("aggregation changed: "^name);
  Printf.eprintf "equivalent:%s rows=%d result=%d\n%!" name (List.length rows) (List.length candidate)
let () =
  check "empty" [];
  check "duplicates and agenda order" [Home_agenda,"first";Home_choose_keeper,"keeper";
    Home_agenda,"second";Home_choose_keeper,"changed";Home_agenda,"third";
    Home_create_keeper,"new";Home_approvals,"all";Home_resume "k","resume";
    Home_read_last "k","history";Home_resume "k","ignored"];
  check "request kind and call ownership" [
    Home_request(Home_held_call{keeper="a";call_id="same"}),"a";
    Home_request(Home_held_call{keeper="b";call_id="same"}),"b";
    Home_request(Home_held_call{keeper="a";call_id="other"}),"other";
    Home_request(Home_gate_request "same"),"gate";
    Home_request(Home_operator_request "same"),"operator";
    Home_request(Home_goal_confirmation "same"),"goal";
    Home_request(Home_operator_task "same"),"task";
    Home_request(Home_gate_request "same"),"gate ignored"];
  check "ask identities and structural title behavior" [
    installation "one" "a" "id","a";installation "two" "b" "id","b";
    installation "one" "a" "id","ignored";installation "changed" "a" "id","changed";
    keeper_ask "a" "id","keeper";keeper_ask "b" "id","keeper b"];
  Random.init 724;
  let identities=Array.of_list [Home_agenda;Home_approvals;Home_choose_keeper;
    Home_request(Home_gate_request "x");Home_request(Home_operator_task "x");
    installation "one" "a" "id";installation "two" "b" "id"] in
  for round=1 to 100 do
    check ("mixed-"^string_of_int round)
      (List.init (Random.int 200) (fun index ->
        identities.(Random.int (Array.length identities)),string_of_int index))
  done;
  Printf.printf "requests,round,variant,iterations,mean_ms,allocated_bytes_per_projection\n";
  List.iter (fun n ->
    let rows=List.init n (fun index ->
      let id=string_of_int index in
      let action=match index mod 5 with
      |0->Home_request(Home_held_call{keeper="keeper-"^id;call_id="call-"^id})
      |1->Home_request(Home_gate_request id)
      |2->Home_request(Home_operator_request id)
      |3->keeper_ask ("keeper-"^id) id
      |_->installation ("package-"^id) ("lane-"^id) id in
      action,"request-"^id) in
    check ("scale-"^string_of_int n) rows;
    let count=List.length rows in
    let a=count/5 and b=count*2/5 and c=count*3/5 and d=count*4/5 in
    let p=List.take a rows and q=List.take (b-a) (List.drop a rows)
    and r=List.take (c-b) (List.drop b rows) and s=List.take (d-c) (List.drop c rows)
    and t=List.drop d rows in
    let iterations=if n<=30 then 1000 else if n<=300 then 100 else 3 in
    let measure round (name,f) =
      Gc.compact ();
      let allocated=Gc.allocated_bytes () in
      let started=Mtime_clock.elapsed_ns () in
      for _=1 to iterations do ignore(Sys.opaque_identity(f p q r s t)) done;
      let elapsed=Int64.to_float (Int64.sub (Mtime_clock.elapsed_ns ()) started) /. 1e9 in
      let bytes=Gc.allocated_bytes()-.allocated in
      Printf.printf "%d,%d,%s,%d,%.9f,%.3f\n%!" n round name iterations
        (elapsed*.1000./.float iterations) (bytes/.float iterations) in
    for round=1 to 9 do
      List.iter (measure round)
        (if round mod 2=1 then ["before",before;"after",after]
         else ["after",after;"before",before])
    done) [30;300;3000]
"""


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def extract(source, start, end):
    first = source.index(start)
    return source[first:source.index(end, first)]


def aggregation(source):
    first = source.index("  (* Equality is kind plus authoritative request ID")
    first = source.index("*)\n", first) + len("*)\n")
    return source[first:source.index("\nlet clear_ask_answering", first)].strip()


def declarations(files):
    return (extract(files[ASKS], "type ask_asker =", "\nlet ask_asker_label"),
            extract(files[ASKS], "type ask_key =", "\nlet ask_key "),
            extract(files[TYPES], "type home_request =",
                    "\n(* Which request a Home row names."))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before-ref", required=True, help="full baseline commit SHA")
    parser.add_argument("--after-root", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--output-dir", type=Path, required=True, help="new evidence directory")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.before_ref):
        parser.error("before-ref must be a full lowercase commit SHA")
    root = args.after_root.resolve(strict=True)
    ocaml = shutil.which("ocaml")
    ocamlfind = shutil.which("ocamlfind")
    if not ocaml or not ocamlfind:
        parser.error("existing ocaml and ocamlfind executables are required")
    try:
        before = {name: subprocess.check_output(
            ["git", "show", f"{args.before_ref}:{name}"], cwd=root, text=True)
                  for name in (HOME, TYPES, ASKS)}
        after = {name: (root / name).read_text() for name in (HOME, TYPES, ASKS)}
        if declarations(before) != declarations(after):
            parser.error("baseline and candidate action type declarations differ")
        asker, ask_key, home_types = declarations(after)
        old = aggregation(before[HOME])
        helper = extract(after[HOME], "module Action_table =", "\n(* Current successes survive")
        new = aggregation(after[HOME])
        mtime = Path(subprocess.check_output([ocamlfind, "query", "mtime"], text=True).strip())
        clock = Path(subprocess.check_output(
            [ocamlfind, "query", "mtime.clock.os"], text=True).strip())
        for archive in (mtime / "mtime.cma", clock / "mtime_clock.cma"):
            if not archive.is_file():
                parser.error(f"existing bytecode archive is missing: {archive}")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.error(str(error))
    probe = ("module Masc = struct module Tui_decode_asks = struct\n"
             + asker + "\n" + ask_key + "\nend end\n" + home_types
             + "\nlet before approval_rows questions goals tasks approvals =\n" + old
             + "\n" + helper
             + "\nlet after approval_rows questions goals tasks approvals =\n" + new
             + "\n" + BENCHMARK)
    args.output_dir.mkdir(parents=True, exist_ok=False)
    out = args.output_dir.resolve()
    probe_path = out / "probe.ml"
    probe_path.write_text(probe)
    command = [ocaml, "-noinit", "-I", str(mtime), str(mtime / "mtime.cma"),
               "-I", str(clock), str(clock / "mtime_clock.cma"), str(probe_path)]
    metadata = {
        "schema_version": 1, "scope": SCOPE, "before_ref": args.before_ref,
        "after_root": str(root), "clock": "Mtime_clock.elapsed_ns (monotonic)",
        "version": subprocess.check_output([ocaml, "-version"], text=True).strip(),
        "command": command, "requests": [30, 300, 3000], "alternating_rounds": 9,
        "iterations_per_batch": {"30": 1000, "300": 100, "3000": 3},
        "type_shim": "Only enclosing Masc.Tui_decode_asks module recreated; declarations copied exactly",
        "before_files_sha256": {name: digest(value) for name, value in before.items()},
        "after_files_sha256": {name: digest(value) for name, value in after.items()},
        "before_aggregation_sha256": digest(old),
        "after_helper_sha256": digest(helper), "after_aggregation_sha256": digest(new),
        "probe_sha256": digest(probe), "runner_sha256": digest(Path(__file__).read_text()),
        "mtime_archives_sha256": {
            str(path): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in (mtime / "mtime.cma", clock / "mtime_clock.cma")},
    }
    (out / "sources.json").write_text(json.dumps(metadata, indent=2) + "\n")
    with (out / "raw.csv").open("w") as raw, (out / "checks.txt").open("w") as checks:
        result = subprocess.run(command, stdout=raw, stderr=checks, check=False)
    metadata["interpreter_exit_code"] = result.returncode
    (out / "sources.json").write_text(json.dumps(metadata, indent=2) + "\n")
    if result.returncode:
        print(f"interpreter failed; retained evidence in {out}", file=sys.stderr)
        return result.returncode
    with (out / "raw.csv").open() as raw:
        rows = list(csv.DictReader(raw))
    summary = {"scope": SCOPE, "statistic": "batch means; not per-call percentiles", "results": []}
    for count in metadata["requests"]:
        item = {"requests": count}
        for variant in ("before", "after"):
            population = [row for row in rows if int(row["requests"]) == count
                          and row["variant"] == variant]
            means = [float(row["mean_ms"]) for row in population]
            item[variant] = {
                "rounds": len(means), "median_batch_mean_ms": statistics.median(means),
                "worst_batch_mean_ms": max(means), "raw_batch_mean_ms": means,
                "median_allocated_bytes_per_projection": statistics.median(
                    float(row["allocated_bytes_per_projection"]) for row in population),
            }
        summary["results"].append(item)
    summary["equivalence_cases"] = sum(
        line.startswith("equivalent:") for line in (out / "checks.txt").read_text().splitlines())
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
