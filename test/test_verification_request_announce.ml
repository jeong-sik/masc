(* RFC-0480 §3.4: the verification request store tells its workspace's
   readers when a request file is written or removed. *)

open Alcotest
open Masc

let ok_or_fail = function
  | Ok value -> value
  | Error detail -> fail detail
;;

let test_writes_and_removals_announce () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Unix.realpath (Filename.temp_dir "verification-announce-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    ignore (Workspace.init (Workspace.default_config base_path) ~agent_name:None);
    let heard = ref 0 in
    let id = "verification-request-announce" in
    Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
      ~callback:(fun (event : Sse.external_event) ->
        match Json_util.assoc_string_opt "type" event.ext_payload with
        | Some kind when String.equal kind Workspace_dataset_event.event_type ->
          (match event.ext_payload with
           | `Assoc fields ->
             (match Workspace_dataset_event.of_fields fields with
              | Ok Workspace_dataset_event.Verification_requests -> incr heard
              | Ok _ | Error _ -> ())
           | _ -> ())
        | Some _ | None -> ())
      ();
    Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
      let request =
        ok_or_fail
          (Verification.create_request ~base_path ~task_id:"task-announce" ~output:(`Assoc [])
             ~criteria:[] ~worker:"producer" ())
      in
      check int "a written request announces" 1 !heard;
      ok_or_fail (Verification.delete_request base_path request.Verification.id);
      check int "a removed request announces" 2 !heard;
      ok_or_fail (Verification.delete_request base_path request.Verification.id);
      check int "removing a request that is gone announces nothing" 2 !heard))
;;

let test_typed_commit_refreshes_cached_reader () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Unix.realpath (Filename.temp_dir "verification-typed-commit-" "") in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let changes = ref [] in
    let unsubscribe = Dashboard_observation_commit.subscribe (function
      | Dashboard_observation_commit.Workspace { base_path; payload } when payload.topic = `Verification_requests ->
        changes := (base_path, payload.scope) :: !changes
      | Dashboard_observation_commit.Workspace _ | Dashboard_observation_commit.Process _ -> ()) in
    Fun.protect ~finally:unsubscribe (fun () ->
      let create output = Verification.create_request ~base_path ~request_id:"typed-cache-request"
          ~task_id:"task-observed" ~output:(`String output) ~criteria:[] ~worker:"producer" () |> ok_or_fail in
      let listing = Verification.listing ~project:(fun request -> Ok request.Verification.output) () in
      let request = create "old" in
      let read () = (Verification.list_projected listing base_path |> ok_or_fail).readable in
      check bool "first committed reader result" true (read () = [`String "old"]);
      ignore (create "new");
      check int "create and replacement notify" 2 (List.length !changes);
      check bool "a notified reader cannot retain the preceding projection" true (read () = [`String "new"]);
      ok_or_fail (Verification.delete_request base_path request.id);
      check int "removal notifies" 3 (List.length !changes);
      check bool "reader sees removal" true (read () = []);
      ok_or_fail (Verification.delete_request base_path request.id);
      check int "an absent request is no write notification" 3 (List.length !changes);
      check bool "notification retains workspace authority" true
        (List.for_all (fun (source, scope) -> String.equal source base_path && scope = `Workspace) !changes)))
;;

let () =
  run "verification_request_announce"
    [ ( "store"
      , [ test_case "writes and removals announce" `Quick test_writes_and_removals_announce
        ; test_case "typed commits refresh a cached reader" `Quick test_typed_commit_refreshes_cached_reader ] )
    ]
;;
