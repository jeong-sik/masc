#!/usr/bin/env python3
"""Compile real Context modules against explicit snapshot/config read fixtures."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess


def run(argv, cwd):
    result = subprocess.run(argv, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"{argv[0]} failed ({result.returncode}):\n{result.stdout[-4000:]}\n{result.stderr[-4000:]}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    repo, out = args.repo.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    identities = {}

    def source(path, baseline=False):
        data = run(["git", "show", f"{args.base}:{path}"], repo) if baseline else (repo / path).read_text()
        identities[("base:" if baseline else "candidate:") + path] = hashlib.sha256(data.encode()).hexdigest()
        return data

    for ext in ["ml", "mli"]:
        path = f"lib/workspace_memory/workspace_memory_context.{ext}"
        (out / f"baseline_context.{ext}").write_text(source(path, True))
        (out / f"workspace_memory_context.{ext}").write_text(source(path))
    for stem, extensions in [("agent_core_digest_slices", ["ml"]), ("agent_core_sha256", ["ml", "mli"])]:
        for ext in extensions:
            (out / f"{stem}.{ext}").write_text(source(f"packages/agent_core/lib/digest/{stem}.{ext}"))
    fixtures = {
        "fixture.ml": r'''
let reads = ref []
let serializations = ref 0
let clock = ref 42.
let note text = reads := text :: !reads
let reset () = reads := []; serializations := 0
let read path =
  note ("snapshot:" ^ path);
  let channel = open_in_bin path in
  let text = Fun.protect ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel)) in
  match text with
  | "ERROR" -> Error "fixture snapshot unreadable"
  | "GONE" -> Ok None
  | "SYS_ERROR" -> raise (Sys_error "fixture snapshot read failed")
  | "UNIX_ERROR" -> raise (Unix.Unix_error (Unix.EIO,"fixture-read",path))
  | text -> (try Ok (Some (Yojson.Safe.from_string text))
             with Yojson.Json_error _ -> Error "fixture invalid JSON")
let serialize value = incr serializations; value
''',
        "config_dir_resolver.ml": 'let keepers_dir_for_base_path ~base_path =\n Fixture.note ("resolve:" ^ base_path); Filename.concat base_path "keepers"\n',
        "time_compat.ml": 'let now () = !(Fixture.clock)\n',
        "keeper_types_profile.ml": r'''
let load_keeper_toml path =
  Fixture.note ("config:" ^ path);
  let channel = open_in_bin path in
  let text = Fun.protect ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel)) in
  try Ok (Yojson.Safe.from_string text |> Yojson.Safe.Util.to_string, ())
  with Yojson.Json_error _ -> Error "fixture invalid config"
'''
    }
    for stem, suffix in [("keeper_memory_os_current", ".ordinary.json"), ("keeper_memory_source_current", ".source.json")]:
        fixtures[stem + ".ml"] = f'''type t = Yojson.Safe.t
let path_for_keepers_dir ~keepers_dir ~keeper_id = Filename.concat keepers_dir (keeper_id ^ "{suffix}")
let keeper_id_of_filename name = Filename.chop_suffix_opt ~suffix:"{suffix}" name
let read_for_keepers_dir ~keepers_dir ~keeper_id = Fixture.read (path_for_keepers_dir ~keepers_dir ~keeper_id)
let to_json = Fixture.serialize
'''
    for name, text in fixtures.items():
        (out / name).write_text(text)
    probe = r'''
module B = Baseline_context
module C = Workspace_memory_context
let assertions = ref 0
let expect label value = incr assertions; if not value then failwith label
let base = Filename.concat (Sys.getcwd ()) "fixture-workspace"
let directory = Filename.concat base "keepers"
let write path text = let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel text)
let b_observation = function
  | B.Missing -> `String "missing"
  | B.Unavailable detail -> `Assoc ["unavailable", `String detail]
  | B.Available value -> value
let c_observation = function
  | C.Missing -> `String "missing"
  | C.Unavailable detail -> `Assoc ["unavailable", `String detail]
  | C.Available value -> value
let b_view = Result.map (fun captured -> B.keepers captured |> List.map (fun (k:B.keeper) ->
  k.keeper_id, b_observation k.ordinary, b_observation k.source_bound))
let c_view = Result.map (fun captured -> C.keepers captured |> List.map (fun (k:C.keeper) ->
  k.keeper_id, c_observation k.ordinary, c_observation k.source_bound))
let paired_case name =
  Fixture.reset (); let before = B.collect ~base_path:base in
  let reads = !(Fixture.reads) in
  Fixture.reset (); let after = C.collect ~base_path:base in
  expect "collect does no unused serialization" (!(Fixture.serializations) = 0);
  expect "same resolver/config/snapshot read trace" (reads = !(Fixture.reads));
  expect "same discovery, ordering, captured values and errors" (b_view before = c_view after);
  (match before,after with
   | Ok before,Ok after ->
     Fixture.reset ();
     expect "same canonical captured fingerprint" (B.fingerprint before = C.fingerprint after);
     expect "fingerprint does not reread" (!(Fixture.reads) = [])
   | Error _,Error _ -> ()
   | Ok _,Error _ | Error _,Ok _ -> failwith "result shape differs");
  Fixture.reset (); let old_http = B.http_json ~base_path:base |> Yojson.Safe.to_string in
  let reads = !(Fixture.reads) in
  Fixture.reset (); let new_http = C.http_json ~base_path:base |> Yojson.Safe.to_string in
  expect "same HTTP read trace" (reads = !(Fixture.reads));
  expect "same HTTP captured bytes under fixed clock" (old_http = new_http);
  Printf.printf "CASE %s\n%!" name;
  before,after
let measure label count fn =
  Gc.full_major (); Fixture.reset ();
  let allocated = Gc.allocated_bytes () in
  let cpu = Sys.time () and wall = Unix.gettimeofday () in
  for _ = 1 to count do ignore (Sys.opaque_identity (fn ())) done;
  let cpu_s = Sys.time () -. cpu and wall_s = Unix.gettimeofday () -. wall in
  let bytes = Gc.allocated_bytes () -. allocated in
  Printf.printf "MEASURE %s %d %.9f %.9f %.0f %d\n%!" label count cpu_s wall_s bytes !(Fixture.serializations)
let () =
  Unix.mkdir base 0o700;
  ignore (paired_case "missing_directory");
  write directory "not a directory";
  ignore (paired_case "regular_file_inventory");
  Unix.unlink directory; Unix.mkdir directory 0o700;
  ignore (paired_case "empty_inventory");
  write (Filename.concat directory "alias.toml") "\"actual\"";
  write (Filename.concat directory "duplicate.toml") "\"actual\"";
  write (Filename.concat directory "broken.toml") "{bad";
  write (Filename.concat directory "actual.ordinary.json") "{\"facts\":[\"first\"],\"revision\":1}";
  write (Filename.concat directory "actual.source.json") "{\"sources\":[\"a.md\"]}";
  let before,after = paired_case "canonical_owner_aliases_and_missing_stores" in
  let before = Result.get_ok before and after = Result.get_ok after in
  let captured = B.fingerprint before in
  Fixture.clock := 43.;
  let unchanged = C.collect ~base_path:base |> Result.get_ok in
  expect "observation time excluded" (captured = C.fingerprint unchanged);
  write (Filename.concat directory "actual.ordinary.json") "{\"facts\":[],\"revision\":2}";
  Fixture.reset ();
  expect "old captured identity survives disk replacement" (captured = C.fingerprint after);
  expect "old captured fingerprint performs no filesystem read" (!(Fixture.reads) = []);
  let changed = C.collect ~base_path:base |> Result.get_ok in
  expect "fresh changed snapshot changes fingerprint" (captured <> C.fingerprint changed);
  ignore (paired_case "replacement_snapshot");
  List.iter (fun (name,contents) -> write (Filename.concat directory (name ^ ".ordinary.json")) contents)
    ["corrupt","{bad"; "unreadable","ERROR"; "vanished","GONE"; "sys-error","SYS_ERROR"; "unix-error","UNIX_ERROR"];
  Unix.mkdir (Filename.concat directory "nonregular.source.json") 0o700;
  ignore (paired_case "snapshot_gaps_and_read_errors");
  write (Filename.concat directory "blank.toml") "\"  \"";
  ignore (paired_case "blank_owner_refuses_discovery");
  Unix.unlink (Filename.concat directory "blank.toml");
  (* Only the measured workload is enlarged; fixture input writes are outside timing. *)
  let large = Yojson.Safe.to_string (`Assoc ["facts",`List [`String (String.make (1024*1024) 'x')]]) in
  for i = 1 to 8 do write (Filename.concat directory (Printf.sprintf "large%d.ordinary.json" i)) large done;
  ignore (paired_case "eight_one_mib_snapshots");
  measure "collect_before" 3 (fun () -> B.collect ~base_path:base);
  measure "collect_after" 3 (fun () -> C.collect ~base_path:base);
  measure "http_before" 3 (fun () -> B.http_json ~base_path:base);
  measure "http_after" 3 (fun () -> C.http_json ~base_path:base);
  measure "collect_and_fingerprint_before" 3 (fun () -> B.collect ~base_path:base |> Result.map B.fingerprint);
  measure "collect_and_fingerprint_after" 3 (fun () -> C.collect ~base_path:base |> Result.map C.fingerprint);
  Printf.printf "ASSERTIONS %d\n%!" !assertions
'''
    (out / "probe.ml").write_text(probe)
    flags = ["ocamlfind", "ocamlopt", "-package", "yojson,digestif.c,unix", "-linkpkg", "-w", "+4+32+69", "-warn-error", "+4+8+32+69"]
    modules = ["fixture.ml", "config_dir_resolver.ml", "time_compat.ml", "keeper_types_profile.ml", "keeper_memory_os_current.ml", "keeper_memory_source_current.ml", "agent_core_digest_slices.ml", "agent_core_sha256.mli", "agent_core_sha256.ml", "baseline_context.mli", "baseline_context.ml", "workspace_memory_context.mli", "workspace_memory_context.ml", "probe.ml"]
    run(flags + modules + ["-o", "probe"], out)
    output = run([str(out / "probe")], out)
    (out / "probe.stdout.txt").write_text(output)
    tests, measurements, assertions = [], [], None
    for line in output.splitlines():
        parts = line.split()
        if parts[0] == "CASE":
            tests.append(parts[1])
        elif parts[0] == "ASSERTIONS":
            assertions = int(parts[1])
        elif parts[0] == "MEASURE":
            measurements.append(dict(label=parts[1], iterations=int(parts[2]), cpu_s=float(parts[3]), wall_s=float(parts[4]), allocated_bytes=int(parts[5]), snapshot_serializations=int(parts[6])))
    test = "test/test_server_dashboard_http_keeper_memory_health.ml"
    identities["candidate:" + test] = hashlib.sha256((repo / test).read_bytes()).hexdigest()
    run(["ocamlc", "-stop-after", "parsing", "-o", str(out / "health-test.cmo"), "-impl", str(repo / test)], out)
    result = dict(schema="workspace-context-fingerprint-probe.v1", base_commit=args.base, source_sha256=identities, ocamlopt_version=run(["ocamlopt", "-version"], out).strip(), machine=platform.machine(), cases=tests, assertions_passed=assertions, measurements=measurements, probe_script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), limits=["Complete real Context implementations/interfaces and real Agent_core SHA implementation compiled directly, without Dune.", "Snapshot and configuration modules are explicit fixtures, not real Keeper codecs or storage authority.", "Actual Unix stat/readdir and temporary files are used; time is fixed for exact HTTP JSON comparisons.", "The changed real Keeper-health test source passed parsing only, not typing or execution.", "Synthetic one-process measurements are not production CPU/RSS or installed behavior evidence."])
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"cases":tests,"assertions_passed":assertions,"measurements":measurements}))


if __name__ == "__main__":
    main()
