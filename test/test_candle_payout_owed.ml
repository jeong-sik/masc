let () = Candle_status.install_appraiser_check (fun () -> Ok ())

(** The PayoutOwed step (RFC-goal-candle-ledger 3.2, step 2): what is written to
    the ledger when the operator confirms a pass, and when nothing is. *)

open Alcotest
open Masc

(* {1 Fixtures}

   Everything that names a real Goal, verdict or workspace type is here. *)

let make_goal () : Goal_store.goal =
  { Goal_store.id = "goal-1"
  ; criterion_revision = "rev-1"
  ; title = "Ship the ledger"
  ; metric = Some "tests"
  ; target_value = Some "10"
  ; due_date = None
  ; priority = 3
  ; phase = Goal_phase.Awaiting_confirmation
  ; last_review_note = None
  ; last_review_at = None
  ; created_at = "2026-09-20T01:00:00Z"
  ; updated_at = "2026-09-20T01:00:00Z"
  }
;;

let make_verdict ?(request_id = "req-1") ?(recorded_at = "2026-09-28T06:32:00Z") ()
  : Goal_verification.verdict
  =
  { Goal_verification.outcome = Goal_verification.Proven
  ; request_id
  ; criterion =
      Goal_store.Criterion
        { revision = "rev-1"
        ; title = "Ship the ledger"
        ; metric = Some "tests"
        ; target_value = Some "10"
        }
  ; verification_run_id = "run-1"
  ; authority = Masc_domain.System_llm_agent { agent_run_id = "test-verifier" }
  ; evidence = "artifact:proof"
  ; recorded_at
  }
;;

let make_confirmation ?(confirmed_at = "2026-09-29T05:00:00Z") () : Goal_verification.confirmation =
  { Goal_verification.operator_id = "operator-a"; confirmed_at }
;;

let base_path_of (config : Workspace.config) = config.base_path

let make_workspace dir =
  let config = Workspace.default_config dir in
  ignore (Workspace.init config ~agent_name:(Some "planner"));
  config
;;

let temp_dir () =
  let path = Filename.temp_file "candle_payout_owed_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun entry -> rm_rf (Filename.concat path entry)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f (make_workspace dir))
;;

let rec mkdir_p dir =
  if not (Sys.file_exists dir)
  then (
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755)
;;

let write_file path text =
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc text)
;;

(* The tests write candle.toml, so they stop if the resolver points anywhere but
   the temporary workspace. *)
let candle_toml config =
  let path =
    Config_dir_resolver.candle_toml_path_for_base_path ~base_path:(base_path_of config)
  in
  if not (String.starts_with ~prefix:(base_path_of config) path)
  then failf "the candle.toml path %s is outside the test workspace" path;
  path
;;

let ledger_path config = Candle_ledger.path ~base_path:(base_path_of config)
let enable_candle config = write_file (candle_toml config) {|half_life = "off"
[payout]
weight_max = 10
deduction_rate = 10
deduction_floor = 200
[payout.grades_milli]
trivial = 1000
small = 2000
medium = 3000
large = 4000
epic = 5000
|}
let clock = 1_790_000_000.

let ledger_events config =
  match Candle_ledger.read ~base_path:(base_path_of config) with
  | Ok view -> Candle_ledger.events view
  | Error error -> failf "%s" (Candle_ledger.read_error_to_string error)
;;

let kinds config =
  List.map (fun (event : Candle_event.t) -> Candle_event.kind event.body) (ledger_events config)
;;

(* The Snapshot the verifier would have left when the Goal passed. *)
let pass ?verdict config =
  let verdict = Option.value verdict ~default:(make_verdict ()) in
  match Candle_snapshot.record ~now:(fun () -> clock) config (make_goal ()) verdict with
  | Ok () -> ()
  | Error detail -> failf "snapshot: %s" detail
;;

let confirm ?verdict ?confirmation config =
  let verdict = Option.value verdict ~default:(make_verdict ()) in
  let confirmation = Option.value confirmation ~default:(make_confirmation ()) in
  Candle_payout_owed.record ~now:(fun () -> clock) config (make_goal ()) verdict confirmation
;;

let is_ok label = function
  | Ok () -> ()
  | Error detail -> failf "%s: %s" label detail
;;

let is_refused label = function
  | Ok () -> failf "%s: expected a refusal" label
  | Error detail ->
    check bool (label ^ ": says where it came from") true
      (String_util.contains_substring detail "candle payout owed")
;;

let no_ledger label config =
  check bool (label ^ ": no ledger file") false (Sys.file_exists (ledger_path config))
;;

(* {1 Tests} *)

let test_no_candle_toml_writes_nothing () =
  with_workspace
  @@ fun config ->
  is_ok "confirm" (confirm config);
  no_ledger "off" config
;;

let test_a_candle_toml_that_does_not_read_writes_nothing_and_does_not_refuse () =
  with_workspace
  @@ fun config ->
  write_file (candle_toml config) "half_life_hours = 72\n";
  is_ok "confirm" (confirm config);
  no_ledger "disabled" config
;;

(* Candle was on when the Goal passed, so there is a Snapshot, and it is not on
   when the operator confirms. Off and disabled write nothing, and the
   confirmation still goes through, so the pass is not paid. RFC-goal-candle-ledger
   6 says a confirmation can be made again with Candle off; this is what that
   costs. *)
