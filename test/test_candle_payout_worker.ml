let appraise ~identity:_ _ = Error (Candle_appraisal.Transport_unavailable "fixture stops after durable Candidates")

let () = Candle_status.install_appraiser_check (fun () -> Ok ())

(** The payout worker (RFC-goal-candle-ledger 3.2, step 3): one pass when it
    starts, and one more each time it is woken. It reads the real Task stores, so
    the workspace is initialised the way a server's is. *)

open Alcotest
open Masc

module E = Candle_event

let ok_or_fail = function
  | Ok value -> value
  | Error detail -> failf "%s" detail
;;

let at text = ok_or_fail (Candle_time.of_rfc3339 text)

(* {1 Fixtures} *)

let temp_dir () =
  let path = Filename.temp_file "candle_payout_worker_" "" in
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

let rec mkdir_p dir =
  if not (Sys.file_exists dir)
  then (
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755)
;;

let inside (config : Workspace.config) path =
  if not (String.starts_with ~prefix:config.base_path path)
  then failf "%s is outside the test workspace" path;
  path
;;

let write_backlog (config : Workspace.config) tasks =
  Workspace_backlog.write_backlog
    config
    { Masc_domain.tasks
    ; task_creation_receipts = []; task_deletion_receipts = []
    ; pending_completion_approvals = []; pending_completion_rejections = []; delivered_completion_rejections = []
    ; last_updated = "2026-09-29T00:00:00Z"
    ; version = 1
    }
;;

(* A server's workspace: the Task stores readable, and a Keepers directory. The
   caller removes [config.base_path]. *)
let make_workspace () : Workspace.config =
  let dir = temp_dir () in
  let config = Workspace.default_config dir in
  ignore (Workspace.init config ~agent_name:(Some "planner"));
  write_backlog config [];
  mkdir_p (inside config (Config_dir_resolver.keepers_dir_for_base_path ~base_path:dir));
  config
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = make_workspace () in
  Fun.protect ~finally:(fun () -> rm_rf config.base_path) (fun () -> f env config)
;;

let with_second_workspace f =
  let config = make_workspace () in
  Fun.protect ~finally:(fun () -> rm_rf config.base_path) (fun () -> f config)
;;

let make_task ~id status : Masc_domain.task =
  { Masc_domain.id
  ; title = "A Task"
  ; description = ""
  ; task_status = status
  ; priority = 3
  ; files = []
  ; created_at = "2026-09-01T00:00:00Z"
  ; created_by = None
  ; predecessor_task_id = None
  ; contract = None
  ; handoff_context = None
  ; cycle_count = 0
  ; reclaim_policy = None
  ; execution_links = Masc_domain.no_execution_links
  ; do_not_reclaim_reason = None
  ; skills = []
  }
;;

let done_by assignee completed_at = Masc_domain.Done { assignee; completed_at; notes = None }

(* A Keeper is a valid name with a config file; the file's content is not read
   here. *)
let write_keeper (config : Workspace.config) name =
  let path =
    inside
      config
      (Config_dir_resolver.keeper_toml_path_for_base_path ~base_path:config.base_path name)
  in
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc "")
;;

let enable_candle ?(medium_criteria = "Connected feature") (config : Workspace.config) =
  let path =
    inside config (Config_dir_resolver.candle_toml_path_for_base_path ~base_path:config.base_path)
  in
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc (Printf.sprintf {|half_life = "off"
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
medium = "%s"
large = "Cross-feature work"
epic = "System outcome"
[payout.grades_milli]
trivial = 1000
small = 2000
medium = 3000
large = 4000
epic = 5000
|} medium_criteria))
;;

(* A Goal whose pass the operator confirmed. It was created 2026-09-20, and the
   operator confirmed on 2026-09-29. *)
let seed_payout ?(linked_task_ids = []) (config : Workspace.config) ~goal_id =
  let request_id = "req-" ^ goal_id in
  let verification_run_id = "run-" ^ goal_id in
  let rows : E.t list =
    [ { at = at "2026-09-28T06:32:01Z"
      ; body =
          E.Snapshot
            { goal_id
            ; request_id
            ; verification_run_id
            ; criterion_revision = "rev-1"
            ; passed_at = at "2026-09-28T06:32:00Z"
            ; goal_created_at = at "2026-09-20T01:00:00Z"
            ; due_date = None
            ; title = "Ship the ledger"
            ; metric = None
            ; target_value = None
            ; linked_task_ids
            }
      }
    ; { at = at "2026-09-29T05:00:01Z"
      ; body =
          E.Payout_owed
            { goal_id
            ; request_id
            ; verification_run_id
            ; passed_at = at "2026-09-28T06:32:00Z"
            ; confirmed_at = at "2026-09-29T05:00:00Z"
            }
      }
    ]
  in
  match Candle_ledger.update ~base_path:config.base_path (fun _ -> Ok (rows, ())) with
  | Ok () -> ()
  | Error error -> failf "%s" (Candle_ledger.update_error_to_string Fun.id error)
;;

let kinds (config : Workspace.config) =
  match Candle_ledger.read ~base_path:config.base_path with
  | Ok view ->
    List.map (fun (event : E.t) -> E.kind event.body) (Candle_ledger.events view)
  | Error error -> failf "%s" (Candle_ledger.read_error_to_string error)
;;

let settled config = List.mem "unattributed" (kinds config)

