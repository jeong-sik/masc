(** Keeper_tool_dispatch_runtime — exact keeper tool execution dispatch. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime
include Keeper_tool_policy

type executed_tool_result = Keeper_tool_execution.t

(* Descriptor and registered-only routes are distinct dispatch sources.
   The selected producer supplies the authoritative typed outcome. *)

type descriptor_dispatch =
  | Descriptor_route of Keeper_tool_descriptor.t * Keeper_tool_execution.t option
  | Validation_rejected of Keeper_tool_execution.t
  | Undescribed_route

type descriptor_dispatch_resolution =
  | Return_output of Keeper_tool_execution.t
  | Return_descriptor_invariant of Keeper_tool_descriptor.t
  | Try_registered_only_route

type frozen_surface_admission_error =
  | Descriptor_outside_frozen_surface of
      { requested_tool : string
      ; descriptor_id : string
      }
  | Tool_name_absent_from_frozen_surface of { requested_tool : string }

let descriptor_is_in_frozen_surface capability_surface descriptor =
  Keeper_capability_surface.descriptors capability_surface
  |> List.exists (fun admitted -> admitted == descriptor)
;;

let frozen_surface_admission_error_to_execution error =
  let requested_tool, detail_fields =
    match error with
    | Descriptor_outside_frozen_surface { requested_tool; descriptor_id } ->
      requested_tool, [ "descriptor_id", `String descriptor_id ]
    | Tool_name_absent_from_frozen_surface { requested_tool } ->
      requested_tool, []
  in
  let data =
    `Assoc
      ([ "ok", `Bool false
       ; "error", `String "tool_outside_frozen_capability_surface"
       ; "tool", `String requested_tool
         (* Spelled here rather than taken from
            [Keeper_capability_surface.capability_availability], which
            describes a row in the frozen inventory. This is the opposite
            situation -- the name the model called is in no row at all. The
            two read the same because that type used to carry an
            [Outside_tool_surface] constructor, which #31728 made unreachable
            and this purge removed. *)
       ; "availability", `String "outside_tool_surface"
       ]
       @ detail_fields)
  in
  Keeper_tool_execution.failure_data
    ~class_:Tool_result.Policy_rejection
    ~effect_disposition:Tool_result.Proven_pre_effect
    ~message:(Yojson.Safe.to_string data)
    data
;;

let admit_descriptor capability_authority ~requested_tool descriptor =
  match capability_authority with
  | Keeper_tool_runtime.Compatibility_meta -> Ok ()
  | Keeper_tool_runtime.Frozen_surface capability_surface ->
    if descriptor_is_in_frozen_surface capability_surface descriptor
    then Ok ()
    else
      Error
        (Descriptor_outside_frozen_surface
           { requested_tool; descriptor_id = descriptor.Keeper_tool_descriptor.id })
;;

let admit_tool_name capability_authority requested_tool =
  match capability_authority with
  | Keeper_tool_runtime.Compatibility_meta -> Ok ()
  | Keeper_tool_runtime.Frozen_surface capability_surface ->
    let is_exposed_name descriptor =
      Keeper_tool_descriptor.keeper_model_names descriptor
      |> List.exists (String.equal requested_tool)
    in
    if
      Keeper_capability_surface.descriptors capability_surface
      |> List.exists is_exposed_name
    then Ok ()
    else Error (Tool_name_absent_from_frozen_surface { requested_tool })
;;

let resolve_descriptor_dispatch = function
  | Descriptor_route (_, Some raw_output) | Validation_rejected raw_output ->
    Return_output raw_output
  | Descriptor_route (descriptor, None) -> Return_descriptor_invariant descriptor
  | Undescribed_route -> Try_registered_only_route
;;

let descriptor_route_invariant_payload ~tool_name descriptor =
  let descriptor_id = descriptor.Keeper_tool_descriptor.id in
  let executor =
    Keeper_tool_descriptor.executor_to_string descriptor.executor
  in
  let runtime_handler =
    Keeper_tool_descriptor.runtime_handler_to_string descriptor.runtime_handler
  in
  `Assoc
    [ "ok", `Bool false
    ; "error", `String "keeper_tool_descriptor_route_invariant"
    ; "failure_class", `String "runtime_failure"
    ; "tool", `String tool_name
    ; "descriptor_id", `String descriptor_id
    ; "executor", `String executor
    ; "runtime_handler", `String runtime_handler
    ]
;;

let descriptor_route_invariant_error ~keeper_name ~tool_name descriptor =
  let payload = descriptor_route_invariant_payload ~tool_name descriptor in
  let descriptor_id = descriptor.Keeper_tool_descriptor.id in
  let executor =
    Keeper_tool_descriptor.executor_to_string descriptor.executor
  in
  let runtime_handler =
    Keeper_tool_descriptor.runtime_handler_to_string descriptor.runtime_handler
  in
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string AgentToolDispatchRuntimeFailures)
    ~labels:
      [ "keeper", keeper_name
      ; "tool", tool_name
      ; "reason", "descriptor_route_unhandled"
      ; "descriptor_id", descriptor_id
      ; "executor", executor
      ; "runtime_handler", runtime_handler
      ]
    ();
  (* The invariant break is a Runtime_failure by construction; deriving the
     level from that same class keeps the log honest if the classification
     ever changes (#28895 review). *)
  let failure_class = Tool_result.Runtime_failure in
  Log.Keeper.emit
    (Tool_result.log_level_of_failure_class failure_class)
    ~keeper_name
    ~category:Log.Tool
    ~details:
      (`Assoc
         [ "error_kind", `String "keeper_tool_descriptor_route_invariant"
         ; "tool", `String tool_name
         ; "descriptor_id", `String descriptor_id
         ; "executor", `String executor
         ; "runtime_handler", `String runtime_handler
         ])
    "keeper descriptor route resolved but its typed runtime handler returned no result";
  Keeper_tool_execution.failure_data
    ~class_:failure_class
    ~message:(Yojson.Safe.to_string payload)
    payload
;;

(* ── Tool execution dispatch ──────────────────────────────────── *)

let runtime_context
      ~config
      ~meta
      ~publication_recovery
      ~ctx_work
      ?turn_sandbox_factory
      ?sw
      ?clock
      ?proc_mgr
      ?net
      ?mcp_session_id
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~capability_authority
      ()
  =
  Keeper_tool_runtime.
    { config
    ; meta
    ; publication_recovery
    ; ctx_work
    ; turn_sandbox_factory
    ; sw
    ; clock
    ; proc_mgr
    ; net
    ; mcp_session_id
    ; continuation_channel
    ; gate_context
    ; gate_grant
    ; capability_authority
    }
;;

let execute_keeper_tool_descriptor_with_authority
      ~capability_authority
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(publication_recovery :
          Keeper_publication_recovery_availability.turn_context)
      ~(ctx_work : working_context)
      ?turn_sandbox_factory
      ?sw
      ?clock
      ?proc_mgr
      ?net
      ?mcp_session_id
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~(descriptor : Keeper_tool_descriptor.t)
      ~(input : Yojson.Safe.t)
      ()
  =
  match
    admit_descriptor
      capability_authority
      ~requested_tool:descriptor.internal_name
      descriptor
  with
  | Error error -> frozen_surface_admission_error_to_execution error
  | Ok () ->
  match Keeper_tool_descriptor.find_id descriptor.id with
  | Some canonical when canonical == descriptor ->
    let context =
      runtime_context
        ~config
        ~meta
        ~publication_recovery
        ~ctx_work
        ?turn_sandbox_factory
        ?sw
        ?clock
        ?proc_mgr
        ?net
        ?mcp_session_id
        ?continuation_channel
        ?gate_context
        ?gate_grant
        ~capability_authority
        ()
    in
    (match Keeper_tool_runtime.handle context ~descriptor ~args:input with
     | Some execution -> execution
     | None ->
       descriptor_route_invariant_error
         ~keeper_name:meta.name
         ~tool_name:descriptor.internal_name
         descriptor)
  | Some _ | None ->
    let data =
      `Assoc
        [ "ok", `Bool false
        ; "error", `String "noncanonical_keeper_tool_descriptor"
        ; "descriptor_id", `String descriptor.id
        ]
    in
    Keeper_tool_execution.failure_data
      ~class_:Tool_result.Runtime_failure
      ~message:(Yojson.Safe.to_string data)
      data
