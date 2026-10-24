#!/usr/bin/env python3
"""Compare complete source tool-metrics readers using installed OCaml/SQLite.

No MASC build, server or operator database is used. Measurements are warm
in-process reads of synthetic SQLite fixtures under the OCaml interpreter.
The filesystem initializer is restricted to already-created fixture parents;
the day constant is supplied for the unused retention function. All reader,
connection, statement, binding, mutex and row-conversion code comes from source.
"""

import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import statistics
import subprocess


SOURCE = "lib/tool_metrics_store/tool_metrics_store.ml"
BASE = r"""
module Fs_compat = struct
  let mkdir_p path =
    if not (Sys.is_directory path) then invalid_arg "fixture parent missing"
end
module Masc_time_constants = struct let day = 86400. end
"""
PROBE = r"""
let require = function Ok value -> value | Error detail -> failwith detail
let canonical rows = `List rows |> Yojson.Safe.to_string
let before root lower upper count =
  Before.read_recent ~masc_root:root ?since_ts:lower ?until_ts:upper ~n:count ()
  |> require
let after root lower upper count =
  After.read_recent ~masc_root:root ?since_ts:lower ?until_ts:upper ~n:count ()
  |> require
let equal root lower upper count =
  canonical (List.map Before.row_to_json (before root lower upper count)) =
  canonical (List.map After.row_to_json (after root lower upper count))
let () =
  Printf.eprintf "SQLite %s\n%!" (Sqlite3.sqlite_version_info ());
  Printf.printf "rows,scenario,round,variant,iterations,mean_ms,bytes_per_call\n%!";
  let roots = Array.to_list Sys.argv |> List.tl |> List.map (fun root ->
    root, int_of_string (Filename.basename root |> String.split_on_char '-' |> List.rev |> List.hd)) in
  Fun.protect ~finally:(fun () -> Before.reset_for_testing (); After.reset_for_testing ()) (fun () ->
  List.iter (fun (root, count) ->
    let last = float_of_int ((count - 1) / 10) in
    let cases = [
      "unbounded",None,None;
      "empty_after",Some (last +. 1.),None;
      "upper_old",None,Some 3.;
      "bounded_middle",Some 1000.,Some 1002.;
      "inverted",Some 20.,Some 10.;
      "lower_tail",Some (last -. 1.),None;
      "bounded_tail",Some (last -. 3.),Some (last -. 1.)] in
    List.iter (fun (name,lower,upper) ->
      if not (equal root lower upper 20) then failwith ("different rows: "^name);
      Printf.eprintf "equivalent:rows=%d scenario=%s\n%!" count name;
      let measure round variant reader =
        let iterations=20 in
        let allocated=Gc.allocated_bytes () in
        let started=Mtime_clock.elapsed_ns () in
        for _=1 to iterations do
          ignore(Sys.opaque_identity(reader root lower upper 20))
        done;
        let elapsed=Int64.to_float(Int64.sub(Mtime_clock.elapsed_ns()) started)/.1e6 in
        Printf.printf "%d,%s,%d,%s,%d,%.9f,%.3f\n%!" count name round variant iterations
          (elapsed/.float iterations) ((Gc.allocated_bytes()-.allocated)/.float iterations) in
      for round=1 to 5 do
        if round mod 2=1 then (measure round "before" before;measure round "after" after)
        else (measure round "after" after;measure round "before" before)
      done) cases;
    List.iter (fun lower -> List.iter (fun upper ->
      List.iter (fun n ->
        if not (equal root lower upper n) then failwith "edge rows differ";
        Printf.eprintf "equivalent:edge rows=%d n=%d\n%!" count n) [-1;0;1;20])
      [None;Some nan;Some infinity;Some neg_infinity;Some 0.;Some last])
      [None;Some nan;Some infinity;Some neg_infinity;Some 0.;Some last]) roots)
"""


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before-ref", required=True)
    parser.add_argument("--after-root", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--rows", type=int, nargs="+", default=[30_000, 300_000])
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.before_ref) or any(n < 20 for n in args.rows):
        parser.error("full baseline SHA and fixture sizes >=20 required")
    root = args.after_root.resolve()
    before = subprocess.check_output(["git", "show", f"{args.before_ref}:{SOURCE}"], cwd=root)
    after = (root / SOURCE).read_bytes()
    out = args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=False)
    fixtures = []
    schema = before.decode().split("let schema_sql =\n  {|", 1)[1].split("|}", 1)[0]
    for count in args.rows:
        directory = out / f"fixture-{count}"
        directory.mkdir()
        with sqlite3.connect(directory / "tool-metrics.sqlite3") as db:
            db.execute(schema)
            db.execute("CREATE INDEX tool_metric_events_ts ON tool_metric_events(ts)")
            db.executemany("INSERT INTO tool_metric_events VALUES (?,?,?,?,?)", (
                (f"r{i:08d}", float(i // 10), "synthetic_metric", "completed", float(i % 7))
                for i in range(count)))
        fixtures.append(directory)
    packages = [(name, Path(subprocess.check_output(["ocamlfind", "query", name], text=True).strip()))
                for name in ("sqlite3", "yojson", "mtime", "mtime.clock.os")]
    command = ["ocaml", "-noinit", "unix.cma"]
    for name, path in packages:
        archive = "mtime_clock.cma" if name == "mtime.clock.os" else name + ".cma"
        command += ["-I", str(path), str(path / archive)]
    probe = BASE + "\nmodule Before = struct\n" + before.decode() + "\nend\n"
    probe += "module After = struct\n" + after.decode() + "\nend\n" + PROBE
    (out / "probe.ml").write_text(probe)
    (out / "before.ml").write_bytes(before)
    (out / "after.ml").write_bytes(after)
    command += [str(out / "probe.ml"), *map(str, fixtures)]
    metadata = {"before_ref": args.before_ref, "before_sha256": sha(before), "after_sha256": sha(after),
                "probe_sha256": sha(probe.encode()), "runner_sha256": sha(Path(__file__).read_bytes()),
                "ocaml": subprocess.check_output(["ocaml", "-version"], text=True).strip(),
                "seed_sqlite": sqlite3.sqlite_version, "command": command,
                "scope": __doc__, "clock": "Mtime_clock.elapsed_ns", "rows": args.rows,
                "library_sha256": {str(part): sha(Path(part).read_bytes()) for part in command
                                   if part.endswith(".cma") and Path(part).is_file()}}
    (out / "sources.json").write_text(json.dumps(metadata, indent=2) + "\n")
    with (out / "raw.csv").open("w") as raw, (out / "checks.txt").open("w") as checks:
        result = subprocess.run(command, stdout=raw, stderr=checks)
    metadata["exit_code"] = result.returncode
    (out / "sources.json").write_text(json.dumps(metadata, indent=2) + "\n")
    if result.returncode:
        raise SystemExit(f"probe failed; retain {out}/checks.txt")
    rows = list(csv.DictReader((out / "raw.csv").open()))
    expected = len(args.rows) * 7 * 5 * 2
    if len(rows) != expected:
        raise SystemExit(f"incomplete measurement rows: {len(rows)} != {expected}")
    summary = {"statistic": "median and worst batch means; not per-call percentiles", "results": []}
    for count in args.rows:
        for scenario in dict.fromkeys(row["scenario"] for row in rows):
            item = {"rows": count, "scenario": scenario}
            for variant in ("before", "after"):
                samples = [row for row in rows if int(row["rows"]) == count
                           and row["scenario"] == scenario and row["variant"] == variant]
                means = [float(row["mean_ms"]) for row in samples]
                item[variant] = {"median_ms": statistics.median(means), "worst_ms": max(means),
                                 "raw_means_ms": means, "median_allocated_bytes": statistics.median(
                                     float(row["bytes_per_call"]) for row in samples)}
            summary["results"].append(item)
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
