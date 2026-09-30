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
    ; task_deletion_receipts = []
    ; pending_completion_rejections = []
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

let enable_candle (config : Workspace.config) =
  let path =
    inside config (Config_dir_resolver.candle_toml_path_for_base_path ~base_path:config.base_path)
  in
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc {|[payout]
weight_max = 10
deduction_rate = 10
deduction_floor = 200
[payout.grades_milli]
trivial = 1000
small = 2000
medium = 3000
large = 4000
epic = 5000
|})
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
         | E.Candidates c -> Some (c.candidate_task_ids, c.candidate_keepers)
         | E.Snapshot _ | E.Payout_owed _ | E.Unattributed _ | E.Paid _ | E.Purchased _ | E.Payout_failed _ -> None)
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
    Candle_payout_worker.start ~appraise ~sw ~config;
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
    Candle_payout_worker.start ~appraise ~sw ~config;
    (* The start-up pass finds nothing waiting. *)
    Eio.Time.sleep (Eio.Stdenv.clock env) 0.2;
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
    Candle_payout_worker.start ~appraise ~sw ~config;
    Candle_payout_worker.wake ();
    Eio.Time.sleep (Eio.Stdenv.clock env) 0.3);
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
    Candle_payout_worker.start ~appraise ~sw ~config;
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
    Candle_payout_worker.start ~appraise ~sw ~config;
    Candle_payout_worker.start ~appraise ~sw ~config;
    Candle_payout_worker.start ~appraise ~sw ~config:other;
    await_within env "the first base path's payout" (fun () -> settled config);
    Candle_payout_worker.wake ();
    Eio.Time.sleep (Eio.Stdenv.clock env) 0.3);
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
    Candle_payout_worker.start ~appraise ~sw ~config;
    await_within env "the first payout" (fun () -> settled config));
  Eio.Switch.run (fun sw ->
    Candle_payout_worker.start ~appraise ~sw ~config:other;
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
     | [Candle_candidates.Retry_later { detail; _ }] ->
       check bool "names unreadable contributor" true
         (String_util.contains_substring detail "assignee")
     | _ -> fail "corrupt contributor must not settle the payout");
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

let test_a_wake_with_no_worker_running_does_nothing () = Candle_payout_worker.wake ()

let () =
  run
    "candle_payout_worker"
    [ ( "worker"
      , [ test_case "unreadable contributor waits for repair" `Quick test_unreadable_contributor_waits_for_repair
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
