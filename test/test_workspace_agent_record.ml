(* RFC-0480 §3.4: an agent record write reports a change of what the Clients
   roster draws for it, and stays quiet when only [last_seen] moved. *)

open Alcotest
open Masc

let agent ?(status = Masc_domain.Active) ?current_task ?(last_seen = "2026-11-04T00:00:00Z")
    name : Masc_domain.agent =
  { id = None
  ; name
  ; agent_type = "codex"
  ; status
  ; capabilities = []
  ; current_task
  ; session_bound_at = "2026-11-04T00:00:00Z"
  ; last_seen
  ; meta = None
  }

let test_only_a_drawn_change_is_reported () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Unix.realpath (Filename.temp_dir "agent-record-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let config = Workspace.default_config base_path in
    ignore (Workspace.init config ~agent_name:None);
    let reports = ref 0 in
    Workspace_agent_record.install_rows_changed_observer (fun _ -> incr reports);
    Fun.protect
      ~finally:(fun () -> Workspace_agent_record.install_rows_changed_observer (fun _ -> ()))
      (fun () ->
        let path = Filename.concat base_path "codex-fixture.json" in
        let first = agent "codex-fixture" in
        Workspace_agent_record.write config path ~previous:None first;
        check int "a new record is reported" 1 !reports;
        let beat = { first with last_seen = "2026-11-04T00:00:30Z" } in
        Workspace_agent_record.write config path ~previous:(Some first) beat;
        check int "a heartbeat is not" 1 !reports;
        let claimed = { beat with current_task = Some "task-1" } in
        Workspace_agent_record.write config path ~previous:(Some beat) claimed;
        check int "a claimed Task is" 2 !reports;
        let ended = { claimed with status = Masc_domain.Inactive } in
        Workspace_agent_record.write config path ~previous:(Some claimed) ended;
        check int "an ended session leaves the roster" 3 !reports;
        Workspace_agent_record.write config path ~previous:(Some ended)
          { ended with last_seen = "2026-11-04T00:01:00Z" };
        check int "an inactive record that moves stays unlisted" 3 !reports))
;;

let () =
  run "workspace_agent_record"
    [ ( "roster"
      , [ test_case "only a drawn change is reported" `Quick
            test_only_a_drawn_change_is_reported ] )
    ]
;;
