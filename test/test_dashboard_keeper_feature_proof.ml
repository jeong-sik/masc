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

let duration_tier feature id =
  feature
  |> U.member "duration_tiers"
  |> U.to_list
  |> List.find_opt (fun tier -> U.member "id" tier |> U.to_string = id)
  |> function
  | Some tier -> tier
  | None -> failf "duration tier %s absent from persistence proof" id
;;

let append_turn_exchange config keeper_name ts =
  Masc.Keeper_types_support.append_jsonl_line
    (Masc.Keeper_types_support.keeper_decision_log_path config keeper_name)
    (`Assoc [ "channel", `String "turn"; "ts_unix", `Float ts ])
;;

(* One decision-log row wider than the reader's segment head budget
   (Dashboard_keeper_decision_log_proof.decision_head_max_bytes, 512 KB). The
   head scan ends inside this row, so every turn row appended after it sits in
   an unscanned suffix and the earliest turn is never seen. *)
let head_budget_overflow_bytes = 600 * 1024

let append_unreadable_head_row config keeper_name ts =
  Masc.Keeper_types_support.append_jsonl_line
    (Masc.Keeper_types_support.keeper_decision_log_path config keeper_name)
    (`Assoc
        [ "channel", `String "heartbeat"
        ; "ts_unix", `Float ts
        ; "detail", `String (String.make head_budget_overflow_bytes 'x')
        ])
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

let test_persistence_duration_tiers_use_durable_turn_history () =
  with_workspace
  @@ fun config ->
  seed_keeper config ~name:"four-hours" ~last_turn_ts:(now -. hour_seconds) ();
  seed_keeper config ~name:"twenty-four-hours" ~last_turn_ts:(now -. hour_seconds) ();
  append_turn_exchange config "four-hours" (now -. (5.0 *. hour_seconds));
  append_turn_exchange config "four-hours" (now -. (0.5 *. hour_seconds));
  append_turn_exchange config "twenty-four-hours" (now -. (24.0 *. hour_seconds));
  append_turn_exchange config "twenty-four-hours" now;
  let feature =
    Feature_proof.json ~config ~now ()
    |> fun payload -> feature_by_id payload "persistent_24h_turn_exchange"
  in
  List.iter
    (fun id ->
      let tier = duration_tier feature id in
      check
        string
        (id ^ " tier names its evidence semantics")
        "durable_turn_span"
        U.(member "evidence_kind" tier |> to_string);
      check string (id ^ " tier passes for both keepers") "pass" U.(member "status" tier |> to_string);
      check int (id ^ " tier observes both keepers") 2 U.(member "observed_count" tier |> to_int))
    [ "1h"; "2h"; "4h" ];
  let tier_24h = duration_tier feature "24h" in
  check string "24h tier stays partial" "warn" U.(member "status" tier_24h |> to_string);
  check
    (list string)
    "24h tier names only the keeper with sufficient durable history"
    [ "twenty-four-hours" ]
    (tier_24h |> U.member "observed_keepers" |> U.to_list |> List.map U.to_string)
;;

let test_persistence_duration_tiers_reject_future_turns () =
  with_workspace
  @@ fun config ->
  seed_keeper config ~name:"future" ~last_turn_ts:(now -. hour_seconds) ();
  append_turn_exchange config "future" (now -. (25.0 *. hour_seconds));
  append_turn_exchange config "future" (now +. hour_seconds);
  let feature =
    Feature_proof.json ~config ~now ()
    |> fun payload -> feature_by_id payload "persistent_24h_turn_exchange"
  in
  List.iter
    (fun id ->
      let tier = duration_tier feature id in
      check string (id ^ " tier rejects a future latest turn") "fail" U.(member "status" tier |> to_string);
      check int (id ^ " tier observes no keeper with future evidence") 0 U.(member "observed_count" tier |> to_int))
    [ "1h"; "2h"; "4h"; "24h" ]
;;

(* A keeper whose earliest turn row the head scan never reached has not failed
   to persist turns: the reader stopped first. Reporting it beside keepers that
   genuinely have no durable span blames a keeper for a reader budget, and the
   distinction already exists - [first_ts_origin] publishes "scan_exhausted" -
   so the report was discarding an answer it had. *)
let test_unreached_history_is_not_a_missing_keeper () =
  with_workspace
  @@ fun config ->
  seed_keeper config ~name:"readable" ~last_turn_ts:(now -. hour_seconds) ();
  seed_keeper config ~name:"unread" ~last_turn_ts:(now -. hour_seconds) ();
  append_turn_exchange config "readable" (now -. (25.0 *. hour_seconds));
  append_turn_exchange config "readable" now;
  append_unreadable_head_row config "unread" (now -. (30.0 *. hour_seconds));
  append_turn_exchange config "unread" (now -. (25.0 *. hour_seconds));
  append_turn_exchange config "unread" now;
  let feature =
    Feature_proof.json ~config ~now ()
    |> fun payload -> feature_by_id payload "persistent_24h_turn_exchange"
  in
  check
    (list string)
    "the keeper with a readable span is the only one observed"
    [ "readable" ]
    (keeper_names feature "observed_keepers");
  check
    (list string)
    "an unreached history is not blamed for the feature"
    []
    (keeper_names feature "missing_keepers");
  check
    (list string)
    "an unreached history is named as undetermined"
    [ "unread" ]
    (keeper_names feature "undetermined_keepers");
  check string "one proven and one unknown is partial" "warn" U.(member "status" feature |> to_string);
  let tier_24h = duration_tier feature "24h" in
  check int "24h tier counts the unread keeper apart" 1 U.(member "undetermined_count" tier_24h |> to_int);
  check int "24h tier blames nobody" 0 U.(member "missing_count" tier_24h |> to_int)
;;

(* Fail says nobody met the span. With every keeper unread the report does not
   know that, and stating it turns a reader limit into a fleet-wide verdict. *)
let test_unreached_history_alone_does_not_read_as_failure () =
  with_workspace
  @@ fun config ->
  seed_keeper config ~name:"unread" ~last_turn_ts:(now -. hour_seconds) ();
  append_unreadable_head_row config "unread" (now -. (30.0 *. hour_seconds));
  append_turn_exchange config "unread" (now -. (25.0 *. hour_seconds));
  append_turn_exchange config "unread" now;
  let feature =
    Feature_proof.json ~config ~now ()
    |> fun payload -> feature_by_id payload "persistent_24h_turn_exchange"
  in
  check string "an entirely unread fleet is not a failed one" "warn" U.(member "status" feature |> to_string);
  check
    (list string)
    "nothing is observed either"
    []
    (keeper_names feature "observed_keepers");
  check
    (list string)
    "and nothing is called missing"
    []
    (keeper_names feature "missing_keepers")
;;

(* Control: a keeper with no turn rows at all is readable and genuinely has no
   span, so it stays in [missing]. Without this, moving every unproven keeper
   out of [missing] would look like the same change. *)
let test_readable_history_without_turns_is_still_missing () =
  with_workspace
  @@ fun config ->
  seed_keeper config ~name:"silent" ~last_turn_ts:(now -. hour_seconds) ();
  let feature =
    Feature_proof.json ~config ~now ()
    |> fun payload -> feature_by_id payload "persistent_24h_turn_exchange"
  in
  check
    (list string)
    "a readable history with no turns is a missing span"
    [ "silent" ]
    (keeper_names feature "missing_keepers");
  check
    (list string)
    "and is not filed as undetermined"
    []
    (keeper_names feature "undetermined_keepers");
  check string "a keeper that never persisted a turn still fails" "fail" U.(member "status" feature |> to_string)
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
    ; ( "persistence_duration_tiers"
      , [ test_case
            "durable history proves 1h 2h 4h and 24h tiers"
            `Quick
            test_persistence_duration_tiers_use_durable_turn_history
        ; test_case
            "future timestamps cannot prove a duration tier"
            `Quick
            test_persistence_duration_tiers_reject_future_turns
        ] )
    ; ( "unreached_history_is_not_missing"
      , [ test_case
            "an unreached history is undetermined, not missing"
            `Quick
            test_unreached_history_is_not_a_missing_keeper
        ; test_case
            "an entirely unreached fleet is not a failure"
            `Quick
            test_unreached_history_alone_does_not_read_as_failure
        ; test_case
            "control: a readable history without turns stays missing"
            `Quick
            test_readable_history_without_turns_is_still_missing
        ] )
    ]
;;
