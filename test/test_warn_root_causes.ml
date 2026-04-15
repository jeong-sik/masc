(** Harness tests for WARN root cause fixes.

    1. AllowList pruning: core_discovery_tools filtered by preset
    2. Atomic agent JSON writes: no empty-file race condition *)

open Alcotest
open Masc_mcp

(* ── Helpers ──────────────────────────────────────────────────── *)

let init_registry () =
  Masc_test_deps.init_keeper_tool_registry ();
  let base_path = Masc_test_deps.find_project_root () in
  match Keeper_tool_policy.init_policy_config ~base_path with
  | Ok () -> ()
  | Error e -> failwith (Printf.sprintf "init_policy_config failed: %s" e)

let make_meta ?(name = "test-keeper") () : Keeper_types.keeper_meta =
  match Keeper_types.meta_of_json
    (`Assoc [("name", `String name); ("agent_name", `String name);
             ("trace_id", `String "test-trace-warn")]) with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_meta failed: %s" e)

(** Build the allowed_exec_set exactly as keeper_agent_run.ml does:
    preset-allowed names + core_always_tools. *)
let build_allowed_exec_set (meta : Keeper_types.keeper_meta) =
  let allowed_names = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let set = Keeper_tool_policy.tool_name_set allowed_names in
  List.iter
    (fun name -> Hashtbl.replace set name ())
    Keeper_tool_registry.core_always_tools;
  set

(** Filter core_discovery_tools by preset (the fix). *)
let filter_core_by_preset (meta : Keeper_types.keeper_meta) =
  let allowed_set = build_allowed_exec_set meta in
  List.filter
    (fun name -> Hashtbl.mem allowed_set name)
    Keeper_tool_registry.core_discovery_tools

(* Direct write tools require coding/delivery/full presets. *)
let write_only_tools = [ "keeper_fs_edit" ]

(* keeper_bash stays visible across presets for read-only shell usage.
   Mutating shell commands are gated separately by shell_write_presets. *)
let shell_bridge_tools = [ "keeper_bash" ]

(* ── Test 1: Core discovery tools respect preset ──────────────── *)

let test_core_tools_filtered_by_research_preset () =
  ignore (init_registry ());
  let meta =
    { (make_meta ~name:"test-research" ()) with
      tool_access = Preset { preset = Research; also_allow = [] };
      tool_denylist = [] }
  in
  (* Precondition: direct write tools ARE in unfiltered core *)
  List.iter (fun t ->
    if not (List.mem t Keeper_tool_registry.core_discovery_tools) then
      fail (Printf.sprintf "precondition: %s missing from core_discovery_tools" t)
  ) write_only_tools;
  let filtered = filter_core_by_preset meta in
  (* Direct write tools must NOT survive preset filter. *)
  List.iter (fun t ->
    if List.mem t filtered then
      fail (Printf.sprintf "%s should be excluded for research preset" t)
  ) write_only_tools;
  List.iter (fun t ->
    if not (List.mem t filtered) then
      fail (Printf.sprintf "%s should stay visible for read-only shell use" t)
  ) shell_bridge_tools;
  (* Core always-tools must survive *)
  List.iter (fun t ->
    if not (List.mem t filtered) then
      fail (Printf.sprintf "core_always %s must survive preset filter" t)
  ) Keeper_tool_registry.core_always_tools

let test_core_tools_filtered_by_social_preset () =
  ignore (init_registry ());
  let meta =
    { (make_meta ~name:"test-social" ()) with
      tool_access = Preset { preset = Social; also_allow = [] };
      tool_denylist = [] }
  in
  let filtered = filter_core_by_preset meta in
  if List.mem "keeper_fs_edit" filtered then
    fail "keeper_fs_edit should be excluded for social preset"

let test_core_tools_include_write_for_coding_preset () =
  ignore (init_registry ());
  let meta =
    { (make_meta ~name:"test-coding" ()) with
      tool_access = Preset { preset = Coding; also_allow = [] };
      tool_denylist = [] }
  in
  let filtered = filter_core_by_preset meta in
  List.iter (fun t ->
    if not (List.mem t filtered) then
      fail (Printf.sprintf "%s should be included for coding preset" t)
  ) (write_only_tools @ shell_bridge_tools)

(* ── Test 2: Atomic agent JSON writes ─────────────────────────── *)

let test_atomic_write_not_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_atomic_%d" (Random.int 1_000_000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = Filename.concat dir "test_agent.json" in
  let json =
    `Assoc [ ("name", `String "test"); ("status", `String "ok") ]
  in
  Room_utils.write_json_local path json;
  let content = Fs_compat.load_file path in
  check bool "file not empty after atomic write" true
    (String.length content > 0);
  let parsed = Yojson.Safe.from_string content in
  check string "name field" "test"
    (Yojson.Safe.Util.member "name" parsed |> Yojson.Safe.Util.to_string);
  (* Verify .tmp is cleaned up *)
  check bool "no leftover .tmp" false (Sys.file_exists (path ^ ".tmp"));
  (try Unix.unlink path with _ -> ());
  (try Unix.rmdir dir with _ -> ())

(** Concurrent writes via atomic pattern must never produce empty reads. *)
let test_concurrent_atomic_writes_never_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_concurrent_%d" (Random.int 1_000_000)) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = Filename.concat dir "agent.json" in
  (* Seed with initial content *)
  Room_utils.write_json_local path
    (`Assoc [ ("name", `String "init") ]);
  let empty_seen = ref false in
  let iterations = 200 in
  Eio.Switch.run @@ fun sw ->
  (* Writer fiber: rapidly update the file *)
  Eio.Fiber.fork ~sw (fun () ->
    for i = 1 to iterations do
      let json =
        `Assoc [ ("name", `String (Printf.sprintf "v%d" i)) ]
      in
      Room_utils.write_json_local path json;
      Eio.Fiber.yield ()
    done);
  (* Reader fiber: read concurrently *)
  Eio.Fiber.fork ~sw (fun () ->
    for _ = 1 to iterations do
      (try
         let content = Fs_compat.load_file path in
         if String.trim content = "" then empty_seen := true
       with _ -> ());
      Eio.Fiber.yield ()
    done);
  check bool "concurrent reads never see empty file" false !empty_seen;
  (try Unix.unlink path with _ -> ());
  (try Unix.rmdir dir with _ -> ())

(* ── Runner ───────────────────────────────────────────────────── *)

let () =
  run "Warn_root_causes"
    [
      ( "allowlist_preset_filter",
        [
          test_case "research preset excludes direct write tools" `Quick
            test_core_tools_filtered_by_research_preset;
          test_case "social preset excludes direct write tools" `Quick
            test_core_tools_filtered_by_social_preset;
          test_case "coding preset includes shell + write tools" `Quick
            test_core_tools_include_write_for_coding_preset;
        ] );
      ( "atomic_agent_json",
        [
          test_case "atomic write produces non-empty file" `Quick
            test_atomic_write_not_empty;
          test_case "concurrent writes never produce empty reads" `Quick
            test_concurrent_atomic_writes_never_empty;
        ] );
    ]
