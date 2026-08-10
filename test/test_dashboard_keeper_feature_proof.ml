(* Feature-proof gates read persisted keeper counters. [total_turns] is a
   lifetime counter, so a counter-only predicate latches: once a keeper takes
   its first turn the gate reports it forever, including after the keeper
   stops. These tests pin the recency requirement that separates a keeper
   taking turns now from one that took turns once. *)

open Alcotest
module U = Yojson.Safe.Util
module Keeper_meta_contract = Masc.Keeper_meta_contract
module Keeper_meta_store = Masc.Keeper_meta_store
module Keeper_owner_registry = Masc.Keeper_owner_registry
module Feature_proof = Dashboard_keeper_feature_proof

let () = ignore Operator_tool.force_link

(* Matches Dashboard_keeper_decision_log_proof.recent_turn_max_age_hours. The
   test states the boundary it exercises rather than importing it, so a silent
   widening of the production window fails here instead of following along. *)
let recent_window_hours = 24.0
let hour_seconds = 3600.0
let now = 1_800_000_000.0

let temp_dir () =
  let path = Filename.temp_file "dashboard_feature_proof_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Eio.Switch.run
  @@ fun sw ->
  (* Masc_test_deps.cleanup_test_workspace, not a local rm_rf: it stats with
     Unix.lstat, so a symlink is unlinked rather than followed. A local rm_rf
     built on Sys.file_exists reads a dangling link as absent, skips it, and
     leaves the parent non-empty for rmdir (#26648, fixed for the shared
     helper by #26652). *)
  Eio.Switch.on_release sw (fun () -> Masc_test_deps.cleanup_test_workspace dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  (match Keeper_owner_registry.install_from_store ~sw ~operation_executor:None config with
   | Ok _ -> ()
   | Error error ->
     fail
       ("owner inventory install failed: "
        ^ Keeper_owner_registry.install_error_to_string error));
  f config
;;

(* Both keepers have taken turns, so [total_turns > 0] holds for both. They
   differ only in when the last turn landed. *)
let seed_keeper config ~name ~last_turn_ts =
  let json =
    `Assoc
      [ "name", `String name
      ; "agent_name", `String ("keeper-" ^ name ^ "-agent")
      ; "trace_id", `String ("trace-" ^ name)
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Error err -> failf "meta fixture failed for %s: %s" name err
  | Ok meta ->
    let meta =
      Keeper_meta_contract.map_usage
        (fun usage -> { usage with total_turns = 5; last_turn_ts })
        meta
    in
    (match Keeper_meta_store.replace_snapshot config meta with
     | Ok () -> ()
     | Error err -> failf "replace_snapshot failed for %s: %s" name err)
;;

let feature_by_id payload id =
  payload
  |> U.member "features"
  |> U.to_list
  |> List.find_opt (fun feature -> U.member "id" feature |> U.to_string = id)
  |> function
  | Some feature -> feature
  | None -> failf "feature %s absent from payload" id
;;

let keeper_names feature key =
  feature
  |> U.member "keeper_evidence"
  |> U.member key
  |> U.to_list
  |> List.map U.to_string
  |> List.sort compare
;;

let test_stale_keeper_fails_runtime_liveness () =
  with_workspace
  @@ fun config ->
  seed_keeper config ~name:"fresh" ~last_turn_ts:(now -. hour_seconds);
  seed_keeper
    config
    ~name:"stale"
    ~last_turn_ts:(now -. ((recent_window_hours +. 2.0) *. hour_seconds));
  let payload = Feature_proof.json ~config ~now () in
  let feature = feature_by_id payload "runtime_liveness" in
  check
    (list string)
    "only the recently active keeper is observed"
    [ "fresh" ]
    (keeper_names feature "observed_keepers");
  check
    (list string)
    "the stopped keeper is reported missing"
    [ "stale" ]
    (keeper_names feature "missing_keepers");
  check
    string
    "a partially live fleet does not pass"
    "warn"
    (U.member "status" feature |> U.to_string)
;;

(* Guards the boundary from the other side: without this, a predicate that
   rejected every keeper would also satisfy the test above. *)
let test_recent_keeper_passes_runtime_liveness () =
  with_workspace
  @@ fun config ->
  seed_keeper config ~name:"fresh" ~last_turn_ts:(now -. hour_seconds);
  let payload = Feature_proof.json ~config ~now () in
  let feature = feature_by_id payload "runtime_liveness" in
  check
    (list string)
    "the recently active keeper is observed"
    [ "fresh" ]
    (keeper_names feature "observed_keepers");
  check
    string
    "a fully live fleet passes"
    "pass"
    (U.member "status" feature |> U.to_string)
;;

(* A keeper that never took a turn has no timestamp to be recent about. It must
   fail on the counter, not be admitted by a permissive timestamp branch. *)
let test_keeper_without_turns_fails_runtime_liveness () =
  with_workspace
  @@ fun config ->
  seed_keeper config ~name:"idle" ~last_turn_ts:0.0;
  let payload = Feature_proof.json ~config ~now () in
  let feature = feature_by_id payload "runtime_liveness" in
  check
    (list string)
    "a keeper with no turns is not observed"
    []
    (keeper_names feature "observed_keepers");
  check
    string
    "a fleet with no live keeper fails"
    "fail"
    (U.member "status" feature |> U.to_string)
;;

let () =
  run
    "dashboard_keeper_feature_proof"
    [ ( "runtime_liveness"
      , [ test_case "stale keeper fails" `Quick test_stale_keeper_fails_runtime_liveness
        ; test_case "recent keeper passes" `Quick test_recent_keeper_passes_runtime_liveness
        ; test_case
            "keeper without turns fails"
            `Quick
            test_keeper_without_turns_fails_runtime_liveness
        ] )
    ]
;;
