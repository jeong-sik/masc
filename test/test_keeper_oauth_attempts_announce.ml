(* RFC-0480 §3.4: a Keeper's OAuth login attempt change tells its workspace's
   readers, naming the Keeper only. *)

open Alcotest
open Masc

let check = Alcotest.check

(* The dataset events a subscriber of [base_path]'s runtime hears, newest
   first, as their fields. *)
let with_dataset_events ~base_path ~id f =
  let heard = ref [] in
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
  Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () -> f heard)

let with_workspace f =
  let base_path = Unix.realpath (Filename.temp_dir "keeper-oauth-announce-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    ignore (Workspace.init (Workspace.default_config base_path) ~agent_name:None);
    f base_path)

(* An announcement reaches the readers of the workspace it names and no other
   workspace's, and carries the Keeper. *)
let test_event_names_only_the_keeper () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  with_workspace @@ fun base_path ->
  with_workspace @@ fun elsewhere ->
  with_dataset_events ~base_path ~id:"keeper-oauth-announce-named" @@ fun heard ->
  with_dataset_events ~base_path:elsewhere ~id:"keeper-oauth-announce-elsewhere"
  @@ fun heard_elsewhere ->
  Workspace_dataset_event.announce ~base_path
    (Workspace_dataset_event.Keeper_oauth_attempts { keeper = "largo" });
  check int "another workspace's readers hear nothing" 0 (List.length !heard_elsewhere);
  match !heard with
  | [ fields ] ->
    check bool "the Keeper is named" true
      (Workspace_dataset_event.of_fields fields
       = Ok (Workspace_dataset_event.Keeper_oauth_attempts { keeper = "largo" }))
  | heard -> fail (Printf.sprintf "expected one announcement, heard %d" (List.length heard))

let decoded = function
  | Ok (Workspace_dataset_event.Keeper_oauth_attempts { keeper }) ->
    Some ("keeper_oauth_attempts:" ^ keeper)
  | Ok dataset -> Some (Workspace_dataset_event.dataset_to_wire dataset)
  | Error _ -> None

let test_of_fields_reads_the_subject () =
  check (option string) "a Keeper attempt decodes with its Keeper"
    (Some "keeper_oauth_attempts:largo")
    (decoded (Workspace_dataset_event.of_fields
                [ "dataset", `String "keeper_oauth_attempts"; "keeper", `String "largo" ]));
  check (option string) "a subject dataset without its Keeper is an error" None
    (decoded (Workspace_dataset_event.of_fields
                [ "dataset", `String "keeper_oauth_attempts" ]));
  check (option string) "an unknown dataset is an error" None
    (decoded (Workspace_dataset_event.of_fields [ "dataset", `String "elsewhere" ]));
  check (option string) "a plain dataset decodes by name"
    (Some "repositories")
    (decoded (Workspace_dataset_event.of_fields [ "dataset", `String "repositories" ]))

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

let () =
  run "keeper_oauth_attempts_announce"
    [ "event", [ test_case "names only the workspace and Keeper" `Quick
                   test_event_names_only_the_keeper ]
    ; "decode", [ test_case "reads the subject beside the name" `Quick
                    test_of_fields_reads_the_subject ]
    ; "attempts", [ test_case "a change announces only its Keeper" `Quick
                      test_an_attempt_change_announces_only_its_keeper ]
    ]
