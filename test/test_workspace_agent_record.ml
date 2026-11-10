(* RFC-0480 §3.4: an agent record write reports what the Clients roster
   draws, and only that. A heartbeat moving last_seen is not a roster
   change; a Task, a status, or the record's first appearance is. *)

open Alcotest
open Masc

let check = Alcotest.check

(* Record writes go through the backend FS, so the test runs inside the Eio
   environment the workspace uses, on a throwaway directory. *)
let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc_agent_record_%d_%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.)))
  in
  Unix.mkdir tmp_dir 0o755;
  let config = Workspace.default_config tmp_dir in
  let _ = Workspace.init config ~agent_name:None in
  Fun.protect
    ~finally:(fun () ->
      let _ = Workspace.reset config in
      (try Unix.rmdir tmp_dir with _ -> ()))
    (fun () -> f config)
;;

let agent ?(status = Masc_domain.Active) ?(current_task = None)
    ?(last_seen = "2026-11-05T01:00:00Z") name : Masc_domain.agent =
  { Masc_domain.id = None
  ; name
  ; agent_type = "gemini"
  ; status
  ; capabilities = []
  ; current_task
  ; session_bound_at = "2026-11-05T00:00:00Z"
  ; last_seen
  ; meta = None
  }
;;

(* The observer is global, so the recording one is installed under a protect
   and the default no-op goes back in afterwards. *)
let with_recorded_observer f =
  let calls = ref [] in
  Fun.protect
    ~finally:(fun () ->
      Workspace_agent_record.install_rows_changed_observer (fun _ -> ()))
    (fun () ->
      Workspace_agent_record.install_rows_changed_observer
        (fun config -> calls := config.base_path :: !calls);
      f (fun () -> List.rev !calls))
;;

let test_write_reports_what_the_roster_draws () =
  with_recorded_observer (fun bases ->
      let call_count () = List.length (bases ()) in
      with_workspace (fun config ->
          let path =
            Filename.concat (Workspace.agents_dir config) "gemini-1.json"
          in
          (* The record's first appearance puts a row on the roster. *)
          Workspace_agent_record.write config path ~previous:None (agent "gemini-1");
          check int "a new record reports" 1 (call_count ());
          (* A heartbeat moves last_seen and nothing the roster draws. *)
          Workspace_agent_record.write config path
            ~previous:(Some (agent "gemini-1"))
            (agent "gemini-1" ~last_seen:"2026-11-05T01:05:00Z");
          check int "a heartbeat does not report" 1 (call_count ());
          (* A Task the row shows is a roster change. *)
          Workspace_agent_record.write config path
            ~previous:(Some (agent "gemini-1"))
            (agent "gemini-1" ~current_task:(Some "task-845"));
          check int "a Task reports" 2 (call_count ());
          (* Inactive takes the row off the roster. *)
          Workspace_agent_record.write config path
            ~previous:(Some (agent "gemini-1" ~current_task:(Some "task-845")))
            (agent "gemini-1" ~status:Masc_domain.Inactive);
          check int "the end of a session reports" 3 (call_count ());
          (* A record that starts Inactive is never drawn, so its first
             write reports nothing. *)
          Workspace_agent_record.write config path ~previous:None
            (agent "leftover-2" ~status:Masc_domain.Inactive);
          check int "a first write that is not drawn reports" 3 (call_count ());
          (* A name the workspace state lists (or stops listing) changes
             the roster without a record write of its own. *)
          Workspace_agent_record.report_roster_changed config;
          check int "a roster prune reports" 4 (call_count ())))
;;

let test_the_report_names_the_workspace () =
  with_recorded_observer (fun bases ->
      with_workspace (fun config ->
          (* The announcement is per workspace: the observer is handed the
             config of the write, so a reader of one workspace never wakes
             for another's roster. *)
          Workspace_agent_record.report_roster_changed config;
          (match bases () with
           | [ base ] -> check string "the workspace is the one written" config.base_path base
           | _ -> fail "one prune reports once")))
;;

let test_signal_change_keeps_roster_contract_and_committed_record () =
  with_recorded_observer (fun bases -> with_workspace (fun config ->
    let path = Filename.concat (Workspace.agents_dir config) "gemini-signal.json" in
    let first = agent "gemini-signal" in
    Workspace_agent_record.write config path ~previous:None first;
    let changes = ref [] in
    let unsubscribe = Workspace_agent_record.subscribe_signal_changed (fun change ->
      changes := change :: !changes) in
    let failures = Workspace_agent_record.signal_observer_failures () in
    let unsubscribe_bad = Workspace_agent_record.subscribe_signal_changed
        (fun _ -> raise (Failure "isolated observation failure")) in
    Fun.protect ~finally:(fun () -> unsubscribe (); unsubscribe_bad ()) (fun () ->
      let heartbeat = { first with last_seen = "2026-11-05T01:05:00Z" } in
      (match Workspace_agent_record.write_commit_result config path
          ~previous:(Some first) heartbeat with
       | Ok _ -> () | Error error -> fail error);
      check int "heartbeat leaves the Clients roster unchanged" 1 (List.length (bases ()));
      (match !changes with
       | [change] ->
           check string "original agent identity" first.name change.agent_name;
           check string "writer root is canonical before the append"
             (Fs_compat.realpath_lenient (Workspace.masc_dir config)) change.canonical_masc_root
       | _ -> fail "one heartbeat owes one source observation");
      check int "a bad listener cannot replace a committed write" (failures + 1)
        (Workspace_agent_record.signal_observer_failures ());
      Workspace_agent_record.write config path ~previous:(Some heartbeat) heartbeat;
      check int "an identical reconcile is not a new signal" 1 (List.length !changes);
      unsubscribe ();
      Workspace_agent_record.write config path ~previous:(Some heartbeat)
        { heartbeat with capabilities = ["review"] };
      check int "released listener is no longer invoked" 1 (List.length !changes))))
;;

let () =
  run "workspace agent record"
    [ ( "row"
      , [ test_case "reports what the roster draws" `Quick
            test_write_reports_what_the_roster_draws
        ; test_case "the report names the workspace" `Quick
            test_the_report_names_the_workspace
        ; test_case "source signal preserves the roster and write outcome" `Quick
            test_signal_change_keeps_roster_contract_and_committed_record
        ] )
    ]
;;
