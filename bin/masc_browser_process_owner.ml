let () =
  let parse = function
    | "--instance"::instance_id::"--"::command when command<>[] -> Ok (instance_id,command)
    | _ -> Error "usage: masc-browser-process-owner --instance ID -- ABSOLUTE_BROWSER [ARG ...]" in
  let arguments=List.tl (Array.to_list Sys.argv) in
  match parse arguments with
  | Error message -> prerr_endline message;exit 1
  | Ok (instance_id,command) ->
    Eio_main.run (fun env ->
      (* The existing Stagehand process cleanup grants 5 s before group KILL. *)
      match Browser_process_owner.run ~env ~instance_id ~command ~grace_seconds:5.
        ~on_ready:(fun receipt -> Eio.Flow.copy_string
          (Yojson.Safe.to_string (Browser_process_owner.ready_to_json receipt) ^ "\n") (Eio.Stdenv.stdout env)) with
      | Ok () -> ()
      | Error error -> prerr_endline (Browser_process_owner.error_to_string error);exit 1)
