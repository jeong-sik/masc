#!/usr/bin/env python3
"""Exact-source differential and postprocessing probe; no target process/events read."""

import argparse, csv, datetime, hashlib, json, pathlib, re, statistics, subprocess


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--repo", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[3]
    )
    p.add_argument("--before-ref", default="63960ad2c29fcafcd8b1785269c7d687d39e5194")
    p.add_argument(
        "--after", type=pathlib.Path, help="Candidate checkout; defaults to --repo"
    )
    p.add_argument(
        "--dimensions",
        type=pathlib.Path,
        default=pathlib.Path(__file__).with_name("rtev_late_arrival_dimensions.json"),
    )
    p.add_argument(
        "--output", type=pathlib.Path, required=True, help="New evidence directory"
    )
    p.add_argument(
        "--prepare-only",
        action="store_true",
        help="Write source-bound probe and metadata without running OCaml",
    )
    p.add_argument(
        "--rounds",
        type=int,
        default=3,
        help="Alternating timing rounds; zero performs correctness checks only",
    )
    args = p.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.before_ref) or args.rounds < 0:
        p.error("A full baseline SHA and nonnegative round count are required")
    args.repo = args.repo.resolve()
    args.after = (args.after or args.repo).resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    rel = "tools/rtev_trace/rtev_watch.ml"
    ref = args.before_ref
    before = subprocess.check_output(
        ["git", "show", f"{ref}:{rel}"], cwd=args.repo
    ).decode()
    after = (args.after / rel).read_text()

    def extract(s):
        helpers = s[s.index("module RE =") : s.index("let () =")]
        first = s.index("  (* For each stop-the-world")
        last = s.index('  Printf.printf "\\nstw late arrivals:', first)
        return helpers, s[first:last]

    modules = []
    for label, source in [("Before", before), ("After", after)]:
        helpers, body = extract(source)
        modules.append(
            "module "
            + label
            + " = struct\n"
            + helpers
            + "\nlet compute barrier_rows handler_begins =\n  let barriers=ref barrier_rows in\n"
            + body
            + "  late\nlet canonical late = Hashtbl.fold (fun d a xs -> (d,a.count,a.total_ns,a.max_ns,a.n,Array.sub a.samples 0 a.n |> Array.to_list)::xs) late [] |> List.sort compare\nend\n"
        )
    # The observed handler counts are completed spans, not all begin events.
    # They size wholly synthetic begin lists; boundary-open begins were not retained.
    dimensions_document = json.loads(args.dimensions.read_text())
    dimensions = []
    seen_domains = set()
    for row in dimensions_document["rows"]:
        values = (
            row["domain"],
            row["completed_handler_spans"],
            row["completed_api_barrier_spans"],
        )
        if (
            any(type(value) is not int or value < 0 for value in values)
            or values[0] in seen_domains
        ):
            p.error(
                "Dimensions need unique nonnegative integer domains and span counts"
            )
        seen_domains.add(values[0])
        dimensions.append(values)
    dims = ";".join(f"({d},{h},{b})" for d, h, b in dimensions)
    probe = (
        """#use "topfind";;
#require "unix,runtime_events,mtime.clock.os";;
"""
        + "".join(modules)
        + r"""
let checked=ref 0
let check label barriers handlers =
 let before=Before.compute barriers handlers |> Before.canonical in
 let after=After.compute barriers handlers |> After.canonical in
 if before<>after then failwith ("differential failed: "^label);
 incr checked
let table entries = let t=Hashtbl.create ~random:true 32 in List.iter (fun (d,l)->Hashtbl.replace t d l) entries;t
let () =
 List.iter (fun (label,barriers,entries)->check label barriers (table entries)) [
  "empty",[],[];
  "no handlers",[0,0L,10L],[];
  "no barriers",[],[0,[1L;2L];1,[3L]];
  "leader excluded",[0,0L,10L],[0,[10L]];
  "both inclusive endpoints",[0,5L,10L],[1,[5L;2_000_010L;2_000_011L;4L]];
  "duplicate begins and domains tie",[9,0L,0L],[4,[1L;1L];2,[1L;1L];8,[1L]];
  "duplicate barriers",[0,0L,0L;0,0L,0L;1,0L,0L],[1,[0L];2,[0L]];
  "unsorted starts",[7,10L,20L],[1,[20L;9L;2_000_020L;10L;12L]];
  "empty domain",[0,0L,0L],[1,[];2,[0L]];
  "negative timestamps",[9,(-10L),(-2_000_005L)],[1,[-5L;-10L;-11L;0L]];
  "inverted bound",[9,100L,(-3_000_000L)],[1,[0L;100L]];
  "upper overflow",[9,Int64.min_int,Int64.max_int],[1,[Int64.min_int;Int64.max_int;-1L;0L]]];
 let rng=Random.State.make [|741;20261024|] in
 for case=0 to 4999 do
  let domains=1+Random.State.int rng 12 in
  let handlers=Hashtbl.create ~random:true domains in
  for d=0 to domains-1 do
   Hashtbl.add handlers d (List.init (Random.State.int rng 35) (fun _ ->
    Int64.of_int ((Random.State.int rng 30-15)*100_000)))
  done;
  let barriers=List.init (Random.State.int rng 30) (fun _ ->
   let first=Int64.of_int ((Random.State.int rng 30-15)*100_000) in
   (Random.State.int rng (domains+1),first,Int64.sub first (Int64.of_int (Random.State.int rng 4_000_001)))) in
  check (string_of_int case) barriers handlers
 done;
 Printf.eprintf "equivalent:%d complete accumulator comparisons; inclusive bounds, leader exclusion, ties, empty/duplicate/inverted/overflow and seeded fixtures\n%!" !checked
let dimensions=[DIMENSIONS]
let synthetic dimensions =
 let handlers=Hashtbl.create 32 in
 let barriers=ref [] in
 List.iter (fun (d,h,b) ->
  Hashtbl.add handlers d (List.init h (fun i -> Int64.add (Int64.mul (Int64.of_int i) 26_000_000L) (Int64.of_int (d*1000))));
  for i=0 to b-1 do
   let first=Int64.mul (Int64.of_int i) 26_000_000L in
   barriers:=(d,first,Int64.add first 150_000L)::!barriers
  done) dimensions;
 !barriers,handlers
let measure round name label compute barriers handlers =
 Gc.full_major();
 let allocated=Gc.allocated_bytes() and cpu=Sys.time() and wall=Mtime_clock.counter() in
 ignore(Sys.opaque_identity(compute barriers handlers));
 let wall_ms=Mtime.Span.to_float_ns(Mtime_clock.count wall)/.1e6 in
 let cpu_ms=(Sys.time()-.cpu)*.1000. in
 let bytes=Gc.allocated_bytes()-.allocated in
 Printf.printf "%d,%s,%s,%.6f,%.6f,%.0f\n%!" round name label wall_ms cpu_ms bytes
let () =
 Printf.printf "round,fixture,variant,wall_ms,cpu_ms,allocated_bytes\n%!";
 List.iter (fun (name,dims) ->
  let barriers,handlers=synthetic dims in
  check ("synthetic-"^name) barriers handlers;
  for round=1 to ROUNDS do
   if round mod 2=0 then (
    measure round name "after" After.compute barriers handlers;
    measure round name "before" Before.compute barriers handlers)
   else (
    measure round name "before" Before.compute barriers handlers;
    measure round name "after" After.compute barriers handlers)
  done) ["empty",[];"small",List.init 3 (fun d->d,30,30);"captured_counts",dimensions]
""".replace("DIMENSIONS", dims).replace("ROUNDS", str(args.rounds))
    )
    (args.output / "probe.ml").write_text(probe)
    (args.output / "before.ml").write_text(before)
    (args.output / "after.ml").write_text(after)
    (args.output / "runner.py").write_bytes(pathlib.Path(__file__).read_bytes())
    (args.output / "synthetic-dimensions.json").write_text(
        json.dumps(dimensions, indent=2) + "\n"
    )
    meta = {
        "scope": "Exact diagnostic late-arrival postprocess including index construction/sorting and accumulator writes; wholly synthetic timestamps; completed-handler-span histogram sizes synthetic begin lists, not exact captured begins. No runtime window, event collection, native target, current MASC load or causality proof.",
        "before_ref": ref,
        "before_sha256": sha(before.encode()),
        "after_sha256": sha(after.encode()),
        "probe_sha256": sha(probe.encode()),
        "runner_sha256": sha(pathlib.Path(__file__).read_bytes()),
        "dimensions_sha256": sha(args.dimensions.read_bytes()),
        "dimension_provenance": dimensions_document,
        "rounds": args.rounds,
        "clock": "Mtime monotonic + Sys.time CPU",
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "ocaml": subprocess.check_output(["ocaml", "-version"], text=True).strip(),
    }
    (args.output / "sources.json").write_text(json.dumps(meta, indent=2) + "\n")
    if args.prepare_only:
        print(json.dumps({"prepared_only": True, "probe_sha256": meta["probe_sha256"]}))
        return
    with (
        (args.output / "raw.csv").open("w") as out,
        (args.output / "checks.txt").open("w") as err,
    ):
        result = subprocess.run(
            ["ocaml", "-noinit", str(args.output / "probe.ml")], stdout=out, stderr=err
        )
    meta.update(
        exit_code=result.returncode,
        finished_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    )
    (args.output / "sources.json").write_text(json.dumps(meta, indent=2) + "\n")
    result.check_returncode()
    rows = list(csv.DictReader((args.output / "raw.csv").open()))
    assert len(rows) == args.rounds * 3 * 2
    if args.rounds == 0:
        (args.output / "summary.json").write_text("[]\n")
        print("Correctness checks passed; no timed observations requested")
        return
    summary = []
    for fixture in ["empty", "small", "captured_counts"]:
        s = {
            "fixture": fixture,
            "statistic": "median/worst late-arrival accumulator construction, excluding summary rendering; not event/operation percentiles",
        }
        for variant in ["before", "after"]:
            selected = [
                r for r in rows if r["fixture"] == fixture and r["variant"] == variant
            ]
            s[variant] = {
                metric: {
                    "median": statistics.median(float(r[metric]) for r in selected),
                    "worst": max(float(r[metric]) for r in selected),
                }
                for metric in ["wall_ms", "cpu_ms", "allocated_bytes"]
            }
        summary.append(s)
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
