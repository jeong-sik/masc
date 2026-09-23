(** See keeper_identity_gate.mli. *)

open Keeper_meta_contract
module Provider = Keeper_oauth_provider

let ( let* ) = Result.bind

let gate_operation = Keeper_gate.identity_call_gate_operation

let gate_input ~provider_id ~remote_name ~arguments =
  `Assoc
    [ "provider_id", `String provider_id
    ; "remote_name", `String remote_name
    ; "arguments", arguments
    ]
;;

type replay_call = {
  input : Yojson.Safe.t;
  provider_id : string;
  remote_name : string;
  arguments : Yojson.Safe.t;
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
    let* remote_name = required_string "remote_name" fields in
    let* arguments = required "arguments" fields in
    let* () =
      reject_unknown ~allowed:[ "provider_id"; "remote_name"; "arguments" ] fields
    in
    Ok { input; provider_id; remote_name; arguments }
  | _ -> Error "approved identity_call input must be an object"
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
      ()
  in
  let run_raw arguments =
    Keeper_identity_tools.tool_result_of_call
      ~read_only:offered.Keeper_identity_tools.read_only
      (send arguments)
  in
  let gated arguments =
    match offered.Keeper_identity_tools.read_only with
    (* The provider's own word, written down at attach time. Only an
       explicit "this tool only reads" runs unasked; silence is not
       permission, and the durable Gate is where the rest gets decided. *)
    | Some true -> run_raw arguments
    | Some false | None ->
      let provider_id = offered.Keeper_identity_tools.provider.Provider.id in
      let remote_name = offered.Keeper_identity_tools.remote_name in
      let call =
        { input = gate_input ~provider_id ~remote_name ~arguments
        ; provider_id
        ; remote_name
        ; arguments
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
      (* MCP [isError] is the server's own statement that the tool failed.
         Read as no effect — the same reading the model-facing adapter
         gives it. A service that half-applied and then errored reports
         through its own state on the next read, not through this field. *)
      Keeper_tool_execution.failure
        ~class_:Tool_result.Runtime_failure
        ~effect_disposition:Tool_result.Proven_pre_effect
        answer.Mcp_client.text
    else Keeper_tool_execution.success answer.Mcp_client.text
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
               ())))
;;