let last_candidates (config : Workspace.config) =
  match Candle_ledger.read ~base_path:config.base_path with
  | Error error -> failf "%s" (Candle_ledger.read_error_to_string error)
  | Ok view ->
    List.find_map
      (fun (event : E.t) ->
         match event.body with
         | E.Candidates c | E.Candidates_fenced c -> Some (c.candidate_task_ids, c.candidate_keepers)
         | E.Half_life_set _ | E.Snapshot _ | E.Payout_owed _ | E.Candidate_window_held _ | E.Unattributed _ | E.Paid _ | E.Equipped _ | E.Purchased _ | E.Granted _ | E.Gifted _ | E.Gifted_item _ | E.Payout_failed _ -> None)
      (List.rev (Candle_ledger.events view))


let await_within env label predicate =
  let clock = Eio.Stdenv.clock env in
  match
    Eio.Time.with_timeout clock 10. (fun () ->
      while not (predicate ()) do
        Eio.Time.sleep clock 0.02
      done;
      Ok ())
  with
  | Ok () -> ()
  | Error `Timeout -> failf "%s did not happen within 10s" label
;;

(* {1 Tests} *)

let test_the_worker_settles_a_waiting_payout_when_it_starts () =
  with_workspace
  @@ fun env config ->
  enable_candle config;
  seed_payout config ~goal_id:"goal-1";
  Eio.Switch.run (fun sw ->
    Candle_payout_worker.start ~appraise ~sw ~config ();
    await_within env "the payout being settled" (fun () -> settled config));
  check
    (list string)
    "Candidates, then Unattributed"
    [ "snapshot"; "payout_owed"; "candidates"; "unattributed" ]
    (kinds config)
;;

let test_a_wake_makes_the_worker_look_again () =
  with_workspace
  @@ fun env config ->
  enable_candle config;
  Eio.Switch.run (fun sw ->
    Candle_payout_worker.start ~appraise ~sw ~config ();
    (* The start-up pass finds nothing waiting. Seeding before it ran would let
       that pass settle the payout and leave the wake unproven. *)
    await_within env "the start-up pass" Candle_payout_worker.For_testing.idle;
    seed_payout config ~goal_id:"goal-2";
    Candle_payout_worker.wake ();
    await_within env "the payout being settled" (fun () -> settled config));
  check
    (list string)
    "Candidates, then Unattributed"
    [ "snapshot"; "payout_owed"; "candidates"; "unattributed" ]
    (kinds config)
;;

let test_the_worker_does_nothing_while_candle_is_off () =
  with_workspace
  @@ fun env config ->
  seed_payout config ~goal_id:"goal-3";
  Eio.Switch.run (fun sw ->
    Candle_payout_worker.start ~appraise ~sw ~config ();
    Candle_payout_worker.wake ();
    await_within env "the woken pass" Candle_payout_worker.For_testing.idle);
  check (list string) "nothing was added" [ "snapshot"; "payout_owed" ] (kinds config)
;;

(* The Task and the Keeper are read from the real stores: a Task done inside the
   Goal's window by a name that has a Keeper config file makes that Keeper the
   candidate, and a payout with a Keeper to pay is not closed. *)
let test_a_payout_with_a_keeper_to_pay_gets_candidates_and_keeps_waiting () =
  with_workspace
  @@ fun env config ->
  enable_candle config;
  write_backlog config [ make_task ~id:"task-1" (done_by "keeper-a" "2026-09-25T00:00:00Z") ];
  write_keeper config "keeper-a";
  seed_payout config ~goal_id:"goal-4" ~linked_task_ids:[ "task-1" ];
  Eio.Switch.run (fun sw ->
    Candle_payout_worker.start ~appraise ~sw ~config ();
    await_within env "the Candidates row" (fun () -> List.mem "candidates" (kinds config)));
  check
    (list string)
    "Candidates, and no row that closes the payout"
    [ "snapshot"; "payout_owed"; "candidates" ]
    (kinds config);
  match last_candidates config with
  | Some (candidate_task_ids, candidate_keepers) ->
    check (list string) "candidate Tasks" [ "task-1" ] candidate_task_ids;
    check (list string) "candidate keepers" [ "keeper-a" ] candidate_keepers
  | None -> fail "no Candidates row"
;;

let test_detached_appraiser_still_preserves_holds_and_other_goals_advance () =
  with_workspace @@ fun env config ->
  enable_candle config;
  write_backlog config
    [make_task ~id:"task-held" (done_by "keeper-a" "2026-09-20T01:00:00Z");
     make_task ~id:"task-normal" (done_by "keeper-a" "2026-09-25T00:00:00Z")];
  write_keeper config "keeper-a";
  seed_payout config ~goal_id:"goal-held" ~linked_task_ids:["task-held"];
  seed_payout config ~goal_id:"goal-normal" ~linked_task_ids:["task-normal"];
  let available = ref false in
  let calls = ref [] in
  Candle_status.install_appraiser_check (fun () ->
    if !available then Ok () else Error "fixture appraiser is detached");
  Fun.protect ~finally:(fun () -> Candle_status.install_appraiser_check (fun () -> Ok ())) (fun () ->
    let reject ~(identity : Candle_appraisal.identity) _ =
      calls := identity.goal_id :: !calls;
      Error (Candle_appraisal.Invalid_response "fixture rejects after dispatch") in
    Eio.Switch.run (fun sw ->
      Candle_payout_worker.start ~appraise:reject ~sw ~config ();
      await_within env "observations while detached" (fun () ->
        let rows = kinds config in
        List.mem "candidate_window_held" rows && List.mem "candidates" rows
        && Candle_payout_worker.For_testing.idle ());
      check (list string) "detached appraiser gets no calls" [] !calls;
      available := true;
      Candle_payout_worker.pulse ();
      await_within env "normal Goal is appraised" (fun () ->
        !calls <> [] && Candle_payout_worker.For_testing.idle ());
      check (list string) "only normal Goal reaches the appraiser" ["goal-normal"] !calls;
      Candle_payout_worker.pulse ();
      await_within env "unchanged rejected appraisal remains idle" Candle_payout_worker.For_testing.idle;
      check (list string) "held Goal and rejected normal Goal do not loop" ["goal-normal"] !calls))
;;

let test_contended_task_lock_does_not_block_prepared_or_taskless_goals () =
  with_workspace @@ fun env config ->
  enable_candle config;
  write_keeper config "keeper-a";
  write_backlog config
    [make_task ~id:"ready-task" (done_by "keeper-a" "2026-09-25T00:00:00Z");
     make_task ~id:"locked-task" (done_by "keeper-a" "2026-09-25T00:00:00Z")];
  seed_payout config ~goal_id:"ready" ~linked_task_ids:["ready-task"];
  (match Candle_candidates.drain_once ~now:(fun () -> 1_790_000_000.) config |> ok_or_fail with
   | [Candle_candidates.Wrote_candidates _] -> () | _ -> fail "fixture did not prepare the first Goal");
  seed_payout config ~goal_id:"locked" ~linked_task_ids:["locked-task"];
  seed_payout config ~goal_id:"taskless";
  let locked, notify_locked = Eio.Promise.create () in
  let release, notify_release = Eio.Promise.create () in
  let calls = ref [] in
  let reject ~(identity:Candle_appraisal.identity) _ =
    calls := identity.goal_id :: !calls;
    Error (Candle_appraisal.Invalid_response "fixture stops after dispatch") in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.fork ~sw (fun () ->
      match Workspace_utils_ops.with_file_lock_r config (Workspace_backlog.backlog_lock_path config) (fun () ->
        Eio.Promise.resolve notify_locked ();
        Eio.Promise.await release) with
      | Ok () -> () | Error error -> fail (Masc_domain.masc_error_to_string error));
    Eio.Promise.await locked;
    Candle_payout_worker.start ~appraise:reject ~sw ~config ();
    await_within env "prepared appraisal and taskless payout despite held lock" (fun () ->
      !calls = ["ready"] && settled config && Candle_payout_worker.For_testing.idle ());
    check bool "locked Goal did not acquire a candidate row" false
      (match Candle_ledger.read ~base_path:config.base_path with
       | Error error -> fail (Candle_ledger.read_error_to_string error)
       | Ok view -> List.exists (fun (event:E.t) -> match event.body with
           | E.Candidates c | E.Candidates_fenced c -> c.goal_id = "locked"
           | _ -> false) (Candle_ledger.events view));
    Eio.Promise.resolve notify_release ())
;;

let test_cancelled_task_lease_is_released_before_retry () =
  with_workspace @@ fun _env config ->
  (match config.Workspace_utils_backend_setup.backend with
   | Workspace_utils_backend_setup.FileSystem _ -> ()
   | Memory _ -> fail "this scenario requires the filesystem lease");
  let path = Workspace_backlog.backlog_lock_path config in
  let context, signal_context = Eio.Promise.create () in
  let entered, signal_entered = Eio.Promise.create () in
  let never, _ = Eio.Promise.create () in
  let result, signal_result = Eio.Promise.create () in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.fork ~sw (fun () ->
      let cancelled = try
        Eio.Cancel.sub (fun cc ->
          Eio.Promise.resolve signal_context cc;
          ignore (Workspace_utils_ops.try_with_file_lock config path (fun () ->
            Eio.Promise.resolve signal_entered ();
            Eio.Promise.await never));
          false)
        with Eio.Cancel.Cancelled _ -> true in
      Eio.Promise.resolve signal_result cancelled);
    Eio.Promise.await entered;
    Eio.Cancel.cancel (Eio.Promise.await context) Exit;
    check bool "owner observes cancellation" true (Eio.Promise.await result);
    (match Workspace_utils_ops.try_with_file_lock config path (fun () -> ()) with
     | Workspace_utils_ops.Lock_acquired () -> ()
     | Lock_contended -> fail "cancelled owner left its lease behind"
     | Lock_unavailable detail -> fail detail))
;;

let test_inflight_task_commit_precedes_candidate_observation () =
  with_workspace @@ fun env config ->
  enable_candle config;
  write_keeper config "keeper-a";
  write_backlog config [make_task ~id:"task-race" Masc_domain.Todo];
  seed_payout config ~goal_id:"goal-race" ~linked_task_ids:["task-race"];
  let entered, signal_entered = Eio.Promise.create () in
  let release, signal_release = Eio.Promise.create () in
  let committed, signal_committed = Eio.Promise.create () in
  Eio.Switch.run (fun sw ->
    Eio.Fiber.fork ~sw (fun () ->
      (match Workspace_utils_ops.with_file_lock_r config (Workspace_backlog.backlog_lock_path config) (fun () ->
         Eio.Promise.resolve signal_entered ();
         Eio.Promise.await release;
         write_backlog config [make_task ~id:"task-race" (done_by "keeper-a" "2026-09-20T01:00:00Z")]) with
       | Ok () -> () | Error error -> fail (Masc_domain.masc_error_to_string error));
      Eio.Promise.resolve signal_committed ());
    Eio.Promise.await entered;
    Candle_payout_worker.start ~appraise ~sw ~config ();
    await_within env "contended initial scan" Candle_payout_worker.For_testing.idle;
    check (list string) "no stale candidate is committed during the Task write"
      ["snapshot";"payout_owed"] (kinds config);
    Eio.Promise.resolve signal_release ();
    Eio.Promise.await committed;
    Candle_payout_worker.pulse ();
    await_within env "boundary observed after Task commit" (fun () ->
      List.mem "candidate_window_held" (kinds config) && Candle_payout_worker.For_testing.idle ());
    check (list string) "the committed boundary is held, without a terminal payout"
      ["snapshot";"payout_owed";"candidate_window_held"] (kinds config))
;;

let test_policy_edit_releases_a_rejected_owner () =
  with_workspace @@ fun env config ->
  enable_candle config;
  write_backlog config [make_task ~id:"task-policy" (done_by "keeper-a" "2026-09-25T00:00:00Z")];
  write_keeper config "keeper-a";
  seed_payout config ~goal_id:"goal-policy" ~linked_task_ids:["task-policy"];
  let calls = ref 0 in
  let reject ~identity:_ _ =
    incr calls;
    Error (Candle_appraisal.Invalid_response "fixture rejects the captured policy") in
  Eio.Switch.run (fun sw ->
    Candle_payout_worker.start ~appraise:reject ~sw ~config ();
    await_within env "first rejected appraisal" (fun () -> !calls = 1 && Candle_payout_worker.For_testing.idle ());
    Candle_payout_worker.pulse ();
    await_within env "unchanged policy pulse" Candle_payout_worker.For_testing.idle;
    check int "unchanged policy does not release rejection" 1 !calls;
    enable_candle ~medium_criteria:"Revised connected feature" config;
    Candle_payout_worker.pulse ();
    await_within env "policy edit retries the original obligation" (fun () -> !calls = 2 && Candle_payout_worker.For_testing.idle ());
    Candle_payout_worker.pulse ();
    await_within env "second unchanged policy pulse" Candle_payout_worker.For_testing.idle;
    check int "rejected retry does not become a pulse loop" 2 !calls)
;;

let test_retry_event_survives_temporarily_unpreparable_candidates () =
  with_workspace @@ fun env config ->
  enable_candle config;
  write_backlog config [make_task ~id:"task-event" (done_by "keeper-a" "2026-09-25T00:00:00Z")];
  write_keeper config "keeper-a";
  seed_payout config ~goal_id:"goal-event" ~linked_task_ids:["task-event"];
  let calls = ref 0 in
  let reject ~identity:_ _ =
    incr calls; Error (Candle_appraisal.Invalid_response "fixture rejects appraisal") in
  Eio.Switch.run (fun sw ->
    Candle_payout_worker.start ~appraise:reject ~sw ~config ();
    await_within env "initial rejection" (fun () -> !calls = 1 && Candle_payout_worker.For_testing.idle ());
    let path = Candle_ledger.path ~base_path:config.base_path in
    let original = In_channel.with_open_bin path In_channel.input_all in
    let conflict = match Candle_ledger.read ~base_path:config.base_path with
      | Error error -> fail (Candle_ledger.read_error_to_string error)
      | Ok view ->
        (match List.find_opt (fun (row:E.t) -> match row.body with E.Snapshot _ -> true | _ -> false)
           (Candle_ledger.events view) with
         | Some ({body=E.Snapshot snapshot;_} as row) ->
           {row with body=E.Snapshot {snapshot with title="conflicting input"}}
         | _ -> fail "missing Snapshot") in
    (match Candle_ledger.update ~base_path:config.base_path (fun _ -> Ok ([conflict], ())) with
     | Ok () -> () | Error error -> fail (Candle_ledger.update_error_to_string Fun.id error));
    Candle_payout_worker.wake ();
    await_within env "event while Snapshot conflicts" Candle_payout_worker.For_testing.idle;
    check int "conflict prevents dispatch" 1 !calls;
    (* Simulate an operator repairing the conflicting fixture while the worker
       is idle; the same retained event must authorize the next pulse. *)
    Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel original);
    Candle_payout_worker.pulse ();
    await_within env "repaired evidence resumes the requested retry" (fun () ->
      !calls = 2 && Candle_payout_worker.For_testing.idle ()))
;;

(* A start for the base path that already runs, and a start for another base
   path while one runs, are refused. The refused base path's payout waits. *)
let test_a_start_while_a_worker_runs_is_refused () =
  with_workspace
  @@ fun env config ->
  with_second_workspace
  @@ fun other ->
  enable_candle config;
  enable_candle other;
  seed_payout config ~goal_id:"goal-5";
  seed_payout other ~goal_id:"goal-6";
  Eio.Switch.run (fun sw ->
    Candle_payout_worker.start ~appraise ~sw ~config ();
    Candle_payout_worker.start ~appraise ~sw ~config ();
    Candle_payout_worker.start ~appraise ~sw ~config:other ();
    await_within env "the first base path's payout" (fun () -> settled config);
    Candle_payout_worker.wake ();
    await_within env "the woken pass" Candle_payout_worker.For_testing.idle);
  check (list string) "the other base path was not served" [ "snapshot"; "payout_owed" ] (kinds other)
;;

(* The daemon gives up its place when its switch ends, or no later start could
   ever run. *)
let test_a_worker_can_start_again_once_its_switch_has_ended () =
  with_workspace
  @@ fun env config ->
  with_second_workspace
  @@ fun other ->
  enable_candle config;
  enable_candle other;
  seed_payout config ~goal_id:"goal-7";
  seed_payout other ~goal_id:"goal-8";
  Eio.Switch.run (fun sw ->
    Candle_payout_worker.start ~appraise ~sw ~config ();
    await_within env "the first payout" (fun () -> settled config));
  Eio.Switch.run (fun sw ->
    Candle_payout_worker.start ~appraise ~sw ~config:other ();
    await_within env "the second payout" (fun () -> settled other))
;;

(* Corrupt contributor evidence must remain retryable. Exercise the actual
   archive decoder and payout pass, then repair the same row and retry. *)
let test_unreadable_contributor_waits_for_repair () =
  List.iter (fun damaged_assignee ->
    with_workspace @@ fun _env config ->
    enable_candle config;
    write_keeper config "keeper-a";
    seed_payout config ~goal_id:"goal-corrupt" ~linked_task_ids:[ "task-corrupt" ];
    let task = make_task ~id:"task-corrupt" (done_by "keeper-a" "2026-09-25T00:00:00Z") in
    let row = Masc_domain.task_to_yojson task in
    let damaged =
      match row with
      | `Assoc fields ->
        let fields = List.remove_assoc "assignee" fields in
        `Assoc (match damaged_assignee with None -> fields | Some value -> ("assignee", value) :: fields)
      | _ -> fail "task encoder did not produce an object"
    in
    let write row =
      Workspace_utils_ops.write_json config (Workspace_utils_paths_backend.archive_path config)
        (`Assoc [ "tasks", `List [row] ])
    in
    let drain () = Candle_candidates.drain_once ~now:(fun () -> 1_790_000_000.) config |> ok_or_fail in
    write damaged;
    (match drain () with
     | [Candle_candidates.Waiting_task { issues; _ }] ->
       check bool "names unreadable contributor" true
         (List.exists (function Candle_payout.Task_unobserved {task_id="task-corrupt"} -> true
           | _ -> false) issues)
     | _ -> fail "corrupt contributor must not settle the payout");
    (match Candle_tasks.lookups config ~goal_id:"goal-corrupt" ["task-corrupt"] with
     | Error detail -> check bool "strict read retains the repair reason" true
         (String_util.contains_substring detail "assignee")
     | Ok _ -> fail "strict read accepted the corrupt contributor");
    check (list string) "no irreversible candidate or unattributed row"
      ["snapshot"; "payout_owed"] (kinds config);
    write row;
    (match drain () with
     | [Candle_candidates.Wrote_candidates _] -> ()
     | _ -> fail "repaired contribution must be collected");
    check (list string) "the repaired payout still awaits appraisal"
      ["snapshot"; "payout_owed"; "candidates"] (kinds config);
    match last_candidates config with
    | Some (_, keepers) -> check (list string) "original contributor is retained" ["keeper-a"] keepers
    | None -> fail "no repaired Candidates row")
    [None; Some `Null; Some (`Int 7); Some (`String ""); Some (`String "  ")]
;;

let test_partial_real_task_read_retains_a_boundary_observation () =
  with_workspace @@ fun _env config ->
  enable_candle config;
  write_keeper config "keeper-a";
  write_backlog config [make_task ~id:"task-boundary" (done_by "keeper-a" "2026-09-20T01:00:00Z")];
  Workspace_goal_index.write_goal_task_links config
    ["goal-partial", ["task-boundary";"task-missing"]];
  seed_payout config ~goal_id:"goal-partial" ~linked_task_ids:["task-boundary";"task-missing"];
  let drain () = Candle_candidates.drain_once ~now:(fun () -> 1_790_000_000.) config |> ok_or_fail in
  (match drain () with
   | [Candle_candidates.Held_window {recorded=true;_}] -> ()
   | _ -> fail "known boundary must be retained despite another unreadable Task");
  let retained () =
    match Candle_ledger.read ~base_path:config.base_path with
    | Error error -> fail (Candle_ledger.read_error_to_string error)
    | Ok view -> List.find_map (fun (row : E.t) -> match row.body with
        | E.Candidate_window_held held -> Some (held.tasks, held.task_keepers)
        | _ -> None) (Candle_ledger.events view) in
  let before = retained () in
  (match before with
   | Some (["task-boundary", E.Found {status=E.Done _;_}; "task-missing", E.Unobserved],
           ["task-boundary", E.Keeper_name "keeper-a"; "task-missing", E.Keeper_unknown]) -> ()
   | _ -> fail "the hold did not preserve both known and unknown observations");
  (match Workspace_task.delete_task_r config ~task_id:"task-boundary" with
   | Ok _ -> () | Error error -> fail (Masc_domain.masc_error_to_string error));
  (match drain () with
   | [Candle_candidates.Held_window {recorded=false;_}] -> ()
   | _ -> fail "deletion must not erase or recalculate the original hold");
  check bool "the retained boundary and assignee survive Task deletion" true (before = retained ())
;;

let test_partial_archive_observation_survives_unreadable_links_and_other_row () =
  with_workspace @@ fun _env config ->
  enable_candle config;
  write_keeper config "keeper-a";
  write_backlog config [];
  let known = make_task ~id:"task-archive" (done_by "keeper-a" "2026-09-20T01:00:00Z") in
  Workspace_utils_ops.write_json config (Workspace_utils_paths_backend.archive_path config)
    (`Assoc ["tasks", `List [Masc_domain.task_to_yojson known; `Assoc ["id", `String "task-broken"];
                              `Assoc ["title", `String "unidentified damaged row"]]]);
  Fs_compat.save_file (Workspace_goal_index.goal_task_links_path config) "not json";
  seed_payout config ~goal_id:"goal-partial-archive" ~linked_task_ids:["task-archive";"task-broken"];
  (match Candle_candidates.drain_once ~now:(fun () -> 1_790_000_000.) config |> ok_or_fail with
   | [Candle_candidates.Held_window {recorded=true;_}] -> ()
   | _ -> fail "the readable archive boundary must be retained");
  let rows = match Candle_ledger.read ~base_path:config.base_path with
    | Ok view -> Candle_ledger.events view
    | Error error -> fail (Candle_ledger.read_error_to_string error) in
  (match List.find_opt (fun (row:E.t) -> match row.body with E.Candidate_window_held _ -> true | _ -> false) rows with
   | Some {body=E.Candidate_window_held held;_} ->
     (match held.tasks with
      | ["task-archive", E.Found_uncertain
          [{assignee=E.Assigned "keeper-a";status=E.Observed_status (E.Done _);
            keeper=E.Keeper_name "keeper-a";_}];
         "task-broken", E.Found_uncertain
          [{assignee=E.Unreadable_assignee;status=E.Unreadable_status;_}]] -> ()
      | _ -> fail "archive observations did not retain distinct states")
   | _ -> fail "no durable archive hold")
;;

let test_boundary_survives_unreadable_assignee_and_duplicate_task_rows () =
  List.iter (fun duplicate ->
    with_workspace @@ fun _env config ->
    enable_candle config;
    write_keeper config "keeper-a";
    let assignee = if duplicate then "keeper-a" else "" in
    let boundary = make_task ~id:"task-fragment" (done_by assignee "2026-09-20T01:00:00Z") in
    let rows = if duplicate then [boundary;make_task ~id:"task-fragment" Masc_domain.Todo] else [boundary] in
    write_backlog config rows;
    seed_payout config ~goal_id:"goal-fragment" ~linked_task_ids:["task-fragment"];
    (match Candle_candidates.drain_once ~now:(fun () -> 1_790_000_000.) config |> ok_or_fail with
     | [Candle_candidates.Held_window {recorded=true;_}] -> ()
     | _ -> fail "a readable boundary must survive uncertainty inside the Task");
    let events = match Candle_ledger.read ~base_path:config.base_path with
      | Ok view -> Candle_ledger.events view
      | Error error -> fail (Candle_ledger.read_error_to_string error) in
    (match List.find_opt (fun (row:E.t) -> match row.body with E.Candidate_window_held _ -> true | _ -> false) events with
     | Some {body=E.Candidate_window_held held;_} ->
       (match held.tasks with
        | ["task-fragment", E.Found_uncertain (first :: rest)] ->
          check bool "boundary time remains observed" true
            (match first.status with E.Observed_status (E.Done _) -> true | _ -> false);
          if duplicate then (
            check int "both conflicting rows remain" 1 (List.length rest);
            check bool "the observed Keeper classification remains" true
              (first.assignee = E.Assigned "keeper-a" && first.keeper = E.Keeper_name "keeper-a"))
          else check bool "unreadable assignee stays unknown" true
            (first.assignee = E.Unreadable_assignee && first.keeper = E.Keeper_unknown)
        | _ -> fail "partial Task observations were lost")
     | _ -> fail "no durable partial Task hold")) [false;true]
;;

let test_damaged_archive_row_retains_independent_payout_fields () =
  with_workspace @@ fun _env config ->
  enable_candle config;
  write_keeper config "keeper-a";
  write_backlog config [];
  let task = make_task ~id:"task-damaged" (done_by "keeper-a" "2026-09-20T01:00:00Z") in
  let damaged = match Masc_domain.task_to_yojson task with
    | `Assoc fields -> `Assoc (("skills", `String "invalid") :: List.remove_assoc "skills" fields)
    | _ -> fail "task fixture did not encode as an object" in
  Workspace_utils_ops.write_json config (Workspace_utils_paths_backend.archive_path config)
    (`Assoc ["tasks", `List [damaged]]);
  seed_payout config ~goal_id:"goal-damaged-row" ~linked_task_ids:["task-damaged"];
  (match Candle_candidates.drain_once ~now:(fun () -> 1_790_000_000.) config |> ok_or_fail with
   | [Candle_candidates.Held_window {recorded=true;_}] -> ()
   | _ -> fail "independent completion fields in damaged archive row were lost");
  let rows = match Candle_ledger.read ~base_path:config.base_path with
    | Ok view -> Candle_ledger.events view | Error error -> fail (Candle_ledger.read_error_to_string error) in
  (match List.find_opt (fun (row:E.t) -> match row.body with E.Candidate_window_held _ -> true | _ -> false) rows with
   | Some {body=E.Candidate_window_held {tasks=["task-damaged", E.Found_uncertain
       [{assignee=E.Assigned "keeper-a";status=E.Observed_status (E.Done _);
         keeper=E.Keeper_name "keeper-a";_}]];_};_} -> ()
   | _ -> fail "damaged archive fragment did not retain the completion and Keeper")
;;

let test_damaged_backlog_preserves_uncertain_boundary () =
  List.iter (fun boundary_in_archive ->
  with_workspace @@ fun _env config ->
  enable_candle config;
  write_keeper config "keeper-a";
  let boundary = make_task ~id:"task-boundary" (done_by "keeper-a" "2026-09-20T01:00:00Z") in
  let damaged = make_task ~id:"task-damaged" Masc_domain.Todo in
  write_backlog config (if boundary_in_archive then [damaged] else [boundary;damaged]);
  if boundary_in_archive then
    Workspace_utils_ops.write_json config (Workspace_utils_paths_backend.archive_path config)
      (`Assoc ["tasks", `List [Masc_domain.task_to_yojson boundary]]);
  let path = Workspace_backlog.backlog_path config in
  let raw = Yojson.Safe.from_string (In_channel.with_open_bin path In_channel.input_all) in
  let damaged = match raw with
    | `Assoc fields -> `Assoc (List.map (fun (name, value) ->
        if name <> "tasks" then name,value else name, (match value with
          | `List rows -> `List (List.map (function
              | `Assoc fields as row ->
                (match List.assoc_opt "id" fields with
                 | Some (`String "task-damaged") ->
                   `Assoc (("skills", `String "invalid") :: List.remove_assoc "skills" fields)
                 | _ -> row)
              | row -> row) rows)
          | _ -> fail "backlog fixture has no tasks")) fields)
    | _ -> fail "backlog fixture is not an object" in
  Fs_compat.save_file path (Yojson.Safe.to_string damaged);
  seed_payout config ~goal_id:"goal-damaged-backlog" ~linked_task_ids:["task-boundary";"task-damaged"];
  (match Candle_candidates.drain_once ~now:(fun () -> 1_790_000_000.) config |> ok_or_fail with
   | [Candle_candidates.Held_window {recorded=true;_}] -> ()
   | _ -> fail "damaged backlog discarded a readable boundary");
  let rows = match Candle_ledger.read ~base_path:config.base_path with
    | Ok view -> Candle_ledger.events view | Error error -> fail (Candle_ledger.read_error_to_string error) in
  (match List.find_opt (fun (row:E.t) -> match row.body with E.Candidate_window_held _ -> true | _ -> false) rows with
   | Some {body=E.Candidate_window_held {tasks=("task-boundary", E.Found_uncertain
       [{assignee=E.Assigned "keeper-a";status=E.Observed_status (E.Done _);_}]) :: _;_};_} -> ()
   | _ -> fail "damaged backlog did not retain the boundary fragment")) [false;true]
