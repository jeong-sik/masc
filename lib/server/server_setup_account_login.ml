module Http = Http_server_eio
module Session = Runtime_setup_login_session
module Client = Runtime_setup_login_client
module Receipt = Runtime_setup_login_receipt
let ( let* ) = Result.bind
let prefix = "/api/v1/setup/accounts/login/"

let respond ~status ~request reqd message =
  Http.Response.json_value ~status ~request ~extra_headers:["cache-control", "no-store"]
    (`Assoc ["error", `String message]) reqd

let parse body =
  try
    match Yojson.Safe.from_string body with
    | `Assoc fields when List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields))
      && List.for_all (fun (key, _) -> List.mem key ["integration_id"; "account_ref"]) fields ->
      (match List.assoc_opt "integration_id" fields, List.assoc_opt "account_ref" fields with
       | Some (`String integration_id), reference when String.trim integration_id <> "" ->
         let* reference = match reference with
           | None -> Ok None
           | Some (`String value) -> Runtime_setup_accounts.reference_of_string value
               |> Result.map Option.some |> Result.map_error Runtime_setup_accounts.error_message
           | Some _ -> Error "account_ref must be an account reference." in
         Ok (integration_id, reference)
       | _ -> Error "integration_id is required.")
    | _ -> Error "Expected integration_id and an optional account_ref."
  with Yojson.Json_error _ -> Error "Invalid login request."

let session_status = function
  | Session.Already_running | Not_running | Input_pending -> `Conflict
  | Not_found -> `Not_found
  | Invalid_input -> `Bad_request
  | Cancelled | Transport_failed | Process_failed _ -> `Bad_gateway

let receipt_failure = "The private login recovery record could not be saved."

let start ~actor ~base_path ~body request reqd =
  let prepared =
    let* integration_id, reference = parse body in
    let* client, cli_path = Server_runtime_setup_actions.login_target ~base_path ~integration_id
      |> Result.map_error Server_runtime_setup_actions.error_message in
    let* existing = match reference with
      | None -> Ok None
      | Some reference -> Runtime_setup_accounts.resolve ~workspace:base_path ~integration_id ~cli_path reference
          |> Result.map Option.some |> Result.map_error Runtime_setup_accounts.error_message in
    Ok (integration_id, client, cli_path, reference, existing)
  in
  match prepared, Eio_context.get_env_opt () with
  | Error message, _ -> respond ~status:`Bad_request ~request reqd message
  | Ok _, None -> respond ~status:`Service_unavailable ~request reqd "Login requires the server process environment."
  | Ok (integration_id, client, cli_path, reference, existing), Some env ->
    let account_key = match existing with
      | None -> Auth.generate_token ()
      | Some (Runtime_setup_accounts.Native_home {account_home}) -> Unix.realpath account_home
      | Some (Runtime_setup_accounts.Antigravity_account {credential_file; _}) -> Unix.realpath credential_file in
    let result = Session.with_session ~workspace:base_path ~actor ~account_key (fun session ->
      let prepared =
        let* home = Client.prepare ~runtime_root:(Common.masc_dir_from_base_path ~base_path)
          ~account_id:(Session.id session) ~client ~existing in
        let* () = match client, existing with
          | Client.Antigravity, Some _ -> Ok ()
          | (Codex | Claude | Muse | Antigravity), _ ->
            Session.bind_account session ~account_key:(Unix.realpath (Client.home_dir home))
            |> Result.map_error Session.error_message in
        let* child_env = Client.environment home in
        let* reference = match client with
          | Client.Antigravity -> Ok reference
          | Codex | Claude | Muse -> Client.publish ~workspace:base_path ~integration_id ~cli_path home
              |> Result.map Option.some in
        let receipt = { Receipt.login_id = Session.id session; integration_id;
          account_ref = reference; status = Receipt.Running } in
        let* () = Receipt.save ~workspace:base_path ~actor receipt
          |> Result.map_error (fun _ -> receipt_failure) in
        Ok (home, child_env, receipt) in
      match prepared with
      | Error _ -> respond ~status:`Service_unavailable ~request reqd
          "The private login account could not be prepared."; Ok ()
      | Ok (home, child_env, initial_receipt) ->
        let receipt = ref initial_receipt in
        let headers = Httpun.Headers.of_list
          (["content-type", "text/event-stream"; "cache-control", "no-store";
            "connection", "close"; "x-accel-buffering", "no"]
            @ Server_auth.cors_headers (Server_auth.get_origin request)) in
        let writer = Httpun.Reqd.respond_with_streaming reqd (Httpun.Response.create ~headers `OK) in
        let is_closed () = Httpun.Body.Writer.is_closed writer in
        let send event json =
          if not (is_closed ()) then (
            Httpun.Body.Writer.write_string writer
              ("event: " ^ event ^ "\ndata: " ^ Yojson.Safe.to_string json ^ "\n\n");
            Httpun.Body.Writer.flush writer (fun _ -> ())) in
        let save next = Eio.Cancel.protect (fun () ->
          let* () = Receipt.save ~workspace:base_path ~actor next
            |> Result.map_error (fun _ -> receipt_failure) in
          receipt := next; Ok ()) in
        let observe () =
          let clock = Eio.Stdenv.clock env in
          let mgr = Posix_spawn_process_mgr.foreground_mgr ~clock
            ~grace_seconds:Process_eio.child_exit_grace_seconds in
          Client.observe ~mgr ~clock
            ~cwd:Eio.Path.(Eio.Stdenv.fs env / Client.home_dir home) ~cli_path home in
        let recover status =
          (* A cancelled CLI may already have saved its selected credential. Only
             Antigravity needs capture: native homes were published before spawn.
             Capturing here makes no successful-login or invocation claim. *)
          let account_ref = match client with
            | Client.Codex | Claude | Muse -> !receipt.account_ref
            | Antigravity ->
              (match observe () with
               | Error _ -> !receipt.account_ref
               | Ok _ ->
                 match Client.publish ~workspace:base_path ~integration_id ~cli_path home with
                 | Ok reference -> Some reference
                 | Error _ -> !receipt.account_ref) in
          save { !receipt with account_ref; status } in
        Fun.protect ~finally:(fun () -> Httpun.Body.Writer.close writer) (fun () ->
          let on_ready () = send "started" (Receipt.to_json !receipt) in
          let on_output stream text = send "output" (`Assoc ["stream", `String stream; "text", `String text]) in
          let on_input_ready () = send "input_ready" (`Assoc []) in
          let completed =
            try
              Session.monitor session ~env ~is_closed (fun () ->
                let* () = Session.run session ~env ~child_env ~cwd:(Client.home_dir home)
                  ~argv:(Client.argv ~cli_path home) ~terminal:(Client.is_pty home)
                  ~is_closed ~on_ready ~on_output ~on_input_ready
                  |> Result.map_error (fun error ->
                    let status = match error with
                      | Session.Cancelled -> Receipt.Cancelled
                      | Already_running | Not_found | Not_running | Input_pending
                      | Invalid_input | Transport_failed | Process_failed _ -> Receipt.Failed in
                    status, Session.error_message error) in
                let* observed = observe () |> Result.map_error (fun _ ->
                  Receipt.Failed, "The official client did not confirm the selected account. Retry login or verify the account.") in
                let* reference = Client.publish ~workspace:base_path ~integration_id ~cli_path home
                  |> Result.map_error (fun _ -> Receipt.Failed, "The selected account could not be published. Retry account recovery.") in
                save { !receipt with account_ref = Some reference; status = Receipt.Complete observed }
                |> Result.map_error (fun message -> Receipt.Failed, message))
            with Eio.Cancel.Cancelled _ as exn ->
              Eio.Cancel.protect (fun () ->
                match !receipt.status with
                | Receipt.Complete _ -> ()
                | Running | Failed | Cancelled | Interrupted ->
                  (match recover Receipt.Interrupted with
                   | Ok () -> ()
                   | Error _ -> Log.Server.warn "Setup login interruption receipt could not be saved"));
              raise exn in
          (match !receipt.status, completed with
           | Receipt.Complete _, _ ->
             Log.Server.info "Setup login %s completed" (Session.id session);
             send "complete" (Receipt.to_json !receipt)
           | (Running | Failed | Cancelled | Interrupted), outcome ->
             let status, message = match outcome with
               | Error Session.Cancelled -> Receipt.Cancelled, Session.error_message Session.Cancelled
               | Error error -> Receipt.Failed, Session.error_message error
               | Ok (Error (status, message)) -> status, message
               | Ok (Ok ()) -> Receipt.Failed, receipt_failure in
             let recovered = Eio.Cancel.protect (fun () -> recover status) in
             let message = match recovered with Ok () -> message | Error _ -> receipt_failure in
             Log.Server.info "Setup login %s did not complete" (Session.id session);
             let fields = match Receipt.to_json !receipt with `Assoc fields -> fields | _ -> [] in
             send "error" (`Assoc (("message", `String message) :: fields)));
          Ok ())) in
    (match result with
     | Ok () -> ()
     | Error error -> respond ~status:(session_status error) ~request reqd (Session.error_message error))

