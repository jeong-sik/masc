let () = Candle_status.install_appraiser_check (fun () -> Ok ())

(** The Candle Snapshot step (RFC-goal-candle-ledger 3.2, step 1): what is
    written to the ledger when the verifier's passing result is about to be
    committed, and when nothing is. *)

open Alcotest
open Masc

(* Helper mode. A test that needs another process to hold the ledger's lock starts
   this same executable again with this variable set. That copy takes the lock,
   says so, and holds it until its stdin closes. *)
let lock_holder_variable = "CANDLE_SNAPSHOT_TEST_HOLD_LOCK"

let () =
  match Sys.getenv_opt lock_holder_variable with
  | None -> ()
  | Some lock_path ->
    let fd = Unix.openfile lock_path [ Unix.O_RDWR ] 0 in
    Unix.lockf fd Unix.F_LOCK 0;
    print_string "locked\n";
    flush stdout;
    (match input_line stdin with
     | (_ : string) -> ()
     | exception End_of_file -> ());
    exit 0
;;

(* {1 Fixtures}

   Everything that names a real Goal, verdict or workspace type is here. *)

let make_goal ?(created_at = "2026-09-20T01:00:00Z") ?(due_date = Some "2026-09-26") ()
  : Goal_store.goal
  =
  { Goal_store.id = "goal-1"
  ; criterion_revision = "rev-1"
  ; title = "Ship the ledger"
  ; metric = Some "tests"
  ; target_value = Some "10"
  ; due_date
  ; priority = 3
  ; phase = Goal_phase.Verifying
  ; last_review_note = None
  ; last_review_at = None
  ; created_at
  ; updated_at = created_at
  }
;;

