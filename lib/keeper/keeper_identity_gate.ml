(** See keeper_identity_gate.mli. *)

open Keeper_meta_contract
module Provider = Keeper_oauth_provider

open Result.Syntax

let gate_operation = Keeper_gate.identity_call_gate_operation

(* The declaration snapshot is ordered and versioned. Only its fingerprint
   is persisted, so neither URLs with private query values nor OAuth parameters
   are copied into approval records. Credential contents are intentionally not
   included: their account identity requires a separate provider capability. *)
let provider_authority_sha256 (provider : Provider.t) =
  let credential_source =
    match provider.Provider.credential_source with
    | Provider.Oauth_exchange -> `Assoc [ "type", `String "oauth_exchange" ]
    | Provider.Github_cli { hostname } ->
      `Assoc [ "type", `String "github_cli"; "hostname", `String hostname ]
  in
  let authority = `Assoc
    [ "version", `Int 1
    ; "id", `String provider.id
    ; "mcp_url", `String provider.mcp_url
    ; "client_group", `String provider.client_group
    ; "credential_source", credential_source
    ; "access_token_env", `String provider.access_token_env
    ; "expires_at_env", `String provider.expires_at_env
    ; "refresh_token_file", `String provider.refresh_token_file
    ; "renew_before_sec", `Int provider.renew_before_sec
    ; "authorize_params", `List
        (provider.authorize_params
         |> List.sort compare
         |> List.map (fun (key, value) -> `List [ `String key; `String value ]))
    ] in
  Agent_core_sha256.(authority |> Yojson.Safe.to_string |> digest_string |> to_hex)
;;

let gate_input ~provider ~remote_name ~arguments ~input_schema ~read_only =
  `Assoc
    [ "provider_id", `String provider.Provider.id
    ; "provider_authority_sha256", `String (provider_authority_sha256 provider)
    ; "remote_name", `String remote_name
    ; "arguments", arguments
    ; "input_schema", input_schema
    ; "read_only", (match read_only with Some value -> `Bool value | None -> `Null)
    ]
;;

type replay_call = {
  input : Yojson.Safe.t;
  provider_id : string;
  provider_authority_sha256 : string option;
  remote_name : string;
  arguments : Yojson.Safe.t;
  input_schema : Yojson.Safe.t option;
  read_only : bool option;
}

