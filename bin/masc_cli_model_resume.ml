type outcome = Resumed of { exact_output_available : bool } | Refused of string

let bounded_cause_max_bytes = 240

let bounded_cause text =
  if String.length text <= bounded_cause_max_bytes then text
  else String_util.utf8_prefix ~max_bytes:bounded_cause_max_bytes text ^ "..."

let response ~status body =
  let decoded = try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None in
  let one key fields = match List.filter (fun (name, _) -> name = key) fields with
    | [(_, value)] -> Some value | _ -> None in
  let server_error () =
    match decoded with
    | Some (`Assoc fields) ->
      (match one "error" fields with
       | Some (`String raw) ->
         let cleaned = String.trim (Masc.Tui_terminal_text.sanitize_terminal_text raw) in
         if cleaned = "" then None else Some (bounded_cause cleaned)
       | _ -> None)
    | _ -> None in
  match status with
  | 401 | 403 -> Refused "Local operator access was rejected. Sign in again and resume setup."
  | 404 -> Refused "This running server needs an upgrade before model setup can resume. Restart this workspace with the installed MASC version."
  | 200 ->
    (match decoded with
     | Some (`Assoc fields) ->
       (match one "runtime_ready" fields, one "exact_output_authority_available" fields,
              one "model_setup" fields with
        | Some (`Bool true), Some (`Bool exact_output_available), Some (`Assoc setup)
            when one "status" setup = Some (`String "available") -> Resumed {exact_output_available}
        | _ -> Refused "The server did not confirm that model setup resumed. Retry setup.")
     | _ -> Refused "The server returned an unreadable model setup result.")
  | _ ->
    let fallback = "Saved model settings could not be activated. Review the selected connection and retry setup." in
    Refused (match server_error () with None -> fallback | Some cause -> fallback ^ " " ^ cause)

module Upgrade = Server_upgrade_preparation

(* HIGH-RISK-UNREVIEWED: the private operator token goes only to the server
   of a single user that the kernel names as lease owner of [base_path] and
   announcer of [port], asked again right before the POST. The port is read
   without credentials only for [/health/ready]. *)
let resume ~clock ~base_path ~port ~agent =
  let refused_with tail sentence = Refused (sentence ^ tail) in
  let not_sent = " The saved model settings were not sent." in
  let root = (Host_config.host ()).base_path_lease_root in
  let lease_dir = Upgrade.lease_directory root ~base_path in
  match Upgrade.owner_without_making root ~base_path ~port with
  | Error unread ->
    Refused (Printf.sprintf "The owner of %s could not be checked (%s). The saved model settings \
                             were not sent." base_path
               (Server_startup_takeover.owner_capture_error_to_string unread))
  | Ok Upgrade.Unowned ->
    Refused (Printf.sprintf "%s No server can load the saved model settings. Start it with masc \
                             start --base-path %s --port %d and run this again."
               (Upgrade.owner_sentence ~lease_dir ~base_path ~port Upgrade.Unowned)
               (Filename.quote base_path) port)
  | Ok (Upgrade.Single_user_server_here server) ->
    let origin = Masc_network_defaults.masc_http_loopback_origin ~port in
    (match Masc_http_client.get_sync ~clock ~timeout_sec:Masc_http_client.default_request_timeout_sec
             ~url:(origin ^ Server_health_paths.readiness) ~headers:[] () with
     | Ok (200, (_ : string)) ->
       (match Auth_login.read_persisted_http_token ~base_path ~agent_name:agent with
        | None -> Refused "Local operator sign-in is missing. Complete sign-in before resuming setup."
        | Some token ->
          (match Upgrade.confirm server with
           | Error departure ->
             refused_with not_sent (Upgrade.departure_sentence server departure)
           | Ok () ->
             let headers = ["authorization", "Bearer " ^ token; "x-masc-agent", agent;
                            "content-type", "application/json"] in
             match Masc_http_client.post_sync ~clock ~url:(origin ^ "/api/v1/runtime/setup/resume")
                     ~headers ~body:"{}" () with
             | Error _ -> Refused "The workspace server did not answer. Retry when it is running."
             | Ok (status, body) -> response ~status body))
     | Ok ((_ : int), (_ : string)) ->
       Refused "The workspace server is not ready. Retry when workspace preparation finishes."
     | Error (_ : string) ->
       Refused (Printf.sprintf "The server of %s (pid %d) announces port %d and does not answer \
                                there. Retry when it is running." base_path
                  (Upgrade.single_user_server_pid server) port))
  | Ok ((Upgrade.Single_user_server_elsewhere _ | Upgrade.Account_server_here _
        | Upgrade.Account_server_elsewhere _ | Upgrade.Owner_unannounced _) as owner) ->
    refused_with not_sent (Upgrade.owner_sentence ~lease_dir ~base_path ~port owner)

let run ~base_path ~port ~agent =
  try
    let base_path = Unix.realpath base_path in
    let outcome = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
      Eio_context.set_env env;
      Eio_context.set_switch sw;
      Eio_context.set_net (Eio.Stdenv.net env);
      Eio_context.set_clock (Eio.Stdenv.clock env);
      Masc_http_client.with_scoped_pool ~sw ~env (fun () ->
        resume ~clock:(Eio.Stdenv.clock env) ~base_path ~port ~agent))) in
    match outcome with
    | Resumed {exact_output_available} ->
      print_endline "The running workspace has loaded your saved model settings.";
      if not exact_output_available then
        print_endline "Conversation is available; task completion verification still needs its model authority settings.";
      0
    | Refused message -> prerr_endline message; 1
  with
  | Unix.Unix_error _ | Sys_error _ -> prerr_endline "The selected workspace cannot be read. Check its location and permissions."; 1