let make_verdict ?(recorded_at = "2026-09-28T06:32:00Z") () : Goal_verification.verdict =
  { Goal_verification.outcome = Goal_verification.Proven
  ; request_id = "req-1"
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

let write_links config links = Workspace_goal_index.write_goal_task_links config links
let links_path config = Workspace_goal_index.goal_task_links_path config
let base_path_of (config : Workspace.config) = config.base_path

let make_workspace dir =
  let config = Workspace.default_config dir in
  ignore (Workspace.init config ~agent_name:(Some "planner"));
  config
;;

(* {1 Helpers} *)

let temp_dir () =
  let path = Filename.temp_file "candle_snapshot_" "" in
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
  let path = Config_dir_resolver.candle_toml_path_for_base_path ~base_path:(base_path_of config) in
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
share_rounding = "largest_remainder"
remainder_tie_break = "name_ascending"
deduction_rounding = "down"
[payout.grade_criteria]
trivial = "Minor adjustment"
small = "Bounded change"
medium = "Connected feature"
large = "Cross-feature work"
epic = "System outcome"
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

let record ?goal ?verdict config =
  let goal = Option.value goal ~default:(make_goal ()) in
  let verdict = Option.value verdict ~default:(make_verdict ()) in
  Candle_snapshot.record ~now:(fun () -> clock) config goal verdict
;;

let is_ok label = function
  | Ok () -> ()
  | Error detail -> failf "%s: %s" label detail
;;

let is_refused label = function
  | Ok () -> failf "%s: expected a refusal" label
  | Error detail ->
    check bool (label ^ ": says where it came from") true
      (String_util.contains_substring detail "candle snapshot")
;;

let no_ledger label config =
  check bool (label ^ ": no ledger file") false (Sys.file_exists (ledger_path config))
;;

let goal_ids events =
  List.filter_map
    (fun (event : Candle_event.t) ->
       match event.body with
       | Candle_event.Snapshot { goal_id; _ }
       | Candle_event.Payout_owed { goal_id; _ }
       | Candle_event.Candidates { goal_id; _ }
       | Candle_event.Unattributed { goal_id; _ }
       | Candle_event.Payout_failed { goal_id; _ } -> Some goal_id
       | Candle_event.Paid p -> Some p.identity.goal_id
       | Candle_event.Half_life_set _ -> None
       | Candle_event.Equipped _ | Candle_event.Purchased _ -> Alcotest.fail "a purchase has no Goal identity")
    events
;;

(* Starts the lock holder and returns the function that lets it go. The lock file
   is made first because the holder opens it without creating it. *)
let start_lock_holder config =
  let lock_path = Fs_compat.private_jsonl_lock_path (ledger_path config) in
  mkdir_p (Filename.dirname lock_path);
  Out_channel.with_open_gen [ Open_creat; Open_append ] 0o600 lock_path (fun _ -> ());
  let stdin_read, stdin_write = Unix.pipe ~cloexec:true () in
  let stdout_read, stdout_write = Unix.pipe ~cloexec:true () in
  let environment =
    Array.append [| lock_holder_variable ^ "=" ^ lock_path |] (Unix.environment ())
  in
  let pid =
    Unix.create_process_env
      Sys.executable_name
      [| Sys.executable_name |]
      environment
      stdin_read
      stdout_write
      Unix.stderr
  in
  Unix.close stdin_read;
  Unix.close stdout_write;
  let from_holder = Unix.in_channel_of_descr stdout_read in
  (match input_line from_holder with
   | "locked" -> ()
   | other -> failf "the lock holder said %S" other);
  let rec wait_for_exit () =
    match Unix.waitpid [] pid with
    | (_ : int * Unix.process_status) -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_for_exit ()
  in
  fun () ->
    Unix.close stdin_write;
    wait_for_exit ();
    close_in_noerr from_holder
;;

(* {1 Tests} *)

let test_no_candle_toml_writes_nothing () =
  with_workspace
  @@ fun config ->
  is_ok "record" (record config);
  no_ledger "off" config
;;

let test_a_candle_toml_that_does_not_read_writes_nothing_and_does_not_refuse () =
  List.iter (fun text ->
    with_workspace @@ fun config ->
    write_file (candle_toml config) text;
    is_ok "record" (record config);
    no_ledger "disabled" config)
    [""; "[payout]\nweight_max = 10\n"; "half_life_hours = 72\n"]
;;

let test_the_snapshot_holds_what_the_goal_held () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  write_links config [ "goal-1", [ "task-1"; "task-2" ]; "goal-2", [ "task-9" ] ];
  is_ok "record" (record config);
  match ledger_events config with
  | [ { Candle_event.at; body = Candle_event.Snapshot s } ] ->
    let time text = Result.get_ok (Candle_time.of_rfc3339 text) in
    check string "goal" "goal-1" s.goal_id;
    check string "request" "req-1" s.request_id;
    check string "verifier run" "run-1" s.verification_run_id;
    check string "criterion revision" "rev-1" s.criterion_revision;
    check bool "passed_at is the verdict's recorded_at" true
      (Candle_time.equal s.passed_at (time "2026-09-28T06:32:00Z"));
    check bool "goal_created_at is the Goal's created_at" true
      (Candle_time.equal s.goal_created_at (time "2026-09-20T01:00:00Z"));
    check bool "at is the clock" true
      (Candle_time.equal at (Candle_time.of_ptime (Option.get (Ptime.of_float_s clock))));
    check (option string) "due date as the Goal held it" (Some "2026-09-26") s.due_date;
    check string "title" "Ship the ledger" s.title;
    check (option string) "metric" (Some "tests") s.metric;
    check (option string) "target" (Some "10") s.target_value;
    check (list string) "only this Goal's Tasks" [ "task-1"; "task-2" ] s.linked_task_ids
  | events -> failf "expected one Snapshot, got %d rows" (List.length events)
;;

let test_a_due_date_that_is_not_a_date_is_kept_as_written () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  is_ok "record" (record ~goal:(make_goal ~due_date:(Some "TBD") ()) config);
  match ledger_events config with
  | [ { Candle_event.body = Candle_event.Snapshot s; _ } ] ->
    check (option string) "kept" (Some "TBD") s.due_date;
    check (list string) "a Goal with no links has no linked Tasks" [] s.linked_task_ids
  | events -> failf "expected one Snapshot, got %d rows" (List.length events)
;;

let test_links_that_cannot_be_read_refuse_the_step () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  write_links config [ "goal-1", [ "task-1" ] ];
  write_file (links_path config) "not json";
  is_refused "unreadable links" (record config);
  no_ledger "refused" config
;;

let test_a_time_the_ledger_cannot_hold_refuses_the_step () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  is_refused "goal created_at" (record ~goal:(make_goal ~created_at:"yesterday" ()) config);
  is_refused
    "verdict recorded_at"
    (record ~verdict:(make_verdict ~recorded_at:"2026-09-28 06:32:00" ()) config);
  no_ledger "refused" config
;;

let earlier_snapshot : Candle_event.t =
  let time text = Result.get_ok (Candle_time.of_rfc3339 text) in
  { at = time "2026-09-01T00:00:00Z"
  ; body =
      Candle_event.Snapshot
        { goal_id = "goal-earlier"
        ; request_id = "req-0"
        ; verification_run_id = "run-0"
        ; criterion_revision = "rev-0"
        ; passed_at = time "2026-08-31T00:00:00Z"
        ; goal_created_at = time "2026-08-01T00:00:00Z"
        ; due_date = None
        ; title = ""
        ; metric = None
        ; target_value = None
        ; linked_task_ids = []
        }
  }
;;

(* A crash in the middle of an append leaves a row without its newline. The first
   Snapshot after a start cuts it, and the new row follows the last whole one. *)
let test_a_torn_tail_is_cut_the_first_time_and_appended_after () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  (match Candle_ledger.update ~base_path:(base_path_of config) (fun _ -> Ok ([ earlier_snapshot ], ())) with
   | Ok () -> ()
   | Error error -> failf "%s" (Candle_ledger.update_error_to_string Fun.id error));
  write_file
    (ledger_path config)
    (In_channel.with_open_bin (ledger_path config) In_channel.input_all
     ^ {|{"kind":"snapshot","at":"2026|});
  is_ok "record" (record config);
  check
    (list string)
    "the row before the tear and the new one"
    [ "goal-earlier"; "goal-1" ]
    (goal_ids (ledger_events config))
;;

let test_an_unreadable_ledger_disables_candle_instead_of_refusing () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  write_file (ledger_path config) "not a row\n";
  is_ok "the transition is not blocked" (record config);
  check string "the ledger is left as it was" "not a row\n"
    (In_channel.with_open_bin (ledger_path config) In_channel.input_all);
  (* The answer is not remembered: once the operator repairs the ledger the
     next Snapshot is written, with no restart. *)
  write_file (ledger_path config) "";
  is_ok "record after the repair" (record config);
  check (list string) "written" [ "goal-1" ] (goal_ids (ledger_events config))
;;

(* The two ways a ledger fails to read give the same answer. A row that does not
   parse is one (above). A ledger that cannot be opened at all is the other; here
   its path is a directory. *)
let test_a_ledger_that_cannot_be_opened_disables_candle_instead_of_refusing () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  mkdir_p (ledger_path config);
  is_ok "the transition is not blocked" (record config);
  check
    bool
    "candle is disabled"
    true
    (match Candle_status.current ~base_path:(base_path_of config) with
     | Candle_config.Disabled _ -> true
     | Candle_config.Off | Candle_config.Enabled _ -> false);
  check bool "the directory was left alone" true (Sys.is_directory (ledger_path config));
  Unix.rmdir (ledger_path config);
  is_ok "record after the repair" (record config);
  check (list string) "written" [ "goal-1" ] (goal_ids (ledger_events config))
;;

let test_a_ledger_that_fails_after_recovery_refuses_the_step () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  is_ok "first snapshot" (record config);
  Sys.remove (ledger_path config);
  Unix.mkdir (ledger_path config) 0o755;
  is_refused "ledger path is a directory" (record config)
;;

(* Another process is appending to the ledger when a Goal passes, and this process
   has not recovered the ledger yet. Candle is not disabled for that. Disabling it
   would let the Goal pass with no Snapshot, and no later step can add one. The
   step is refused instead, and it writes once the lock is free. *)
let test_a_pass_while_another_process_holds_the_ledger_lock_is_refused () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  let release = start_lock_holder config in
  let released = ref false in
  let release_once () =
    if not !released
    then (
      released := true;
      release ())
  in
  Fun.protect
    ~finally:release_once
    (fun () ->
       check
         bool
         "candle stays enabled"
         true
         (match Candle_status.current ~base_path:(base_path_of config) with Candle_config.Enabled _ -> true | Off | Disabled _ -> false);
       (match record config with
        | Ok () -> fail "a pass went through a ledger another process is writing"
        | Error detail ->
          check bool "says where it came from" true
            (String_util.contains_substring detail "candle snapshot");
          check bool "says the ledger is locked" true
            (String_util.contains_substring detail "locked by another process"));
       no_ledger "refused" config;
       release_once ();
       is_ok "record once the lock is free" (record config);
       check (list string) "written" [ "goal-1" ] (goal_ids (ledger_events config)))
;;

(* The lock does not count as a recovery. A pass refused while another process
   holds the lock leaves the tail alone and remembers nothing, so the first pass
   after the lock is free cuts the tail and writes after the last whole row. *)
let test_a_torn_tail_is_cut_after_a_pass_was_refused_for_the_lock () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  (match
     Candle_ledger.update ~base_path:(base_path_of config) (fun _ ->
       Ok ([ earlier_snapshot ], ()))
   with
   | Ok () -> ()
   | Error error -> failf "%s" (Candle_ledger.update_error_to_string Fun.id error));
  write_file
    (ledger_path config)
    (In_channel.with_open_bin (ledger_path config) In_channel.input_all
     ^ {|{"kind":"snapshot","at":"2026|});
  let release = start_lock_holder config in
  let released = ref false in
  let release_once () =
    if not !released
    then (
      released := true;
      release ())
  in
  Fun.protect
    ~finally:release_once
    (fun () ->
       is_refused "the lock is held" (record config);
       release_once ();
       is_ok "the lock is free" (record config);
       check
         (list string)
         "the row before the tear and the new one"
         [ "goal-earlier"; "goal-1" ]
         (goal_ids (ledger_events config)))
;;

(* A clock that gives no time is an error, not a time to write. *)
let test_a_clock_that_gives_no_time_refuses_the_step () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  is_refused
    "no time"
    (Candle_snapshot.record ~now:(fun () -> nan) config (make_goal ()) (make_verdict ()));
  no_ledger "refused" config
;;

(* #40054: the appraiser lane settles money; it does not gate the pass record.
   A pass records its Snapshot while the lane is unavailable. Recording sees
   Enabled; only appraiser-gated readers (settlement,
   [Candle_status.current]) see Disabled. *)
let test_a_pass_records_its_snapshot_while_the_appraiser_is_unavailable () =
  with_workspace
  @@ fun config ->
  enable_candle config;
  Fun.protect
    ~finally:(fun () -> Candle_status.install_appraiser_check (fun () -> Ok ()))
    (fun () ->
      Candle_status.install_appraiser_check (fun () -> Error "publication unavailable");
      check
        bool
        "settlement view is disabled"
        true
        (match Candle_status.current ~base_path:(base_path_of config) with
         | Candle_config.Disabled _ -> true
         | Candle_config.Off | Candle_config.Enabled _ -> false);
      is_ok "snapshot records" (record config);
      (match ledger_events config with
       | [ { Candle_event.body = Candle_event.Snapshot snapshot; _ } ] ->
         check string "goal" "goal-1" snapshot.goal_id
       | events -> failf "expected one Snapshot, got %d rows" (List.length events)))
;;

let () =
  run
    "candle_snapshot"
    [ ( "when candle is not on"
      , [ test_case "no candle.toml writes nothing" `Quick test_no_candle_toml_writes_nothing
        ; test_case
            "a candle.toml that does not read writes nothing and does not refuse"
            `Quick
            test_a_candle_toml_that_does_not_read_writes_nothing_and_does_not_refuse
        ; test_case
            "an unreadable ledger disables candle instead of refusing"
            `Quick
            test_an_unreadable_ledger_disables_candle_instead_of_refusing
        ; test_case
            "a ledger that cannot be opened disables candle instead of refusing"
            `Quick
            test_a_ledger_that_cannot_be_opened_disables_candle_instead_of_refusing
        ] )
    ; ( "when candle is on"
      , [ test_case
            "the snapshot holds what the Goal held"
            `Quick
            test_the_snapshot_holds_what_the_goal_held
        ; test_case
            "a due date that is not a date is kept as written"
            `Quick
            test_a_due_date_that_is_not_a_date_is_kept_as_written
        ; test_case
            "links that cannot be read refuse the step"
            `Quick
            test_links_that_cannot_be_read_refuse_the_step
        ; test_case
            "a time the ledger cannot hold refuses the step"
            `Quick
            test_a_time_the_ledger_cannot_hold_refuses_the_step
        ; test_case
            "a torn tail is cut the first time and appended after"
            `Quick
            test_a_torn_tail_is_cut_the_first_time_and_appended_after
        ; test_case
            "a ledger that fails after recovery refuses the step"
            `Quick
            test_a_ledger_that_fails_after_recovery_refuses_the_step
        ; test_case
            "a pass while another process holds the ledger lock is refused"
            `Quick
            test_a_pass_while_another_process_holds_the_ledger_lock_is_refused
        ; test_case
            "a torn tail is cut after a pass was refused for the lock"
            `Quick
            test_a_torn_tail_is_cut_after_a_pass_was_refused_for_the_lock
        ; test_case
            "a clock that gives no time refuses the step"
            `Quick
            test_a_clock_that_gives_no_time_refuses_the_step
        ; test_case
            "a pass records its snapshot while the appraiser is unavailable"
            `Quick
            test_a_pass_records_its_snapshot_while_the_appraiser_is_unavailable
        ] )
    ]
;;