;;

let execute_keeper_tool_descriptor_for_capability_surface_with_outcome
      ~capability_surface
  =
  execute_keeper_tool_descriptor_with_authority
    ~capability_authority:
      (Keeper_tool_runtime.Frozen_surface capability_surface)
;;

let execute_keeper_tool_call_with_authority
      ~capability_authority
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(publication_recovery :
          Keeper_publication_recovery_availability.turn_context)
      ~(ctx_work : working_context)
      ?turn_sandbox_factory
      (* RFC-0182 Phase 5 PR-A.2: optional Eio resources threaded to
         Keeper_tool_runtime.context for Eio-bound descriptor handlers. *)
      ?sw
      ?clock
      ?proc_mgr
      ?net
      ?mcp_session_id
      ?continuation_channel
      ?gate_context
      ?gate_grant
      ~(name : string)
      ~(input : Yojson.Safe.t)
      ()
  : executed_tool_result
  =
  let args = input in
  let surface_admission = admit_tool_name capability_authority name in
  match surface_admission with
  | Error error -> frozen_surface_admission_error_to_execution error
  | Ok () ->
       let keeper_tool_runtime_context =
         runtime_context
           ~config
           ~meta
           ~publication_recovery
           ~ctx_work
           ?turn_sandbox_factory
           ?sw
           ?clock
           ?proc_mgr
           ?net
           ?mcp_session_id
           ?continuation_channel
           ?gate_context
           ?gate_grant
           ~capability_authority
           ()
       in
       let descriptor_dispatch =
         match
           Keeper_tool_descriptor_resolution.validated_descriptor_and_input_for_tool_call
             ~tool_name:name
             ~input:args
         with
         | Some (Ok (descriptor, translated_args)) ->
           Descriptor_route
             ( descriptor
             , Keeper_tool_runtime.handle
                 keeper_tool_runtime_context
                 ~descriptor
                 ~args:translated_args )
         | Some (Error validation_result) ->
           Validation_rejected (Keeper_tool_execution.of_tool_result validation_result)
         | None -> Undescribed_route
       in
       match resolve_descriptor_dispatch descriptor_dispatch with
       | Return_output execution -> execution
       | Return_descriptor_invariant descriptor ->
         descriptor_route_invariant_error
           ~keeper_name:meta.name
           ~tool_name:name
           descriptor
       | Try_registered_only_route ->
         (* Registered-only tools are a separate dispatch source. A descriptor
            route that resolves but returns [None] is handled above as a typed
            invariant failure and can never fall through to this backend. *)
         let unknown_name = name in
         (match
            Keeper_tool_registered_runtime.handle_registered_tool_with_outcome
              ~config
              ~keeper_name:meta.name
              ~name:unknown_name
              ~args
          with
          | Some execution -> execution
          | None ->
            let fields =
              [ "ok", `Bool false
              ; "error", `String "unknown_tool"
              ; "tool", `String unknown_name
              ]
            in
            let data = `Assoc fields in
            Keeper_tool_execution.failure_data
              ~class_:Tool_result.Runtime_failure
              ~message:(Yojson.Safe.to_string data)
              data)
;;

let execute_keeper_tool_call_for_capability_surface_with_outcome
      ~capability_surface
  =
  execute_keeper_tool_call_with_authority
    ~capability_authority:
      (Keeper_tool_runtime.Frozen_surface capability_surface)
;;

module Compatibility = struct
  let execute_keeper_tool_descriptor_with_outcome =
    execute_keeper_tool_descriptor_with_authority
      ~capability_authority:Keeper_tool_runtime.Compatibility_meta
  ;;

  let execute_keeper_tool_call_with_outcome =
    execute_keeper_tool_call_with_authority
      ~capability_authority:Keeper_tool_runtime.Compatibility_meta
  ;;

  let execute_keeper_tool_call
        ~(config : Workspace.config)
        ~(meta : keeper_meta)
        ~(publication_recovery :
            Keeper_publication_recovery_availability.turn_context)
        ~(ctx_work : working_context)
        ?turn_sandbox_factory
        ~(name : string)
        ~(input : Yojson.Safe.t)
        ()
    : string
    =
    let result =
      execute_keeper_tool_call_with_outcome
        ~config
        ~meta
        ~publication_recovery
        ~ctx_work
        ?turn_sandbox_factory
        ~name
        ~input
        ()
    in
    result.Keeper_tool_execution.raw_output
  ;;
end

module For_testing = struct
  type descriptor_route_kind =
    | Output
    | Invariant
    | Registered_only

  let descriptor_route_invariant_payload = descriptor_route_invariant_payload

  let descriptor_route_kind ~descriptor ~output =
    let output = Option.map Keeper_tool_execution.success output in
    match resolve_descriptor_dispatch (Descriptor_route (descriptor, output)) with
    | Return_output _ -> Output
    | Return_descriptor_invariant _ -> Invariant
    | Try_registered_only_route -> Registered_only
  ;;
end
