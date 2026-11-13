module Http = Http_server_eio
module Session = Runtime_setup_login_session
module Client = Runtime_setup_login_client
module Receipt = Runtime_setup_login_receipt
open Result.Syntax
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
  | Cancelled | Transport_failed | Process_failed _ | Interpreter_missing -> `Bad_gateway

let receipt_failure = "The private login recovery record could not be saved."
let account_failure = "The private login account could not be prepared."

let canonical_account_key path =
  try Ok (Fs_compat.realpath path) with
  | Unix.Unix_error _ | Sys_error _ -> Error account_failure

type person =
  { zone : Authz_zone.t
  ; user_id : Authz_types.User_id.t
  ; namespace : Authz_types.Account_home_namespace.t
  }

type owner =
  | Operator of { actor : string }
  | Person of person

(* The scope of the sessions and receipts of the caller. *)
let actor_of = function
  | Operator { actor } -> Session.Agent actor
  | Person { user_id; _ } -> Session.Person (Authz_types.User_id.to_string user_id)

(* The page of this server reads a person's stream from the same origin, so
   that stream names no origin it allows. The operator's stream keeps the
   headers of the single-user server. *)
let stream_cors_headers owner request =
  match owner with
  | Person (_ : person) -> []
  | Operator { actor = (_ : string) } -> Server_auth.cors_headers (Server_auth.get_origin request)

let private_child parent leaf =
  let path = Filename.concat parent leaf in
  (try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  path

(* A person's account homes go under their namespace, which the admission
   fixed (design 4.1 and 5.4), so no other person's login reaches them. The two
   directories are made from the spelling of the layout. *)
let runtime_root_of ~base_path = function
  | Operator _ -> Ok (Common.masc_dir_from_base_path ~base_path)
  | Person { namespace; _ } ->
    let root = Runtime_account_home_layout.person_runtime_root ~base_path ~namespace in
    let accounts = Filename.dirname root in
    (try
       let accounts = private_child (Filename.dirname accounts) (Filename.basename accounts) in
       Ok (private_child accounts (Filename.basename root))
     with Unix.Unix_error _ | Sys_error _ -> Error account_failure)

let person_reference_refused =
  "In multi-account mode a login makes a new account, and account_ref is not read."

type person_refusal =
  | Not_declared
  | No_login of Server_runtime_setup_actions.error
  | Copy_without_owner

let person_refusal_message = function
  | Not_declared ->
    "In multi-account mode a login is of a provider this workspace declares, and it \
     declares none of this id."
  | No_login error -> Server_runtime_setup_actions.error_message error
  | Copy_without_owner ->
    "Antigravity is not connected in multi-account mode: its credential is a copy in the \
     setup registry, which has no owner."

let person_target config ~integration_id =
  match Runtime_schema.provider_of_id config integration_id with
  | None -> Error Not_declared
  | Some (_ : Runtime_schema.provider) ->
    (match Server_runtime_setup_actions.login_target_of_config config ~integration_id with
     | Error error -> Error (No_login error)
     | Ok target ->
       (match target.Server_runtime_setup_actions.client with
        | Client.Antigravity -> Error Copy_without_owner
        | Client.Codex | Client.Claude | Client.Muse -> Ok target))

(* What a confirmed login leaves behind. An operator's account is published to
   the setup registry, from which setup selects it. A person's account is
   linked to them in the authorization log, and the registry, which has no
   owner, does not hear of it. *)
let finish owner ~base_path ~integration_id ~cli_path ~login_id home =
  match owner with
  | Operator _ ->
    Client.publish ~workspace:base_path ~integration_id ~cli_path home
    |> Result.map (fun reference -> Receipt.Published reference)
    |> Result.map_error (fun _ -> "The selected account could not be published. Retry account recovery.")
  | Person { zone; user_id; namespace = _ } ->
    let* provider_account_id =
      Authz_types.Provider_account_id.of_string login_id
      |> Result.map_error (fun _ -> account_failure) in
    Authz_provider_account.link zone ~user_id ~provider_account_id
    |> Result.map (fun () -> Receipt.Linked)
    |> Result.map_error (fun error ->
      "The account was not linked to you: " ^ Authz_provider_account.error_to_string error)

let start ~owner ~base_path ~body request reqd =
  let actor = actor_of owner in
  let prepared =
    let* integration_id, reference = parse body in
    let* config = Server_runtime_setup_actions.config ~base_path
      |> Result.map_error Server_runtime_setup_actions.error_message in
    let* target = match owner with
      | Person _ -> person_target config ~integration_id |> Result.map_error person_refusal_message
      | Operator _ ->
        Server_runtime_setup_actions.login_target_of_config config ~integration_id
        |> Result.map_error Server_runtime_setup_actions.error_message in
    let Server_runtime_setup_actions.{client; cli_path; spawn_path} = target in
    let* existing = match owner, reference with
      | (Operator _ | Person _), None -> Ok None
      | Person _, Some _ -> Error person_reference_refused
      | Operator _, Some reference -> Runtime_setup_accounts.resolve ~workspace:base_path ~integration_id ~cli_path reference
          |> Result.map Option.some |> Result.map_error Runtime_setup_accounts.error_message in
    Ok (integration_id, client, cli_path, spawn_path, reference, existing)
  in
  match prepared, Eio_context.get_env_opt () with
  | Error message, _ -> respond ~status:`Bad_request ~request reqd message
  | Ok _, None -> respond ~status:`Service_unavailable ~request reqd "Login requires the server process environment."
  | Ok (integration_id, client, cli_path, spawn_path, reference, existing), Some env ->
    let account_key = match existing with
      | None -> Ok (Auth.generate_token ())
      | Some (Runtime_setup_accounts.Native_home {account_home}) -> canonical_account_key account_home
      | Some (Runtime_setup_accounts.Antigravity_account {credential_file; _}) -> canonical_account_key credential_file in
    let result = match account_key with
    | Error message -> respond ~status:`Service_unavailable ~request reqd message; Ok ()
    | Ok account_key -> Session.with_session ~workspace:base_path ~actor ~account_key (fun session ->
      let prepared =
        let* runtime_root = runtime_root_of ~base_path owner in
        let* home = Client.prepare ~runtime_root
          ~account_id:(Session.id session) ~client ~existing in
        let* () = match client, existing with
          | Client.Antigravity, Some _ -> Ok ()
          | (Codex | Claude | Muse | Antigravity), _ ->
            let* account_key = canonical_account_key (Client.home_dir home) in
            Session.bind_account session ~account_key
            |> Result.map_error Session.error_message in
        let* child_env = Client.environment home in
        let* account = match owner, client, reference with
          | Operator _, Client.Antigravity, Some reference -> Ok (Receipt.Published reference)
          | Operator _, Client.Antigravity, None -> Ok Receipt.Unselected
          | Operator _, (Codex | Claude | Muse), (None | Some _) ->
            Client.publish ~workspace:base_path ~integration_id ~cli_path home
            |> Result.map (fun reference -> Receipt.Published reference)
          | Person _, (Client.Antigravity | Codex | Claude | Muse), (None | Some _) -> Ok Receipt.Unselected in
        let receipt = { Receipt.login_id = Session.id session; integration_id;
          account; status = Receipt.Running } in
        let* () = Receipt.save ~workspace:base_path ~actor receipt
          |> Result.map_error (fun _ -> receipt_failure) in
        Ok (home, child_env, receipt) in
      match prepared with
      | Error _ -> respond ~status:`Service_unavailable ~request reqd account_failure; Ok ()
      | Ok (home, child_env, initial_receipt) ->
        let receipt = ref initial_receipt in
        let headers = Httpun.Headers.of_list
          (["content-type", "text/event-stream"; "cache-control", "no-store";
            "connection", "close"; "x-accel-buffering", "no"]
            @ stream_cors_headers owner request) in
        let response = Server_sse_response.respond ~clock:(Eio.Stdenv.clock env)
          ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s
          reqd (Httpun.Response.create ~headers `OK) in
        let is_closed () = Server_sse_response.is_closed response in
        (* A response that did not take the frame is closed, so [is_closed]
           reports it and the login ends there. *)
        let send event json =
          match Server_sse_response.send response
            ("event: " ^ event ^ "\ndata: " ^ Yojson.Safe.to_string json ^ "\n\n") with
          | Server_sse_response.Written | Closed | Stalled -> () in
        let save next = Eio.Cancel.protect (fun () ->
          let* () = Receipt.save ~workspace:base_path ~actor next
            |> Result.map_error (fun _ -> receipt_failure) in
          receipt := next; Ok ()) in
        let observe () =
          let clock = Eio.Stdenv.clock env in
          let mgr = Posix_spawn_process_mgr.foreground_mgr ~clock
            ~grace_seconds:Process_eio.child_exit_grace_seconds in
          (* A person checks the account of their own login, which the log
             links to them only once the check is done. *)
          let* account_request = match owner with
            | Operator _ -> Ok Runtime_account_access.Operator_call
            | Person { user_id; _ } ->
              Authz_types.Provider_account_id.of_string (Session.id session)
              |> Result.map (fun provider_account_id ->
                Runtime_account_access.Own_account { user_id; provider_account_id })
              |> Result.map_error (fun _ -> account_failure) in
          Client.observe ~mgr ~clock
            ~cwd:Eio.Path.(Eio.Stdenv.fs env / Client.home_dir home) ~cli_path:spawn_path
            ~account_request home in
        let recover status =
          (* A cancelled CLI may already have saved its selected credential. Only
             Antigravity needs capture: native homes were published before spawn.
             Capturing here makes no successful-login or invocation claim. *)
          let account = match client with
            | Client.Codex | Claude | Muse -> !receipt.account
            | Antigravity ->
              (match observe () with
               | Error _ -> !receipt.account
               | Ok _ ->
                 match Client.publish ~workspace:base_path ~integration_id ~cli_path home with
                 | Ok reference -> Receipt.Published reference
                 | Error _ -> !receipt.account) in
          save { !receipt with account; status } in
        (* The official client rewrites its credential file however the login
           ends, a cancelled one included, and the models panes draw the
           account emails those files hold. *)
        let credentials_rewritten () =
          Workspace_dataset_event.announce ~base_path
            Workspace_dataset_event.Account_emails in
        Server_sse_response.close_after response (fun () ->
          let on_ready () = send "started" (Receipt.to_json !receipt) in
          let on_output stream text = send "output" (`Assoc ["stream", `String stream; "text", `String text]) in
          let on_input_ready () = send "input_ready" (`Assoc []) in
          let completed =
            try
              Session.monitor session ~env ~is_closed (fun () ->
                let* () = Session.run session ~env ~child_env ~cwd:(Client.home_dir home)
                  ~argv:(Client.argv ~cli_path:spawn_path home) ~terminal:(Client.is_pty home)
                  ~is_closed ~on_ready ~on_output ~on_input_ready
                  |> Result.map_error (fun error ->
                    let status = match error with
                      | Session.Cancelled -> Receipt.Cancelled
                      | Already_running | Not_found | Not_running | Input_pending
                      | Invalid_input | Transport_failed | Process_failed _ | Interpreter_missing -> Receipt.Failed in
                    status, Session.error_message error) in
                let* observed = observe () |> Result.map_error (fun _ ->
                  Receipt.Failed, "The official client did not confirm the selected account. Retry login or verify the account.") in
                let* account = finish owner ~base_path ~integration_id ~cli_path
                    ~login_id:(Session.id session) home
                  |> Result.map_error (fun message -> Receipt.Failed, message) in
                save { !receipt with account; status = Receipt.Complete observed }
                |> Result.map_error (fun message -> Receipt.Failed, message))
            with Eio.Cancel.Cancelled _ as exn ->
              Eio.Cancel.protect (fun () ->
                match !receipt.status with
                | Receipt.Complete _ -> ()
                | Running | Failed | Cancelled | Interrupted ->
                  (match recover Receipt.Interrupted with
                   | Ok () -> ()
                   | Error _ -> Log.Server.warn "Setup login interruption receipt could not be saved");
                credentials_rewritten ());
              raise exn in
          (match !receipt.status, completed with
           | Receipt.Complete _, _ ->
             Log.Server.info "Setup login %s completed" (Session.id session);
             send "complete" (Receipt.to_json !receipt)
           | (Running | Failed | Cancelled | Interrupted), outcome ->
             let status, message = match outcome with
               | Error Session.Cancelled -> Receipt.Cancelled, Session.error_message Session.Cancelled
               | Error
                   ((Session.Already_running | Session.Not_found | Session.Not_running
                    | Session.Input_pending | Session.Invalid_input
                    | Session.Transport_failed | Session.Process_failed _
                    | Session.Interpreter_missing) as error) ->
                 Receipt.Failed, Session.error_message error
               | Ok (Error (status, message)) -> status, message
               | Ok (Ok ()) -> Receipt.Failed, receipt_failure in
             let recovered = Eio.Cancel.protect (fun () -> recover status) in
             let message = match recovered with Ok () -> message | Error _ -> receipt_failure in
             Log.Server.info "Setup login %s did not complete" (Session.id session);
             let fields = match Receipt.to_json !receipt with `Assoc fields -> fields | _ -> [] in
             send "error" (`Assoc (("message", `String message) :: fields)));
          credentials_rewritten ();
          Ok ())) in
    (match result with
     | Ok () -> ()
     | Error error -> respond ~status:(session_status error) ~request reqd (Session.error_message error))

let status ~owner ~base_path request reqd =
  let actor = actor_of owner in
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

let control ~owner ~base_path ~body request reqd =
  let actor = actor_of owner in
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

(* ---- a person's account, called once (plan D1-6a), and its Runtime (plan D1) ---- *)

let verification_timeout_s = 120.0

let verify_members = [ "provider_account_id"; "model" ]

(* Exactly the two members, in either order. A repeated member leaves the
   other one out, so it is refused too. *)
let verify_request body =
  let expected = "Expected exactly provider_account_id and model." in
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error _ -> Error "Invalid verification request."
  | `Assoc fields when List.length fields = List.length verify_members ->
    (match List.assoc_opt "provider_account_id" fields, List.assoc_opt "model" fields with
     | Some (`String id), Some (`String model) -> Ok (id, model)
     | _ -> Error expected)
  | _ -> Error expected

let unknown_account = "No account of yours has this id."

type prepared =
  { provider_account_id : Authz_types.Provider_account_id.t
  ; runtime_id : Authz_types.Runtime_id.t
  ; runtime : Runtime_instance.t
  }

(* The diagnostic of a runtime that does not load can name a path of the
   server, so it goes to the server log (issue #50018). The other errors name
   only the provider and the model the person chose. *)
let template_error (error : Runtime_account_runtime.error) =
  match error with
  | Runtime_account_runtime.Not_materialized _ ->
    Log.Server.warn "Account runtime did not load: %s" (Runtime_account_runtime.error_to_string error);
    `Bad_request, "The runtime of this account does not load."
  | Runtime_account_runtime.Template_not_declared _ | Runtime_account_runtime.Model_not_bound _
  | Runtime_account_runtime.Runtime_not_bound _ ->
    `Bad_request, Runtime_account_runtime.error_to_string error

(* The state a route of a person decides on. A zone that cannot be trusted
   gives none, and the route answers a 503. *)
let trusted_state person =
  match Authz_zone.read person.zone with
  | Ok trusted -> Ok (trusted :> Authz_zone.snapshot).Authz_zone.state
  | Error uncertain -> Error (`Service_unavailable, Login_routes.zone_uncertain_message uncertain)

(* The account of the person, its integration as the login receipt names it,
   and the runtime of [binding] on its home. An account of another person is
   answered as one that does not exist (design 4.2: an id grants nothing). *)
let person_runtime person ~base_path ~provider_account_id:id ~binding =
  let provider_account_id = Authz_types.Provider_account_id.to_string id in
  let* state = trusted_state person in
  let* () = match Authz_provider_account_state.owner state.Authz_state.provider_accounts id with
    | Some owner when Authz_types.User_id.equal owner person.user_id -> Ok ()
    | Some _ | None -> Error (`Not_found, unknown_account) in
  let* receipt = Receipt.load ~workspace:base_path ~actor:(actor_of (Person person)) ~login_id:provider_account_id
    |> Result.map_error (function
      | Receipt.Not_found -> `Not_found, unknown_account
      | Receipt.Unavailable -> `Service_unavailable, receipt_failure) in
  let setup_error error =
    `Bad_request, Server_runtime_setup_actions.error_message error in
  let* target = Server_runtime_setup_actions.login_target ~base_path ~integration_id:receipt.integration_id
    |> Result.map_error setup_error in
  let* runtime_root = runtime_root_of ~base_path (Person person)
    |> Result.map_error (fun message -> `Service_unavailable, message) in
  let* account_home = Client.account_home ~runtime_root ~account_id:provider_account_id
      ~client:target.Server_runtime_setup_actions.client
    |> Result.map_error (fun message -> `Service_unavailable, message) in
  let* config = Server_runtime_setup_actions.config ~base_path |> Result.map_error setup_error in
  let* runtime = Runtime_account_runtime.of_template config ~template:receipt.integration_id
      ~provider_id:provider_account_id ~account_home ~binding
    |> Result.map_error template_error in
  (* Checked before the call, so a model that makes no Runtime id is not
     called for two minutes first. A [Runtime] binding makes the id it was
     chosen by, which is one. *)
  let* runtime_id = Authz_types.Runtime_id.of_string runtime.Runtime_instance.id
    |> Result.map_error (fun _ -> `Bad_request, "This model makes no valid Runtime id.") in
  Ok { provider_account_id = id; runtime_id; runtime }

(* One call of an account at a time, a verification or a turn of a Keeper:
   each starts the official client on the home of the account, and no two
   clients refresh the credential of one home at once. A call while another
   runs gets [busy] (issue #50018). An account has one owner, so its id is
   the key. *)
let calling = Hashtbl.create 8
let calling_mutex = Mutex.create ()
let call_running = "A call of this account is running."

let one_call_of provider_account_id ~busy f =
  let key = Authz_types.Provider_account_id.to_string provider_account_id in
  let claimed = Mutex.protect calling_mutex (fun () ->
    if Hashtbl.mem calling key then false else (Hashtbl.replace calling key (); true)) in
  if not claimed then Error busy
  else Fun.protect f ~finally:(fun () ->
    Mutex.protect calling_mutex (fun () -> Hashtbl.remove calling key))

type recorded = Made | Existing

let recorded_label = function Made -> "made" | Existing -> "existing"

let runtime_failure = "The Runtime of this account could not be recorded."

(* What the Self grant of a verified Runtime allows: its owner's turns read
   state, call the model and use tools (user decision 2026-11-09, plan D2).
   A turn is decided against this set, never against a default in code. *)
let verified_runtime_effects =
  Authz_types.Effect.(Set.of_list [ Read_state; Invoke_model; Use_tool ])

(* A model of the person's account answered and called a tool, so its binding
   is a Runtime of theirs, with its Self grant (plan D1). Another call finds
   the Runtime the first one made. *)
let record_runtime person { provider_account_id; runtime_id; runtime = _ } =
  let* state = trusted_state person in
  match Authz_runtime_state.find state.Authz_state.runtimes runtime_id with
  | Some { Authz_runtime_state.owner; provider_account_id = account; self_grant = _; self_effects = _ }
    when Authz_types.User_id.equal owner person.user_id
         && Authz_types.Provider_account_id.equal account provider_account_id -> Ok Existing
  | Some _ -> Error (`Conflict, "Another account has a Runtime of this id.")
  | None ->
    (match Authz_runtime.make person.zone ~user_id:person.user_id ~provider_account_id ~runtime_id
             ~self_effects:verified_runtime_effects ~draw:Auth.generate_token with
     | Ok (_ : Authz_types.Grant_id.t) -> Ok Made
     | Error error ->
       Log.Server.warn "Runtime %s was not recorded: %s"
         (Authz_types.Runtime_id.to_string runtime_id) (Authz_runtime.error_detail error);
       Error (`Service_unavailable, runtime_failure))

(* The detail of a failure can name a path of the server, so it goes to the
   server log and the person gets the code and the message (issue #50018). *)
let log_detail (result : Runtime_verification.result) =
  match Option.bind result.Runtime_verification.failure Runtime_verification.failure_detail with
  | Some detail -> Log.Server.warn "Account verification %s failed: %s" result.runtime_id detail
  | None -> ()

let call ~env ~person prepared =
  (* macOS TMPDIR sits under the /var -> /private/var symlink, and a runtime
     root must be its own realpath, as the runtime-verify command has it. *)
  match Filename.temp_dir "masc-account-verify-" "" |> Unix.realpath with
  | exception (Unix.Unix_error _ | Sys_error _) ->
    Error (`Service_unavailable, "The private verification directory could not be made.")
  | private_dir ->
    Ok (Eio.Switch.run (fun sw ->
      Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree private_dir);
      Runtime_verification.verify_as_command ~env ~sw ~private_dir
        ~timeout_s:verification_timeout_s
        ~account_request:(Runtime_account_access.Own_account
          { user_id = person.user_id; provider_account_id = prepared.provider_account_id })
        prepared.runtime))

let verify ~person ~base_path ~body request reqd =
  let answer =
    let* provider_account_id, model = verify_request body
      |> Result.map_error (fun message -> `Bad_request, message) in
    let* provider_account_id = Authz_types.Provider_account_id.of_string provider_account_id
      |> Result.map_error (fun _ -> `Not_found, unknown_account) in
    let* prepared = person_runtime person ~base_path ~provider_account_id
        ~binding:(Runtime_account_runtime.Model model) in
    let* env = Option.to_result (Eio_context.get_env_opt ())
      ~none:(`Service_unavailable, "Verification requires the server process environment.") in
    one_call_of prepared.provider_account_id ~busy:(`Conflict, call_running) (fun () ->
      let* result = call ~env ~person prepared in
      log_detail result;
      let* runtime = match result.Runtime_verification.failure with
        | Some _ -> Ok `Null
        | None ->
          let* recorded = record_runtime person prepared in
          Ok (`Assoc [ "runtime_id", `String (Authz_types.Runtime_id.to_string prepared.runtime_id);
                       "record", `String (recorded_label recorded) ]) in
      Ok (`Assoc [ "verification", Runtime_verification.to_member_json result; "runtime", runtime ])) in
  match answer with
  | Error (status, message) -> respond ~status ~request reqd message
  | Ok json -> Http.Response.json_value ~request ~extra_headers:["cache-control", "no-store"] json reqd
