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
  (match Keeper_owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config with
   | Ok _ -> ()
   | Error error ->
     fail
       ("owner inventory install failed: "
        ^ Keeper_owner_registry.install_error_to_string error));
  f config
;;

(* Both keepers have taken turns, so [total_turns > 0] holds for both. They
   differ only in when the last turn landed. *)
let seed_keeper config ?(autonomous_at = "") ~name ~last_turn_ts () =
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
    let meta =
      Keeper_meta_contract.map_runtime
        (fun runtime ->
           { runtime with
             autonomous_action_count = 3
           ; autonomous_tool_turn_count = 2
           ; board_reactive_turn_count = 4
           ; last_autonomous_action_at = autonomous_at
           })
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

let append_turn_exchange config keeper_name ts =
  Masc.Keeper_types_support.append_jsonl_line
    (Masc.Keeper_types_support.keeper_decision_log_path config keeper_name)
    (`Assoc [ "channel", `String "turn"; "ts_unix", `Float ts ])
;;

let test_stale_keeper_fails_runtime_liveness () =
  with_workspace
  @@ fun config ->
  seed_keeper config ~name:"fresh" ~last_turn_ts:(now -. hour_seconds) ();
  seed_keeper
    config
    ~name:"stale"
    ~last_turn_ts:(now -. ((recent_window_hours +. 2.0) *. hour_seconds))
    ();
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
  seed_keeper config ~name:"fresh" ~last_turn_ts:(now -. hour_seconds) ();
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
  seed_keeper config ~name:"idle" ~last_turn_ts:0.0 ();
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

(* [autonomous_tool_use] and [board_reactive_autonomy] read lifetime counters,
   which never decrease. Both keepers below carry the same counters; only the
   timestamps differ, so a predicate that ignores time reports them
   identically. *)
let iso_ago seconds = Masc_domain.iso8601_of_unix_seconds (now -. seconds)

let test_stale_keeper_fails_autonomous_tool_use () =
  with_workspace
  @@ fun config ->
  seed_keeper
    config
    ~name:"fresh"
    ~last_turn_ts:(now -. hour_seconds)
    ~autonomous_at:(iso_ago hour_seconds)
    ();
  seed_keeper
    config
    ~name:"stale"
    ~last_turn_ts:(now -. hour_seconds)
    ~autonomous_at:(iso_ago ((recent_window_hours +. 2.0) *. hour_seconds))
    ();
  let payload = Feature_proof.json ~config ~now () in
  let feature = feature_by_id payload "autonomous_tool_use" in
  check
    (list string)
    "a keeper still turning but not acting autonomously is not observed"
    [ "fresh" ]
    (keeper_names feature "observed_keepers");
  check
    (list string)
    "it is reported missing rather than dropped"
    [ "stale" ]
    (keeper_names feature "missing_keepers")
;;

let test_stopped_keeper_fails_board_reactive_autonomy () =
  with_workspace
  @@ fun config ->
  seed_keeper
    config
    ~name:"fresh"
    ~last_turn_ts:(now -. hour_seconds)
    ~autonomous_at:(iso_ago hour_seconds)
    ();
  seed_keeper
    config
    ~name:"stopped"
    ~last_turn_ts:(now -. ((recent_window_hours +. 2.0) *. hour_seconds))
    ~autonomous_at:(iso_ago hour_seconds)
    ();
  let payload = Feature_proof.json ~config ~now () in
  let feature = feature_by_id payload "board_reactive_autonomy" in
  check
    (list string)
    "a stopped keeper does not carry the board-reactive claim"
    [ "fresh" ]
    (keeper_names feature "observed_keepers");
  check
    string
    "a partially stopped fleet does not pass"
    "warn"
    (U.member "status" feature |> U.to_string)
;;

(* A keeper whose record will not open did not fail to exercise the feature --
   it failed to be read. Reporting it under both readings puts one name in two
   lists that mean opposite things, and every surface drawing the report shows
   it twice, once as a keeper to go chase and once as a record to go fix. *)
let corrupt_keeper_record config name =
  let path = Masc.Keeper_types_profile.keeper_meta_path config name in
  let out = open_out path in
  output_string out "{ this is not a keeper record";
  close_out out
;;

let read_error_keepers feature =
  feature
  |> U.member "keeper_evidence"
  |> U.member "read_errors"
  |> U.to_list
  |> List.map (fun entry -> U.member "keeper" entry |> U.to_string)
  |> List.sort compare
;;

let test_unreadable_keeper_is_not_reported_as_missing () =
  with_workspace
  @@ fun config ->
  seed_keeper config ~name:"alive" ~last_turn_ts:(now -. hour_seconds) ();
  seed_keeper config ~name:"broken" ~last_turn_ts:(now -. hour_seconds) ();
  corrupt_keeper_record config "broken";
  let payload = Feature_proof.json ~config ~now () in
  let feature = feature_by_id payload "runtime_liveness" in
  check
    (list string)
    "the readable keeper is observed"
    [ "alive" ]
    (keeper_names feature "observed_keepers");
  check
    (list string)
    "the unreadable one is not blamed for the feature"
    []
    (keeper_names feature "missing_keepers");
  check
    (list string)
    "it is reported as a record that would not open"
    [ "broken" ]
    (read_error_keepers feature)
;;

(* Setting the unreadable keeper aside must not promote the fleet. Nothing is
   known about that keeper, and unknown does not become proven by being moved
   out of the missing list. *)
let test_unreadable_keeper_still_blocks_pass () =
  with_workspace
  @@ fun config ->
  seed_keeper config ~name:"alive" ~last_turn_ts:(now -. hour_seconds) ();
  seed_keeper config ~name:"broken" ~last_turn_ts:(now -. hour_seconds) ();
  corrupt_keeper_record config "broken";
  let payload = Feature_proof.json ~config ~now () in
  let feature = feature_by_id payload "runtime_liveness" in
  check
    string
    "a fleet with an unreadable record is not proven"
    "warn"
    (U.member "status" feature |> U.to_string)
;;

(* [scheduled_proactive_autonomy] counted its read errors over the keepers it
   had already filtered to proactive-enabled, which a keeper with no readable
   meta can never reach. The field could only ever be empty, which reads as
   "every record opened". *)
let test_scheduled_proactive_reports_unreadable_records () =
  with_workspace
  @@ fun config ->
  seed_keeper config ~name:"alive" ~last_turn_ts:(now -. hour_seconds) ();
  seed_keeper config ~name:"broken" ~last_turn_ts:(now -. hour_seconds) ();
  corrupt_keeper_record config "broken";
  let payload = Feature_proof.json ~config ~now () in
  let feature = feature_by_id payload "scheduled_proactive_autonomy" in
  check
    (list string)
    "the unreadable record is named here too"
    [ "broken" ]
    (read_error_keepers feature);
  check
    bool
    "and it keeps the feature off pass"
    false
    (U.member "status" feature |> U.to_string = "pass")
;;

(* The summary used to be recovered by re-reading the status string out of the
   payload each feature had just written, with anything unrecognised counted as
   a failure. The status is now carried as a value, so this pins the
   relationship that round-trip was maintaining: what the summary counts and
   what each feature publishes are the same statuses. *)
let test_summary_counts_agree_with_published_feature_statuses () =
  with_workspace
  @@ fun config ->
  seed_keeper config ~name:"live" ~last_turn_ts:(now -. hour_seconds)
    ~autonomous_at:(iso_ago hour_seconds) ();
  seed_keeper config ~name:"stopped" ~last_turn_ts:(now -. (72.0 *. hour_seconds)) ();
  append_turn_exchange config "live" (now -. (25.0 *. hour_seconds));
  append_turn_exchange config "live" now;
  let payload = Feature_proof.json ~config ~now () in
  let published =
    payload
    |> U.member "features"
    |> U.to_list
    |> List.map (fun feature -> U.member "status" feature |> U.to_string)
  in
  let count status = List.length (List.filter (String.equal status) published) in
  let summary = U.member "summary" payload in
  check int "feature_count counts the published features"
    (List.length published) U.(member "feature_count" summary |> to_int);
  check int "pass_count counts the features that published pass"
    (count "pass") U.(member "pass_count" summary |> to_int);
  check int "warn_count counts the features that published warn"
    (count "warn") U.(member "warn_count" summary |> to_int);
  check int "fail_count counts the features that published fail"
    (count "fail") U.(member "fail_count" summary |> to_int);
  let worst =
    if count "fail" > 0 then "fail" else if count "warn" > 0 then "warn" else "pass"
  in
  check string "the report status is the worst status any feature published"
    worst U.(member "status" payload |> to_string);
  (* A mix, so the assertions above are not all comparing zero to zero. *)
  check bool "the fixture produces more than one distinct feature status" true
    (List.length (List.sort_uniq String.compare published) > 1)
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
    ; ( "unreadable_is_not_missing"
      , [ test_case
            "an unreadable record is not a missing keeper"
            `Quick
            test_unreadable_keeper_is_not_reported_as_missing
        ; test_case
            "and it still keeps the feature off pass"
            `Quick
            test_unreadable_keeper_still_blocks_pass
        ; test_case
            "scheduled proactive reports it too"
            `Quick
            test_scheduled_proactive_reports_unreadable_records
        ] )
    ; ( "counter_features_are_dated"
      , [ test_case
            "stale autonomous action fails autonomous_tool_use"
            `Quick
            test_stale_keeper_fails_autonomous_tool_use
        ; test_case
            "stopped keeper fails board_reactive_autonomy"
            `Quick
            test_stopped_keeper_fails_board_reactive_autonomy
        ] )
    ; ( "summary_projection"
      , [ test_case
            "summary counts agree with the published feature statuses"
            `Quick
            test_summary_counts_agree_with_published_feature_statuses
        ] )
    ]
;;