let test_candle_turned_off_between_the_pass_and_the_confirmation_owes_nothing () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  pass config;
  Sys.remove (candle_toml config);
  is_ok "confirm with no candle.toml" (confirm config);
  check (list string) "only the Snapshot" [ "snapshot" ] (kinds config)
;;

let test_candle_disabled_between_the_pass_and_the_confirmation_owes_nothing () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  pass config;
  write_file (candle_toml config) "half_life_hours = 72\n";
  is_ok "confirm with a candle.toml that does not read" (confirm config);
  check (list string) "only the Snapshot" [ "snapshot" ] (kinds config)
;;

let test_a_confirmed_pass_with_a_snapshot_is_owed () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  pass config;
  is_ok "confirm" (confirm config);
  check (list string) "the Snapshot, then the PayoutOwed" [ "snapshot"; "payout_owed" ] (kinds config);
  match List.rev (ledger_events config) with
  | { Candle_event.at; body = Candle_event.Payout_owed owed } :: _ ->
    let time text = Result.get_ok (Candle_time.of_rfc3339 text) in
    check string "goal" "goal-1" owed.goal_id;
    check string "request" "req-1" owed.request_id;
    check string "verifier run" "run-1" owed.verification_run_id;
    check bool "passed_at is the pass" true (Candle_time.equal owed.passed_at (time "2026-09-28T06:32:00Z"));
    check
      bool
      "confirmed_at is the operator's"
      true
      (Candle_time.equal owed.confirmed_at (time "2026-09-29T05:00:00Z"));
    check
      bool
      "at is the clock"
      true
      (Candle_time.equal at (Candle_time.of_ptime (Option.get (Ptime.of_float_s clock))))
  | _ -> fail "expected a PayoutOwed last"
;;

let test_confirming_again_writes_no_second_row () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  pass config;
  is_ok "first" (confirm config);
  is_ok "again" (confirm config);
  is_ok "again with a later confirmation time" (confirm ~confirmation:(make_confirmation ~confirmed_at:"2026-09-30T05:00:00Z" ()) config);
  check (list string) "one PayoutOwed" [ "snapshot"; "payout_owed" ] (kinds config)
;;

let test_a_pass_without_a_snapshot_owes_nothing () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  is_ok "confirm" (confirm config);
  no_ledger "nothing to pay for" config
;;

let test_only_the_pass_the_snapshot_names_is_owed () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  pass config;
  is_ok "another request" (confirm ~verdict:(make_verdict ~request_id:"req-2" ()) config);
  is_ok
    "the same request at another time"
    (confirm ~verdict:(make_verdict ~recorded_at:"2026-09-28T06:32:01Z" ()) config);
  check (list string) "still only the Snapshot" [ "snapshot" ] (kinds config)
;;

let test_a_ledger_that_fails_after_recovery_refuses_the_step () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  pass config;
  Sys.remove (ledger_path config);
  Unix.mkdir (ledger_path config) 0o755;
  is_refused "ledger path is a directory" (confirm config)
;;

let test_a_confirmation_time_the_ledger_cannot_hold_refuses_the_step () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  pass config;
  is_refused
    "confirmed_at"
    (confirm ~confirmation:(make_confirmation ~confirmed_at:"yesterday" ()) config);
  check (list string) "nothing was written" [ "snapshot" ] (kinds config)
;;

(* Without a Snapshot nothing is written, so the confirmation's time is never read. *)
let test_a_confirmation_time_is_not_read_when_nothing_is_owed () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  is_ok
    "no Snapshot"
    (confirm ~confirmation:(make_confirmation ~confirmed_at:"yesterday" ()) config);
  no_ledger "nothing to pay for" config
;;

let () =
  run
    "candle_payout_owed"
    [ ( "when candle is not on"
      , [ test_case "no candle.toml writes nothing" `Quick test_no_candle_toml_writes_nothing
        ; test_case
            "a candle.toml that does not read writes nothing and does not refuse"
            `Quick
            test_a_candle_toml_that_does_not_read_writes_nothing_and_does_not_refuse
        ; test_case
            "candle turned off between the pass and the confirmation owes nothing"
            `Quick
            test_candle_turned_off_between_the_pass_and_the_confirmation_owes_nothing
        ; test_case
            "candle disabled between the pass and the confirmation owes nothing"
            `Quick
            test_candle_disabled_between_the_pass_and_the_confirmation_owes_nothing
        ] )
    ; ( "when candle is on"
      , [ test_case
            "a confirmed pass with a snapshot is owed"
            `Quick
            test_a_confirmed_pass_with_a_snapshot_is_owed
        ; test_case
            "confirming again writes no second row"
            `Quick
            test_confirming_again_writes_no_second_row
        ; test_case
            "a pass without a snapshot owes nothing"
            `Quick
            test_a_pass_without_a_snapshot_owes_nothing
        ; test_case
            "only the pass the snapshot names is owed"
            `Quick
            test_only_the_pass_the_snapshot_names_is_owed
        ; test_case
            "a ledger that fails after recovery refuses the step"
            `Quick
            test_a_ledger_that_fails_after_recovery_refuses_the_step
        ; test_case
            "a confirmation time the ledger cannot hold refuses the step"
            `Quick
            test_a_confirmation_time_the_ledger_cannot_hold_refuses_the_step
        ; test_case
            "a confirmation time is not read when nothing is owed"
            `Quick
            test_a_confirmation_time_is_not_read_when_nothing_is_owed
        ] )
    ]
;;
