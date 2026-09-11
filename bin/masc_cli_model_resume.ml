type outcome = Resumed of { exact_output_available : bool } | Refused of string

let response ~status body =
  match status with
  | 401 | 403 -> Refused "Local operator access was rejected. Sign in again and resume setup."
  | 404 -> Refused "This running server needs an upgrade before model setup can resume. Restart this workspace with the installed MASC version."
  | 200 ->
    let decoded = try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None in
    let one key fields = match List.filter (fun (name, _) -> name = key) fields with
      | [(_, value)] -> Some value | _ -> None in
    (match decoded with
     | Some (`Assoc fields) ->
       (match one "runtime_ready" fields, one "exact_output_authority_available" fields,
              one "model_setup" fields with
        | Some (`Bool true), Some (`Bool exact_output_available), Some (`Assoc setup)
            when one "status" setup = Some (`String "available") -> Resumed {exact_output_available}
        | _ -> Refused "The server did not confirm that model setup resumed. Retry setup.")
     | _ -> Refused "The server returned an unreadable model setup result.")
  | _ -> Refused "Saved model settings could not be activated. Review the selected connection and retry setup."

let run ~base_path ~port ~agent =
  try
    let base_path = Unix.realpath base_path in
    let outcome = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      Eio_context.set_env env;
      Eio_context.set_switch sw;
      Eio_context.set_net (Eio.Stdenv.net env);
      Eio_context.set_clock (Eio.Stdenv.clock env);
      Masc_http_client.with_scoped_pool ~sw ~env (fun () ->
        let clock = Eio.Stdenv.clock env in
        let origin = Printf.sprintf "http://127.0.0.1:%d" port in
        (* Validate the workspace before sending its private operator token. *)
        match Masc_http_client.get_sync ~clock ~url:(origin ^ "/health?full=1") ~headers:[] () with
        | Ok (200, health) when Masc_cli_setup.health_state ~base_path health ->
          (match Auth_login.read_persisted_token ~base_path ~agent_name:agent with
           | None -> Refused "Local operator sign-in is missing. Complete sign-in before resuming setup."
           | Some token ->
             let headers = ["authorization", "Bearer " ^ token; "x-masc-agent", agent;
                            "content-type", "application/json"] in
             match Masc_http_client.post_sync ~clock ~url:(origin ^ "/api/v1/runtime/setup/resume")
                     ~headers ~body:"{}" () with
             | Error _ -> Refused "The workspace server did not answer. Retry when it is running."
             | Ok (status, body) -> response ~status body)
        | _ -> Refused "The workspace server is not ready. Retry when workspace preparation finishes."))) in
    match outcome with
    | Resumed {exact_output_available} ->
      print_endline "The running workspace has loaded your saved model settings.";
      if not exact_output_available then
        print_endline "Conversation is available; task completion verification still needs its model authority settings.";
      0
    | Refused message -> prerr_endline message; 1
  with
  | Masc_cli_setup.Setup_error message -> prerr_endline message; 1
  | Unix.Unix_error _ | Sys_error _ -> prerr_endline "The selected workspace cannot be read. Check its location and permissions."; 1
