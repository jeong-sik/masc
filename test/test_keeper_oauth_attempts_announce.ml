(* RFC-0480 §3.4: a Keeper's OAuth login attempt change tells its workspace's
   readers, naming the Keeper only. *)

open Alcotest
open Masc

let check = Alcotest.check

(* The event carries the dataset, the Keeper it belongs to and a timestamp:
   no provider, attempt id, state, code, verifier or consent URL. *)
let test_event_names_only_the_keeper () =
  let heard = ref [] in
  let base_path = "/tmp/oauth-attempts-announce" in
  Fun.protect
    ~finally:(fun () -> Keeper_oauth_pending.install_change_observer (fun ~base_path:_ ~keeper:_ -> ()))
    (fun () ->
      Keeper_oauth_pending.install_change_observer (fun ~base_path:seen ~keeper:seen_keeper ->
        heard := (seen, seen_keeper) :: !heard);
      Workspace_dataset_event.announce ~base_path
        (Workspace_dataset_event.Keeper_oauth_attempts { keeper = "largo" });
      let (seen_base, seen_keeper) = List.hd !heard in
      check string "the workspace is the one announced" base_path seen_base;
      check string "the Keeper is named" "largo" seen_keeper;
      check int "one announcement" 1 (List.length !heard))
;;

(* The dataset type has no Alcotest module of its own; the wire name and,
   for a Keeper's attempts, the Keeper identify the decoded value. *)
let decoded = function
  | Ok (Workspace_dataset_event.Keeper_oauth_attempts { keeper }) ->
    Some ("keeper_oauth_attempts:" ^ keeper)
  | Ok dataset -> Some (Workspace_dataset_event.dataset_to_wire dataset)
  | Error _ -> None
;;

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
;;


let () =
  run "keeper_oauth_attempts_announce"
    [ "event", [ test_case "names only the workspace and Keeper" `Quick
                   test_event_names_only_the_keeper ]
    ; "decode", [ test_case "reads the subject beside the name" `Quick
                    test_of_fields_reads_the_subject ]
    ]
;;
