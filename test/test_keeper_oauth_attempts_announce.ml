(* RFC-0480 §3.4: a change to a Keeper's OAuth login attempts tells its
   workspace's readers whose attempts to read again, and nothing more. *)

open Alcotest
open Masc

let test_an_attempt_change_announces_only_its_keeper () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Unix.realpath (Filename.temp_dir "keeper-oauth-announce-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let config = Workspace.default_config base_path in
    ignore (Workspace.init config ~agent_name:None);
    Workspace_dataset_event.install_store_observers ();
    let heard = ref [] in
    let id = "keeper-oauth-attempts-announce" in
    Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
      ~callback:(fun (event : Sse.external_event) ->
        match event.ext_payload with
        | `Assoc fields
          when Option.equal String.equal
                 (Json_util.assoc_string_opt "type" event.ext_payload)
                 (Some Workspace_dataset_event.event_type) ->
          heard := fields :: !heard
        | _ -> ())
      ();
    Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
      let table = Keeper_oauth_pending.create ~base_path () in
      (match
         Keeper_oauth_pending.retire_scope table ~keeper:"alpha" ~provider_id:"atlassian"
           ~local_delete:(fun () -> Ok ())
       with
       | Ok () -> ()
       | Error detail -> fail detail);
      match !heard with
      | [ fields ] ->
        check (list string) "it carries its type, dataset, Keeper and time, nothing else"
          [ "dataset"; "keeper"; "ts_unix"; "type" ]
          (List.sort String.compare (List.map fst fields));
        check bool "it names that Keeper's attempts" true
          (Workspace_dataset_event.of_fields fields
           = Ok (Workspace_dataset_event.Keeper_oauth_attempts { keeper = "alpha" }))
      | heard -> fail (Printf.sprintf "expected one event, heard %d" (List.length heard))))
;;

let () =
  run "keeper_oauth_attempts_announce"
    [ ( "attempts"
      , [ test_case "a change announces only its Keeper" `Quick
            test_an_attempt_change_announces_only_its_keeper ] )
    ]
;;