let replay_of_gate_input input =
  let field key fields =
    List.filter_map
      (fun (name, value) -> if String.equal name key then Some value else None)
      fields
  in
  let required_string key fields =
    match field key fields with
    | [ `String value ] when not (String.equal (String.trim value) "") ->
      Ok value
    | [ `String _ ] ->
      Error (Printf.sprintf "approved identity_call %s is blank" key)
    | [ _ ] ->
      Error (Printf.sprintf "approved identity_call %s must be a string" key)
    | [] -> Error (Printf.sprintf "approved identity_call is missing %s" key)
    | _ -> Error (Printf.sprintf "approved identity_call repeats %s" key)
  in
  let required key fields =
    match field key fields with
    | [ value ] -> Ok value
    | [] -> Error (Printf.sprintf "approved identity_call is missing %s" key)
    | _ -> Error (Printf.sprintf "approved identity_call repeats %s" key)
  in
  let reject_unknown ~allowed fields =
    match
      fields
      |> List.filter_map (fun (name, _) ->
        if List.mem name allowed then None else Some name)
      |> List.sort_uniq String.compare
    with
    | [] -> Ok ()
    | names ->
      Error
        (Printf.sprintf
           "approved identity_call has unknown field(s): %s"
           (String.concat ", " names))
  in
  match input with
  | `Assoc fields ->
    let* provider_id = required_string "provider_id" fields in
    let* provider_authority_sha256 =
      match field "provider_authority_sha256" fields with
      | [] -> Ok None
      | [ `String value ]
        when String.length value = 64
             && String.for_all
                  (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
                  value -> Ok (Some value)
      | [ _ ] -> Error "approved identity_call provider_authority_sha256 is invalid"
      | _ -> Error "approved identity_call repeats provider_authority_sha256"
    in
    let* remote_name = required_string "remote_name" fields in
    let* arguments = required "arguments" fields in
    let* input_schema =
      match field "input_schema" fields with
      | [] -> Ok None
      | [ value ] -> Ok (Some value)
      | _ -> Error "approved identity_call repeats input_schema"
    in
    let* read_only =
      match field "read_only" fields with
      | [] | [ `Null ] -> Ok None
      | [ `Bool value ] -> Ok (Some value)
      | [ _ ] -> Error "approved identity_call read_only must be a boolean or null"
      | _ -> Error "approved identity_call repeats read_only"
    in
    let* () =
      reject_unknown
        ~allowed:[ "provider_id"; "provider_authority_sha256"; "remote_name";
                   "arguments"; "input_schema"; "read_only" ] fields
    in
    Ok { input; provider_id; provider_authority_sha256; remote_name; arguments;
         input_schema; read_only }
  | _ -> Error "approved identity_call input must be an object"
;;

let validate_replay_provider ~(provider : Provider.t) (call : replay_call) =
  if not (String.equal provider.id call.provider_id) then
    Error "the approved provider ID no longer matches; a new approval is required"
  else
    match call.input_schema, call.provider_authority_sha256 with
    | None, _ -> Error "the approval has no tool schema; a new approval is required"
    | _, None -> Error "the approval has no provider declaration binding; a new approval is required"
    | Some _, Some fingerprint ->
      if String.equal fingerprint (provider_authority_sha256 provider) then Ok ()
      else Error "the provider declaration changed; a new approval is required"
;;

(* What an identity_call approval is about, in one line: the provider surface
   it would reach, [provider/remote]. The arguments are the provider's own
   payload and are not read; a field in them named like a command is the
   remote tool's business, not this call's summary. *)
let call_summary (call : replay_call) =
  String_util.first_nonblank_line (call.provider_id ^ "/" ^ call.remote_name)
;;

let decide
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~(call : replay_call)
      ()
  =
  Keeper_gate.decide_external_service
    ?cycle_grant:gate_grant
    ~keeper_always_allow:(Option.value ~default:false meta.always_allow)
    { keeper_name = meta.name
    ; operation = gate_operation
    ; input = call.input
    ; call_summary = call_summary call
    ; sandbox_profile = None
    ; base_path = config.Workspace.base_path
    ; causal_context = Option.map (fun current -> current ()) gate_context
    ; task_id = Option.map Keeper_id.Task_id.to_string meta.current_task_id
    ; continuation_channel
    }
;;

let gate_unavailable_message reason =
  Printf.sprintf
    "External effect was not executed because the Gate could not durably \
     record its decision state. This Keeper remains active and may continue \
     other work. gate_reason=%s"
    (Keeper_gate.unavailable_reason_to_string reason)
;;

(* Injected transports are a test's. Production builds bounded ones from a
   clock, the turn's when the caller carries one and the process's otherwise.
   A process with no clock cannot bound the call and does not make it: that
   is a precondition failure like a missing credential, and the model is told
   it is deterministic. *)
let resolve_transports ?transports ?clock () =
  match transports with
  | Some transports -> Ok transports
  | None ->
    (match
       (match clock with
        | Some clock -> Some clock
        | None -> Eio_context.get_clock_opt ())
     with
     | Some clock -> Ok (Keeper_identity_tools.http_transports ~clock)
     | None ->
       Error
         (Keeper_identity_tools.Precondition
            "this process has no clock to bound the call with; nothing was sent"))
;;

(* The one way a call leaves this module, for the live tool and for a replay
   alike: the transports are resolved per call, so a turn that started
   without a clock and gained one is not held to the earlier refusal. *)
let send_call
      ?transports
      ?clock
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~provider
      ~remote_name
      ~arguments
      ~input_schema
      ~read_only
      ()
  =
  match resolve_transports ?transports ?clock () with
  | Error error -> Error error
  | Ok transports ->
    Keeper_identity_tools.run_call
      ~transports
      ~config
      ~keeper_name:meta.name
      ~provider
      ~remote_name
      ~arguments
      ~catalog_authority:
        (Mcp_client.Bound
           (Option.map (fun input_schema -> { Mcp_client.input_schema; read_only }) input_schema))
      ()
;;

let agent_tool
      ?transports
      ?clock
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ?continuation_channel
      ?gate_context
      ?gate_grant
      (offered : Keeper_identity_tools.offered_tool)
  =
  let send arguments =
    send_call
      ?transports
      ?clock
      ~config
      ~meta
      ~provider:offered.Keeper_identity_tools.provider
      ~remote_name:offered.Keeper_identity_tools.remote_name
      ~arguments
      ~input_schema:(Some offered.Keeper_identity_tools.remote_input_schema)
      ~read_only:offered.Keeper_identity_tools.read_only
      ()
  in
  let run_raw arguments =
    Keeper_identity_tools.tool_result_of_call
      (send arguments)
  in
  let gated arguments =
    (* Provider annotations are hints, not authority to bypass this lane. *)
      let provider = offered.Keeper_identity_tools.provider in
      let provider_id = provider.Provider.id in
      let remote_name = offered.Keeper_identity_tools.remote_name in
      let call =
        { input = gate_input ~provider ~remote_name ~arguments
                    ~input_schema:offered.Keeper_identity_tools.remote_input_schema
                    ~read_only:offered.Keeper_identity_tools.read_only
        ; provider_id
        ; provider_authority_sha256 = Some (provider_authority_sha256 provider)
        ; remote_name
        ; arguments
        ; input_schema = Some offered.Keeper_identity_tools.remote_input_schema
        ; read_only = offered.Keeper_identity_tools.read_only
        }
      in
      (match
         decide
           ~config
           ~meta
           ?continuation_channel
           ?gate_context
           ?gate_grant
           ~call
           ()
       with
       | Keeper_gate.Deferred { approval_id; reason; audit_receipts } ->
         let payload =
           Keeper_gate_deferred_payload.create
             ~operation:gate_operation
             ~approval_id
             ~reason
             ~audit_receipts
             ()
         in
         Ok
           { Agent_core.Types.content =
               Yojson.Safe.to_string (Keeper_gate_deferred_payload.data payload)
           ; content_blocks = None; _meta = None
           }
       | Keeper_gate.Unavailable reason ->
         Error
           { Agent_core.Types.message = gate_unavailable_message reason
           ; recoverable = true
           ; error_class = Some Agent_core.Types.Transient
           }
       | Keeper_gate.Allow authorization ->
         (match run_raw arguments with
          | Ok output ->
            Ok
              { output with
                Agent_core.Types._meta =
                  Some
                    (Keeper_gate.authorization_metadata
                       ?producer_metadata:output.Agent_core.Types._meta
                       authorization)
              }
          | Error _ as failed -> failed))
  in
  Agent_core.Base.Tool.of_schema
    offered.Keeper_identity_tools.schema
    (Agent_core.Base.Tool.ignoring_execution_env gated)
;;

let resolve_provider provider_id =
  List.find_map
    (function
      | Keeper_oauth_declarations.Declared provider
        when String.equal provider.Provider.id provider_id -> Some provider
      | Keeper_oauth_declarations.Declared _
      | Keeper_oauth_declarations.Unreadable _ -> None)
    (Keeper_oauth_declarations.all ())
;;

let execution_of_call_result result =
  match result with
  | Ok (answer : Mcp_client.tool_result) ->
    if answer.Mcp_client.is_error
    then
      (* A failed tool may have applied an effect before reporting its error. *)
      Keeper_tool_execution.failure
        ~class_:Tool_result.Runtime_failure
        ~effect_disposition:Tool_result.Effect_outcome_unknown
        (Mcp_client.model_text answer)
    else Keeper_tool_execution.success (Mcp_client.model_text answer)
  | Error call_error ->
    (* The disposition is the call's own statement of what it proves; the
       model-facing result reads the same one for retry safety. *)
    Keeper_tool_execution.failure
      ~class_:Tool_result.Runtime_failure
      ~effect_disposition:
        (Keeper_identity_tools.effect_disposition_of_call_error call_error)
      (Keeper_identity_tools.call_error_to_string call_error)
;;

let replay_call_with_outcome
      ?transports
      ?clock
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ?continuation_channel
      ?gate_context
      ~gate_grant
      (call : replay_call)
  =
  match resolve_provider call.provider_id with
  | None ->
    Keeper_tool_execution.failure
      ~class_:Tool_result.Runtime_failure
      ~effect_disposition:Tool_result.Proven_pre_effect
      (Printf.sprintf
         "provider %s is no longer declared; the approved call cannot run"
         call.provider_id)
  | Some provider ->
    (match validate_replay_provider ~provider call with
     | Error reason ->
       Keeper_tool_execution.failure
         ~class_:Tool_result.Runtime_failure
         ~effect_disposition:Tool_result.Proven_pre_effect
         reason
     | Ok () ->
    (* The stored input verbatim, through the same Gate and lane: an exact
       match consumes the one-shot grant, and anything else follows the
       ordinary Gate instead of inventing a second replay constraint. *)
    (match
       decide
         ~config
         ~meta
         ?continuation_channel
         ?gate_context
         ~gate_grant
         ~call
         ()
     with
     | Keeper_gate.Deferred { approval_id; reason; audit_receipts } ->
       Keeper_gate_deferred_payload.to_execution
         (Keeper_gate_deferred_payload.create
            ~operation:gate_operation
            ~approval_id
            ~reason
            ~audit_receipts
            ())
     | Keeper_gate.Unavailable reason ->
       Keeper_tool_execution.failure
         ~class_:Tool_result.Dependency_unavailable
         ~effect_disposition:Tool_result.Proven_pre_effect
         (gate_unavailable_message reason)
     | Keeper_gate.Allow authorization ->
       Keeper_tool_execution.with_gate_authorization
         authorization
         (execution_of_call_result
            (send_call
               ?transports
               ?clock
               ~config
               ~meta
               ~provider
               ~remote_name:call.remote_name
               ~arguments:call.arguments
               ~input_schema:call.input_schema
               ~read_only:call.read_only
               ()))))
;;
