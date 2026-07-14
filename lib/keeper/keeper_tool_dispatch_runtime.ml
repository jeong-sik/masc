(** Keeper_tool_dispatch_runtime — exact keeper tool execution dispatch.

    Split into multiple layers:
    - [Keeper_tool_registry]: declarative tool name lists (data)
    - [Keeper_tool_policy]: exact descriptor/registry schema join
    - [Keeper_tool_*_runtime]: dedicated runtime modules for tool categories
    - This module: execution dispatch + shared bookkeeping *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime
include Keeper_tool_registry
include Keeper_tool_policy

type keeper_tool_call_recorder =
  tool_name:string -> success:bool -> duration_ms:int -> unit

let default_keeper_tool_call_recorder ~tool_name:_ ~success:_ ~duration_ms:_ = ()
let keeper_tool_call_recorder : keeper_tool_call_recorder Atomic.t =
  Atomic.make default_keeper_tool_call_recorder

let set_on_keeper_tool_call (f : keeper_tool_call_recorder) =
  Atomic.set keeper_tool_call_recorder f
;;

let record_keeper_tool_call ~tool_name ~success ~duration_ms =
  Atomic.get keeper_tool_call_recorder ~tool_name ~success ~duration_ms
;;

let unavailable_tool_search () =
  let data =
    `Assoc
      [ "ok", `Bool false
      ; "error", `String "tool_search_unavailable"
      ; "reason", `String "catalog_provider_not_injected"
      ]
  in
  Keeper_tool_execution.failure_data
    ~class_:Tool_result.Runtime_failure
    ~message:(Yojson.Safe.to_string data)
    data
;;

type execution_outcome =
  [ `Success
  | `Failure of Tool_result.tool_failure_class
  ]

type executed_tool_result =
  { raw_output : string
  ; data : Yojson.Safe.t option
  ; outcome : execution_outcome
  }

let executed_tool_result_of_execution (execution : Keeper_tool_execution.t) =
  match execution.outcome with
  | Keeper_tool_execution.Succeeded ->
    { raw_output = execution.raw_output
    ; data = execution.data
    ; outcome = `Success
    }
  | Keeper_tool_execution.Failed failure_class ->
    { raw_output = execution.raw_output
    ; data = execution.data
    ; outcome = `Failure failure_class
    }
;;

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
  Log.Keeper.emit
    Log.Error
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
    ~class_:Tool_result.Runtime_failure
    ~message:(Yojson.Safe.to_string payload)
    payload
;;

(* ── Tool execution dispatch ──────────────────────────────────── *)

let execute_keeper_tool_call_with_outcome
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(publication_recovery_registry :
          Fs_compat.publication_recovery_registry)
      ~(publication_recovery_access : Fs_compat.publication_recovery_access)
      ~(ctx_work : working_context)
      ?turn_sandbox_factory
      ~(exec_cache : Masc_exec.Exec_cache.t option)
      ?search_fn
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
  let effective_search_fn =
         match search_fn with
         | Some f -> f
         | None -> unavailable_tool_search
       in
       let keeper_tool_runtime_context =
         Keeper_tool_runtime.
                       { config
                       ; meta
                       ; publication_recovery_registry
                       ; publication_recovery_access
                       ; ctx_work
                       ; turn_sandbox_factory
                       ; exec_cache
           ; search_fn = effective_search_fn
           ; (* RFC-0182 Phase 5 PR-A.2: Eio resources threaded from
                caller via labeled ? params.  Callers without Eio
                context (OAS handler, tests) leave them unset. *)
             sw
           ; clock
           ; proc_mgr
           ; net
           ; mcp_session_id
           ; continuation_channel
           ; gate_context
           ; gate_grant
           }
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
       | Return_output execution -> executed_tool_result_of_execution execution
       | Return_descriptor_invariant descriptor ->
         executed_tool_result_of_execution
           (descriptor_route_invariant_error
              ~keeper_name:meta.name
              ~tool_name:name
              descriptor)
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
          | Some execution -> executed_tool_result_of_execution execution
          | None ->
            let fields =
              [ "ok", `Bool false
              ; "error", `String "unknown_tool"
              ; "tool", `String unknown_name
              ]
            in
            let data = `Assoc fields in
            executed_tool_result_of_execution
              (Keeper_tool_execution.failure_data
                 ~class_:Tool_result.Runtime_failure
                 ~message:(Yojson.Safe.to_string data)
                 data))
;;

let execute_keeper_tool_call
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(publication_recovery_registry :
          Fs_compat.publication_recovery_registry)
      ~(publication_recovery_access : Fs_compat.publication_recovery_access)
      ~(ctx_work : working_context)
      ?turn_sandbox_factory
      ~(exec_cache : Masc_exec.Exec_cache.t option)
      ?search_fn
      ~(name : string)
      ~(input : Yojson.Safe.t)
      ()
  : string
  =
  let result =
    execute_keeper_tool_call_with_outcome
      ~config
      ~meta
      ~publication_recovery_registry
      ~publication_recovery_access
      ~ctx_work
                  ?turn_sandbox_factory
                  ~exec_cache
      ?search_fn
      ~name
      ~input
      ()
  in
  result.raw_output
;;

module For_testing = struct
  type descriptor_route_kind =
    | Output
    | Invariant
    | Registered_only

  let set_on_keeper_tool_call = set_on_keeper_tool_call
  let record_keeper_tool_call = record_keeper_tool_call
  let descriptor_route_invariant_payload = descriptor_route_invariant_payload

  let descriptor_route_kind ~descriptor ~output =
    let output = Option.map Keeper_tool_execution.success output in
    match resolve_descriptor_dispatch (Descriptor_route (descriptor, output)) with
    | Return_output _ -> Output
    | Return_descriptor_invariant _ -> Invariant
    | Try_registered_only_route -> Registered_only
  ;;
end
