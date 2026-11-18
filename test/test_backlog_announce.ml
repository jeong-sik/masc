(* RFC an-idle-tui-receives-only-changes-it-draws §4.1 E2: a backlog commit
   tells its workspace's readers as [Backlog], and only its own workspace. *)

open Alcotest
open Masc

let ok_or_fail = function
  | Ok value -> value
  | Error detail -> fail detail
;;

let test_backlog_commit_announces () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Unix.realpath (Filename.temp_dir "backlog-announce-" "") in
  Fun.protect
    ~finally:(fun () ->
      Workspace_backlog.install_committed_observer (fun ~base_path:_ -> ());
      Fs_compat.remove_tree base_path)
    (fun () ->
      let config = Workspace.default_config base_path in
      ignore (Workspace.init config ~agent_name:None);
      Workspace_dataset_event.install_store_observers ();
      let heard = ref 0 in
      let id = "backlog-announce" in
      Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
        ~callback:(fun (event : Sse.external_event) ->
          match event.ext_payload with
          | `Assoc fields
            when Json_util.assoc_string_opt "type" event.ext_payload
                 = Some Workspace_dataset_event.event_type ->
            (match Workspace_dataset_event.of_fields fields with
             | Ok Workspace_dataset_event.Backlog -> incr heard
             | Ok _ | Error _ -> ())
          | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> ())
        ();
      Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
        let backlog = ok_or_fail (Workspace_backlog.read_backlog_r config) in
        let before = !heard in
        let (_ : Workspace_backlog.write_backlog_outcome) =
          ok_or_fail (Workspace_backlog.write_backlog_result config backlog) in
        check int "a backlog commit announces Backlog once" (before + 1) !heard;
        ok_or_fail (Workspace_backlog.repair_backlog_copies_result config
          (ok_or_fail (Workspace_backlog.read_backlog_r config)));
        check int "a repair commit announces Backlog too" (before + 2) !heard))
;;

let () =
  run "backlog_announce"
    [ "commit", [ test_case "backlog commits announce" `Quick test_backlog_commit_announces ] ]
;;
