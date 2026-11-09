(* HIGH-RISK-UNREVIEWED: see the interface. *)

module R = Login_routes
module Ks = Authz_keeper_state
module Login = Server_setup_account_login

let ( let* ) = Result.bind
let max_message_bytes = 4096
let turn_timeout_s = 120.0
let error status text = R.json status [ "error", `String text ]
let shape = {|The body is {"keeper_id": "<name>", "message": "<text>"}.|}
let unknown_keeper = "No Keeper of yours has this name."
let no_runtime = "The Keeper has no Runtime. Give it one of yours first."
let not_claude_code = "A Keeper turn runs here only on a Claude Code Runtime."
let call_running = "A call of the account of this Keeper's Runtime is running."
let unexpected_refusal = "The turn was refused for a reason this preview does not expect."

let request_of body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error (_ : string) -> Error (error R.Bad_request_400 shape)
  | `Assoc [ ("keeper_id", `String name); ("message", `String message) ] ->
    if String.length message > max_message_bytes
    then
      Error
        (error
           R.Bad_request_400
           (Printf.sprintf "The message is longer than %d bytes." max_message_bytes))
    else if String.equal (String.trim message) ""
    then Error (error R.Bad_request_400 "The message is blank.")
    else Ok (name, message)
  | _ -> Error (error R.Bad_request_400 shape)
;;

(* The Runtime the person gave the Keeper, and the account that Runtime
   spends. A Keeper of another person is answered as one that is not there,
   as the other Keeper routes answer it. *)
let assigned (person : Login.person) keeper_id =
  let state = (Authz_zone.snapshot person.zone).Authz_zone.state in
  match Ks.find state.Authz_state.keepers keeper_id with
  | Some { Ks.owner; runtime; policy_id = _; turn_scope = _ }
    when Authz_types.User_id.equal owner person.user_id ->
    (match runtime with
     | None -> Error (error R.Conflict_409 no_runtime)
     | Some runtime_id ->
       (match Authz_runtime_state.find state.Authz_state.runtimes runtime_id with
        | Some { Authz_runtime_state.provider_account_id; owner = _; self_grant = _; self_effects = _ } ->
          Ok (runtime_id, provider_account_id)
        | None ->
          (* The log gives a Keeper only a Runtime it made, and a Runtime it
             made stays. *)
          Log.Server.warn
            "Keeper %s has the Runtime %s, which the log does not have"
            (Authz_types.Keeper_id.to_string keeper_id)
            (Authz_types.Runtime_id.to_string runtime_id);
          Error (error R.Internal_error_500 "The Runtime of this Keeper is not in the log.")))
  | Some (_ : Ks.keeper) | None -> Error (error R.Not_found_404 unknown_keeper)
;;

let login_answer (status, message) =
  error
    (match status with
     | `Bad_request -> R.Bad_request_400
     | `Not_found -> R.Not_found_404
     | `Service_unavailable -> R.Service_unavailable_503)
    message
;;

let refusal_answer (refusal : Runtime_account_access.refusal) =
  let text = Runtime_account_access.refusal_to_string refusal in
  match refusal with
  | Runtime_account_access.Turn_refused (Authz_keeper_turn.Denied _)
  | Runtime_account_access.Not_active _
  | Runtime_account_access.Not_the_account_home _ -> error R.Forbidden_403 text
  | Runtime_account_access.Not_the_assigned_runtime _
  | Runtime_account_access.Turn_refused (Authz_keeper_turn.No_authorized_runtime _) ->
    (* The owner gave the Keeper another Runtime after the route read it. *)
    error R.Conflict_409 text
  | Runtime_account_access.Turn_refused (Authz_keeper_turn.Keeper_not_made _) ->
    error R.Not_found_404 unknown_keeper
  | Runtime_account_access.Turn_refused Authz_keeper_turn.Log_kept_moving ->
    error R.Service_unavailable_503 text
  | Runtime_account_access.Home_unresolved _ ->
    (* The reason can name a path of the server (issue #50018). *)
    Log.Server.warn "A Keeper turn was refused: %s" text;
    error R.Service_unavailable_503 "The home of the account could not be spelled."
  | Runtime_account_access.Not_published
  | Runtime_account_access.No_operator
  | Runtime_account_access.Not_a_keeper_id _
  | Runtime_account_access.No_membership _
  | Runtime_account_access.Not_a_declared_home
  | Runtime_account_access.Turn_refused Authz_keeper_turn.Not_bootstrapped ->
    (* The preview publishes its access before it listens, a turn is no
       operator call, the name was read as an id of the log, an admission
       makes the membership, the runtime declares its home, and the zone
       opened on a bootstrapped log. *)
    Log.Server.warn "A Keeper turn was refused: %s" text;
    error R.Internal_error_500 unexpected_refusal
;;

let failure_answer ~keeper_id (failure : Runtime_claude_code.error) =
  Log.Server.warn
    "Keeper %s turn failed: %s"
    (Authz_types.Keeper_id.to_string keeper_id)
    (Runtime_claude_code.error_to_string failure);
  match failure with
  | Runtime_claude_code.Subscription_required _ ->
    error R.Conflict_409 "The account of this Runtime is not signed in to a subscription."
  | Runtime_claude_code.Quota_blocked _ ->
    error R.Too_many_requests_429 "The subscription of this Runtime has no quota left."
  | Runtime_claude_code.Timeout _ ->
    error
      R.Gateway_timeout_504
      (Printf.sprintf "The client sent nothing for %.0f seconds." turn_timeout_s)
  | Runtime_claude_code.Spawn_failed _ -> error R.Service_unavailable_503 "The client did not start."
  | Runtime_claude_code.Invalid_config _ ->
    error R.Internal_error_500 "The client refused the configuration of the Runtime."
  | Runtime_claude_code.Turn_failed_with_observation _
  | Runtime_claude_code.Protocol_error _
  | Runtime_claude_code.Unsupported_control_request _
  | Runtime_claude_code.Turn_transport_interrupted _
  | Runtime_claude_code.Context_window_exceeded _
  | Runtime_claude_code.Turn_failed _
  | Runtime_claude_code.Stopped_by_host _
  | Runtime_claude_code.Process_exited _
  | Runtime_claude_code.Unhandled_exception _ ->
    error R.Bad_gateway_502 "The client ended the turn without an answer."
;;

(* macOS TMPDIR sits under the /var -> /private/var symlink, and the client
   gets the real path as its directory, as a verification does. *)
let call ~env ~keeper_id ~(execution : Runtime_execution.claude_code) ~account ~message =
  match Filename.temp_dir "masc-keeper-turn-" "" |> Unix.realpath with
  | exception (Unix.Unix_error _ | Sys_error _) ->
    Error (error R.Service_unavailable_503 "The private turn directory could not be made.")
  | private_dir ->
    Eio.Switch.run (fun sw ->
      Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree private_dir);
      let clock = Eio.Stdenv.clock env in
      let config =
        { (Runtime_claude_code.default_config ~cwd:private_dir) with
          cli_path = execution.cli_path
        ; model = execution.model
        ; admission_timeout_s = Float.min turn_timeout_s execution.timeout_s
        ; timeout_s = Some turn_timeout_s
        }
      in
      Runtime_claude_code.run_turn
        ~mgr:
          (Posix_spawn_process_mgr.foreground_mgr
             ~clock
             ~grace_seconds:Process_eio.child_exit_grace_seconds)
        ~clock
        ~cwd:Eio.Path.(Eio.Stdenv.fs env / private_dir)
        ~account
        config
        ~prompt:message
        ~images:[]
      |> Result.map_error (failure_answer ~keeper_id))
;;

let run ~env ~(person : Login.person) ~base_path ~body =
  let answer =
    let* name, message = request_of body in
    let* keeper_id = Auth_preview_keeper.keeper_id_of name in
    let* runtime_id, provider_account_id = assigned person keeper_id in
    (* The binding is chosen by the Runtime id, so [prepared.runtime_id] is
       [runtime_id]. *)
    let* prepared =
      Login.person_runtime
        person
        ~base_path
        ~provider_account_id
        ~binding:(Runtime_account_runtime.Runtime (Authz_types.Runtime_id.to_string runtime_id))
      |> Result.map_error login_answer
    in
    let* execution =
      match prepared.Login.runtime.Runtime_instance.execution with
      | Runtime_execution.Claude_code execution -> Ok execution
      | Runtime_execution.Codex_app_server _
      | Runtime_execution.Antigravity_cli _
      | Runtime_execution.Muse_serve _
      | Runtime_execution.Vibe_cli _
      | Runtime_execution.Agent_core _ -> Error (error R.Bad_request_400 not_claude_code)
    in
    let* account =
      Runtime_account_access.authorize
        (Runtime_account_access.Keeper_turn
           { keeper_name = Authz_types.Keeper_id.to_string keeper_id
           ; channel = Authz_types.Channel.Direct
           ; runtime_id = Authz_types.Runtime_id.to_string prepared.Login.runtime_id
           })
        (Runtime_account_access.seal execution.account_home)
      |> Result.map_error refusal_answer
    in
    let* turn =
      Login.one_call_of
        provider_account_id
        ~busy:(error R.Conflict_409 call_running)
        (fun () -> call ~env ~keeper_id ~execution ~account ~message)
    in
    Ok
      (R.json
         R.Ok_200
         [ "keeper_id", `String (Authz_types.Keeper_id.to_string keeper_id)
         ; "runtime_id", `String (Authz_types.Runtime_id.to_string prepared.Login.runtime_id)
         ; "model", `String turn.Runtime_claude_code.model
         ; "text", `String turn.Runtime_claude_code.text
         ])
  in
  Result.fold ~ok:Fun.id ~error:Fun.id answer
;;
