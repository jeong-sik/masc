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
        match
          ( Json_util.assoc_string_opt "type" event.ext_payload
          , Json_util.assoc_string_opt "dataset" event.ext_payload )
        with
        | Some kind, Some wire
          when String.equal kind Workspace_dataset_event.event_type
               && Option.equal
                    (fun (a : Workspace_dataset_event.dataset) b -> a = b)
                    (Workspace_dataset_event.dataset_of_wire wire)
                    (Some Workspace_dataset_event.Verification_requests) ->
          incr heard
        | (Some _ | None), (Some _ | None) -> ())
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

let () =
  run "verification_request_announce"
    [ ( "store"
      , [ test_case "writes and removals announce" `Quick test_writes_and_removals_announce ] )
    ]
;;