let status ~actor ~base_path request reqd =
  let path = Uri.path (Uri.of_string request.Httpun.Request.target) in
  let result = match Server_utils.extract_path_param ~prefix path with
    | None -> Error Receipt.Not_found
    | Some login_id -> Receipt.load ~workspace:base_path ~actor ~login_id in
  match result with
  | Error Receipt.Not_found -> respond ~status:`Not_found ~request reqd "This login session is not available in this workspace."
  | Error Unavailable -> respond ~status:`Service_unavailable ~request reqd receipt_failure
  | Ok receipt ->
    let receipt = match receipt.status with
      | Receipt.Running when not (Session.is_active ~workspace:base_path ~actor ~login_id:receipt.login_id) ->
        {receipt with status = Receipt.Interrupted}
      | Running | Complete _ | Failed | Cancelled | Interrupted -> receipt in
    Http.Response.json_value ~request ~extra_headers:["cache-control", "no-store"]
      (Receipt.to_json receipt) reqd

let control ~actor ~base_path ~body request reqd =
  let path = Uri.path (Uri.of_string request.Httpun.Request.target) in
  let suffix = Server_utils.extract_path_param ~prefix path in
  let result = match suffix with
    | Some suffix ->
      (match String.split_on_char '/' suffix with
       | [login_id; "input"] ->
         let* input = try Session.input_of_json (Yojson.Safe.from_string body)
           with Yojson.Json_error _ -> Error Session.Invalid_input in
         Session.submit ~workspace:base_path ~actor ~login_id input
       | [login_id; "cancel"] ->
         let empty = if body = "" then true else
           try match Yojson.Safe.from_string body with `Assoc [] -> true | _ -> false
           with Yojson.Json_error _ -> false in
         if empty then Session.cancel ~workspace:base_path ~actor ~login_id
         else Error Session.Invalid_input
       | _ -> Error Session.Invalid_input)
    | None -> Error Session.Invalid_input in
  match result with
  | Ok () -> Http.Response.json_value ~status:`Accepted ~request (`Assoc ["accepted", `Bool true]) reqd
  | Error error -> respond ~status:(session_status error) ~request reqd (Session.error_message error)
