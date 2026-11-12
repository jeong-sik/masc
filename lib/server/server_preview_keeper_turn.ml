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
let not_official_client = "A Keeper turn runs here only on a Claude Code or a Codex Runtime."
let call_running = "A call of the account of this Keeper's Runtime is running."
let unexpected_refusal = "The turn was refused for a reason this preview does not expect."
let not_signed_in = "The account of this Runtime is not signed in to a subscription."
let no_quota = "The subscription of this Runtime has no quota left."
let not_started = "The client did not start."
let configuration_refused = "The client refused the configuration of the Runtime."
let no_answer = "The client ended the turn without an answer."

let silent () =
  Printf.sprintf "The client sent nothing for %.0f seconds." turn_timeout_s
;;

let request_of body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error (_ : string) -> Error (error R.Bad_request_400 shape)
  | `Assoc ([ _; _ ] as fields) ->
    (* Exactly these two named fields: duplicates cannot replace a missing
       field, and additional fields are refused before starting a turn. *)
    (match List.assoc_opt "keeper_id" fields, List.assoc_opt "message" fields with
     | Some (`String name), Some (`String message) ->
       if String.length message > max_message_bytes
       then
         Error
           (error
              R.Bad_request_400
              (Printf.sprintf "The message is longer than %d bytes." max_message_bytes))
       else if String.equal (String.trim message) ""
       then Error (error R.Bad_request_400 "The message is blank.")
       else Ok (name, message)
     | _ -> Error (error R.Bad_request_400 shape))
  | _ -> Error (error R.Bad_request_400 shape)
;;

(* The Runtime the person gave the Keeper, and the account that Runtime
   spends, in a state the zone can be trusted for. A Keeper of another person
   is answered as one that is not there, as the other Keeper routes answer
   it. *)
let assigned (person : Login.person) keeper_id =
  match Authz_zone.read person.zone with
  | Error uncertain -> Error (R.zone_uncertain uncertain)
  | Ok trusted ->
    let state = (trusted :> Authz_zone.snapshot).Authz_zone.state in
    (match Ks.find state.Authz_state.keepers ~owner:person.user_id keeper_id with
     | Some { Ks.runtime; owner = _; policy_id = _; turn_scope = _ } ->
       (match runtime with
        | None -> Error (error R.Conflict_409 no_runtime)
        | Some runtime_id ->
          (match Authz_runtime_state.find state.Authz_state.runtimes runtime_id with
           | Some
               { Authz_runtime_state.provider_account_id; owner = _; self_grant = _; self_effects = _ }
             -> Ok (runtime_id, provider_account_id)
           | None ->
             (* The log gives a Keeper only a Runtime it made, and a Runtime it
                made stays. *)
             Log.Server.warn
               "Keeper %s has the Runtime %s, which the log does not have"
               (Authz_types.Keeper_id.to_string keeper_id)
               (Authz_types.Runtime_id.to_string runtime_id);
             Error (error R.Internal_error_500 "The Runtime of this Keeper is not in the log.")))
     | None -> Error (error R.Not_found_404 unknown_keeper))
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
  | Runtime_account_access.Zone_uncertain uncertain ->
    (* The zone stopped, or its files came to disagree, after the route read
       the Keeper. *)
    R.zone_uncertain uncertain
  | Runtime_account_access.Home_unresolved _ ->
    (* The reason can name a path of the server (issue #50018). *)
    Log.Server.warn "A Keeper turn was refused: %s" text;
    error R.Service_unavailable_503 "The home of the account could not be spelled."
  | Runtime_account_access.Not_published
  | Runtime_account_access.No_operator
  | Runtime_account_access.No_operator_keeper _
  | Runtime_account_access.No_membership _
  | Runtime_account_access.Not_a_declared_home
  | Runtime_account_access.Host_account _
  | Runtime_account_access.Off_keeper _
  | Runtime_account_access.Off_runtime _
  | Runtime_account_access.Off_person_home
  | Runtime_account_access.Off_own_account _
  | Runtime_account_access.Turn_refused Authz_keeper_turn.Not_bootstrapped ->
    (* The preview publishes its access before it listens, a turn is no
       operator call and no turn of an operator Keeper, an admission
       makes the membership, the runtime declares its home, the preview
       starts no host client, its access is multi-account and not a single
       user after Off, and the zone opened on a bootstrapped log. *)
    Log.Server.warn "A Keeper turn was refused: %s" text;
    error R.Internal_error_500 unexpected_refusal
;;

(* The detail of a failure can name a path of the server (issue #50018), so
   it goes to the log and the answer is one of the fixed sentences. *)
let logged ~keeper_id detail =
  Log.Server.warn "Keeper %s turn failed: %s" (Authz_types.Keeper_id.to_string keeper_id) detail
;;

let claude_failure_answer ~keeper_id (failure : Runtime_claude_code.error) =
  logged ~keeper_id (Runtime_claude_code.error_to_string failure);
  match failure with
  | Runtime_claude_code.Subscription_required _ -> error R.Conflict_409 not_signed_in
  | Runtime_claude_code.Quota_blocked _ -> error R.Too_many_requests_429 no_quota
  | Runtime_claude_code.Timeout _ -> error R.Gateway_timeout_504 (silent ())
  | Runtime_claude_code.Spawn_failed _ -> error R.Service_unavailable_503 not_started
  | Runtime_claude_code.Invalid_config _ -> error R.Internal_error_500 configuration_refused
  | Runtime_claude_code.Turn_failed_with_observation _
  | Runtime_claude_code.Protocol_error _
  | Runtime_claude_code.Unsupported_control_request _
  | Runtime_claude_code.Turn_transport_interrupted _
  | Runtime_claude_code.Context_window_exceeded _
  | Runtime_claude_code.Turn_failed _
  | Runtime_claude_code.Stopped_by_host _
  | Runtime_claude_code.Process_exited _
  | Runtime_claude_code.Unhandled_exception _ -> error R.Bad_gateway_502 no_answer
;;

(* A spent subscription reaches Codex as a refused turn that names
   usageLimitExceeded or sessionBudgetExceeded, so it is read before the
   kind of the failure. *)
let codex_failure_answer ~keeper_id (failure : Runtime_codex_app_server.error) =
  logged ~keeper_id (Runtime_codex_app_server.error_to_string failure);
  if Runtime_codex_app_server.refused_for_spent_usage failure
  then error R.Too_many_requests_429 no_quota
  else (
    match failure with
    | Runtime_codex_app_server.Subscription_required _ -> error R.Conflict_409 not_signed_in
    | Runtime_codex_app_server.Timeout _ -> error R.Gateway_timeout_504 (silent ())
    | Runtime_codex_app_server.Spawn_failed _ -> error R.Service_unavailable_503 not_started
    | Runtime_codex_app_server.Invalid_config _ ->
      error R.Internal_error_500 configuration_refused
    | Runtime_codex_app_server.Reasoning_effort_admission_failed _
    | Runtime_codex_app_server.Turn_input_write_failed _
    | Runtime_codex_app_server.Protocol_error _
    | Runtime_codex_app_server.Rpc_error _
    | Runtime_codex_app_server.Account_read_failed _
    | Runtime_codex_app_server.Unsupported_server_request _
    | Runtime_codex_app_server.Context_window_exceeded _
    | Runtime_codex_app_server.Turn_failed _
    | Runtime_codex_app_server.Stopped_by_host _
    | Runtime_codex_app_server.Turn_interrupted
    | Runtime_codex_app_server.Runtime_shutting_down
    | Runtime_codex_app_server.Process_exited _ -> error R.Bad_gateway_502 no_answer)
;;

(* macOS TMPDIR sits under the /var -> /private/var symlink, and the client
   gets the real path as its directory, as a verification does. The
   directory is removed after the turn. *)
let in_private_dir ~env turn =
  match Filename.temp_dir "masc-keeper-turn-" "" |> Unix.realpath with
  | exception (Unix.Unix_error _ | Sys_error _) ->
    Error (error R.Service_unavailable_503 "The private turn directory could not be made.")
  | private_dir ->
    Eio.Switch.run (fun sw ->
      Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree private_dir);
      let clock = Eio.Stdenv.clock env in
      turn
        ~mgr:
          (Posix_spawn_process_mgr.foreground_mgr
             ~clock
             ~grace_seconds:Process_eio.child_exit_grace_seconds)
        ~clock
        ~private_dir
        ~cwd:Eio.Path.(Eio.Stdenv.fs env / private_dir))
;;

(* A multi-account process runs a model turn only without native tools (plan
   D3c), so the posture is judged before the client starts. The refusal names
   no path, so the answer carries it. *)
let native_answer posture =
  match Runtime_account_access.authorize_native posture with
  | Ok () -> Ok ()
  | Error (Runtime_account_access.Native_tools_reach_other_homes _ as refusal) ->
    Error (error R.Forbidden_403 (Runtime_account_access.native_refusal_to_string refusal))
  | Error
      (( Runtime_account_access.Native_unpublished
       | Runtime_account_access.Native_tools_reach_person_homes _
       | Runtime_account_access.Person_homes_unread _ ) as refusal) ->
    (* The preview publishes its access before it listens, and it is a
       multi-account process: the two refusals of a single user do not occur. *)
    Log.Server.warn
      "A Keeper turn was refused: %s"
      (Runtime_account_access.native_refusal_to_string refusal);
    Error (error R.Internal_error_500 unexpected_refusal)
;;

let call_claude ~env ~keeper_id ~(execution : Runtime_execution.claude_code) ~account ~message =
  in_private_dir ~env (fun ~mgr ~clock ~private_dir ~cwd ->
    let config =
      { (Runtime_claude_code.default_config ~cwd:private_dir) with
        cli_path = execution.cli_path
      ; model = execution.model
      ; admission_timeout_s = Float.min turn_timeout_s execution.timeout_s
      ; timeout_s = Some turn_timeout_s
      }
    in
    let* () = native_answer config.native in
    Runtime_claude_code.run_turn ~mgr ~clock ~cwd ~account config ~prompt:message ~images:[]
    |> Result.map (fun (turn : Runtime_claude_code.turn_result) -> turn.model, turn.text)
    |> Result.map_error (claude_failure_answer ~keeper_id))
;;

(* An ephemeral thread: Codex writes no rollout and no history for it, as
   the turn writes nothing to the log. The posture is the default of the
   client, its least one (Native_read): Codex has no Native_none, so the
   multi-account preview refuses the turn before Codex starts (plan D3c). *)
let call_codex
      ~env
      ~keeper_id
      ~runtime
      ~(execution : Runtime_execution.codex_app_server)
      ~account
      ~message
  =
  in_private_dir ~env (fun ~mgr ~clock ~private_dir:_ ~cwd ->
    let config =
      { (Runtime_codex_app_server.default_config ()) with
        cli_path = execution.cli_path
      ; model = execution.model
      ; context_window = Some (Runtime_instance.max_context_of_runtime runtime)
      ; admission_timeout_s = Float.min turn_timeout_s execution.timeout_s
      ; timeout_s = Some turn_timeout_s
      }
    in
    let* () = native_answer config.native in
    Runtime_codex_app_server.run_turn
      ~thread:Runtime_codex_app_server.Ephemeral
      ~mgr
      ~clock
      ~cwd
      ~account
      config
      ~prompt:message
      ~images:[]
    |> Result.map (fun (turn : Runtime_codex_app_server.turn_result) -> turn.model, turn.text)
    |> Result.map_error (codex_failure_answer ~keeper_id))
;;

let run ~env ~(person : Login.person) ~pat ~base_path ~body =
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
    let request =
      Runtime_account_access.Keeper_turn
        { owner = person.user_id
        ; keeper_id
        ; channel = Authz_types.Channel.Direct
        ; pat
        ; runtime_id = Authz_types.Runtime_id.to_string prepared.Login.runtime_id
        }
    in
    let authorize account =
      Runtime_account_access.authorize request account |> Result.map_error refusal_answer
    in
    let one_call turn =
      Login.one_call_of provider_account_id ~busy:(error R.Conflict_409 call_running) turn
    in
    let* model, text =
      match prepared.Login.runtime.Runtime_instance.execution with
      | Runtime_execution.Claude_code execution ->
        let* account = authorize execution.account_home in
        one_call (fun () -> call_claude ~env ~keeper_id ~execution ~account ~message)
      | Runtime_execution.Codex_app_server execution ->
        let* account = authorize execution.account_home in
        one_call (fun () ->
          call_codex ~env ~keeper_id ~runtime:prepared.Login.runtime ~execution ~account ~message)
      | Runtime_execution.Antigravity_cli _
      | Runtime_execution.Muse_serve _
      | Runtime_execution.Vibe_cli _
      | Runtime_execution.Agent_core _ -> Error (error R.Bad_request_400 not_official_client)
    in
    Ok
      (R.json
         R.Ok_200
         [ "keeper_id", `String (Authz_types.Keeper_id.to_string keeper_id)
         ; "runtime_id", `String (Authz_types.Runtime_id.to_string prepared.Login.runtime_id)
         ; "model", `String model
         ; "text", `String text
         ])
  in
  Result.fold ~ok:Fun.id ~error:Fun.id answer
;;