;;

let test_duplicate_payout_fields_retain_each_observation () =
  List.iter (fun archive ->
    with_workspace @@ fun _env config ->
    enable_candle config;
    write_keeper config "keeper-a";
    write_keeper config "keeper-b";
    let task = make_task ~id:"task-duplicate-fields" (done_by "keeper-a" "2026-09-25T00:00:00Z") in
    let duplicate = match Masc_domain.task_to_yojson task with
      | `Assoc fields -> `Assoc (fields @ ["completed_at", `String "2026-09-20T01:00:00Z";
                                          "assignee", `String "keeper-b"])
      | _ -> fail "task fixture did not encode as an object" in
    if archive then (
      write_backlog config [];
      Workspace_utils_ops.write_json config (Workspace_utils_paths_backend.archive_path config)
        (`Assoc ["tasks", `List [duplicate]]))
    else (
      write_backlog config [task];
      let path = Workspace_backlog.backlog_path config in
      let raw = Yojson.Safe.from_string (In_channel.with_open_bin path In_channel.input_all) in
      let raw = match raw with
        | `Assoc fields -> `Assoc (List.map (fun (name, value) ->
            if String.equal name "tasks" then name, `List [duplicate] else name, value) fields)
        | _ -> fail "backlog fixture is not an object" in
      Fs_compat.save_file path (Yojson.Safe.to_string raw));
    seed_payout config ~goal_id:"goal-duplicate-fields" ~linked_task_ids:["task-duplicate-fields"];
    (match Candle_candidates.drain_once ~now:(fun () -> 1_790_000_000.) config |> ok_or_fail with
     | [Candle_candidates.Held_window {recorded=true;_}] -> ()
     | _ -> fail "a second completion at the boundary must be held");
    let rows = match Candle_ledger.read ~base_path:config.base_path with
      | Ok view -> Candle_ledger.events view | Error error -> fail (Candle_ledger.read_error_to_string error) in
    (match List.find_opt (fun (row:E.t) -> match row.body with E.Candidate_window_held _ -> true | _ -> false) rows with
     | Some {body=E.Candidate_window_held {tasks=["task-duplicate-fields", E.Found_uncertain fragments];_};_} ->
       List.iter (fun timestamp ->
         check bool "each readable completion is retained independently" true
           (List.exists (fun (fragment:E.task_fragment) -> match fragment.status, fragment.assignee with
              | E.Observed_status (E.Done {completed_at}), E.Unreadable_assignee ->
                Candle_time.compare completed_at (at timestamp) = 0
              | _ -> false) fragments)) ["2026-09-25T00:00:00Z";"2026-09-20T01:00:00Z"];
       List.iter (fun name ->
         check bool "each possible Keeper is retained without a status association" true
           (List.exists (fun (fragment:E.task_fragment) ->
              fragment.assignee = E.Assigned name && fragment.status = E.Unreadable_status
              && fragment.keeper = E.Keeper_name name) fragments)) ["keeper-a";"keeper-b"]
     | _ -> fail "the alternatives were not retained in the hold")) [false;true]
;;

let test_goal_observation_reads_off_and_ledger_independently () =
  with_workspace @@ fun _env config ->
  let read () = Candle_goal_observation_reader.read ~base_path:config.base_path ~goal_id:"goal-observed" in
  (match read () with
   | {Candle_goal_observation.configuration=Off; ledger=Missing} -> ()
   | _ -> fail "absent ledger and off config should be independent observations");
  enable_candle config;
  seed_payout config ~goal_id:"goal-observed";
  ignore (Candle_candidates.drain_once ~now:(fun () -> 1_790_000_000.) config |> ok_or_fail);
  let path = Candle_ledger.path ~base_path:config.base_path in
  let before = In_channel.with_open_bin path In_channel.input_all in
  let config_path = Config_dir_resolver.candle_toml_path_for_base_path ~base_path:config.base_path in
  Sys.remove config_path;
  (match read () with
   | {Candle_goal_observation.configuration=Off; ledger=Observed (Unattributed {reason=No_candidates;_})} -> ()
   | _ -> fail "off config must not hide a recorded unattributed payout");
  check string "observation does not change the ledger" before (In_channel.with_open_bin path In_channel.input_all);
  Out_channel.with_open_gen [Open_append; Open_binary] 0o600 path (fun channel ->
    Out_channel.output_string channel "{\"broken\":true}\n");
  (match read () with
   | {Candle_goal_observation.ledger=Unavailable Invalid_row;_} -> ()
   | _ -> fail "a corrupt row is unavailable, not an empty payout")
;;

let test_a_wake_with_no_worker_running_does_nothing () = Candle_payout_worker.wake ()

let () =
  run
    "candle_payout_worker"
    [ ( "worker"
      , [ test_case "Goal observation separates config and ledger" `Quick test_goal_observation_reads_off_and_ledger_independently
        ; test_case "unreadable contributor waits for repair" `Quick test_unreadable_contributor_waits_for_repair
        ; test_case "partial real Task read retains a boundary observation" `Quick
            test_partial_real_task_read_retains_a_boundary_observation
        ; test_case "partial archive survives an unreadable links file and row" `Quick
            test_partial_archive_observation_survives_unreadable_links_and_other_row
        ; test_case "boundary survives unreadable assignee and duplicate Task rows" `Quick
            test_boundary_survives_unreadable_assignee_and_duplicate_task_rows
        ; test_case "damaged archive row retains independent payout fields" `Quick
            test_damaged_archive_row_retains_independent_payout_fields
        ; test_case "damaged backlog preserves an uncertain boundary" `Quick
            test_damaged_backlog_preserves_uncertain_boundary
        ; test_case "duplicate payout fields retain each observation" `Quick
            test_duplicate_payout_fields_retain_each_observation
        ; test_case
            "the worker settles a waiting payout when it starts"
            `Quick
            test_the_worker_settles_a_waiting_payout_when_it_starts
        ; test_case "a wake makes the worker look again" `Quick test_a_wake_makes_the_worker_look_again
        ; test_case
            "the worker does nothing while candle is off"
            `Quick
            test_the_worker_does_nothing_while_candle_is_off
        ; test_case
            "a payout with a keeper to pay gets candidates and keeps waiting"
            `Quick
            test_a_payout_with_a_keeper_to_pay_gets_candidates_and_keeps_waiting
        ; test_case "detached appraiser preserves a hold while another Goal advances" `Quick
            test_detached_appraiser_still_preserves_holds_and_other_goals_advance
        ; test_case "contended Task lock leaves prepared and taskless Goals runnable" `Quick
            test_contended_task_lock_does_not_block_prepared_or_taskless_goals
        ; test_case "cancelled Task lease releases before retry" `Quick
            test_cancelled_task_lease_is_released_before_retry
        ; test_case "inflight Task commit precedes candidate observation" `Quick
            test_inflight_task_commit_precedes_candidate_observation
        ; test_case "policy edit releases rejected payout owner" `Quick test_policy_edit_releases_a_rejected_owner
        ; test_case "retry event survives temporarily unpreparable candidates" `Quick
            test_retry_event_survives_temporarily_unpreparable_candidates
        ; test_case "a start while a worker runs is refused" `Quick test_a_start_while_a_worker_runs_is_refused
        ; test_case
            "a worker can start again once its switch has ended"
            `Quick
            test_a_worker_can_start_again_once_its_switch_has_ended
        ; test_case
            "a wake with no worker running does nothing"
            `Quick
            test_a_wake_with_no_worker_running_does_nothing
        ] )
    ]
;;
