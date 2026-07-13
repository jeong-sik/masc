(** Keeper_tool_dispatch_runtime — exact keeper tool execution dispatch.

    Split into multiple layers:
    - [Keeper_tool_registry]: declarative tool name lists (data)
    - [Keeper_tool_policy]: exact descriptor/registry schema join
    - [Keeper_tool_*_runtime]: dedicated runtime modules for tool categories
    - This module: execution dispatch + shared helpers (side-effects) *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime
include Keeper_tool_registry
include Keeper_tool_policy

let has_mutating_side_effect_with_input ~(tool_name : string) ~(input : Yojson.Safe.t)
  : bool
  =
  not (Keeper_tool_registry.is_read_only_with_input ~tool_name ~input)
;;

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
  `Assoc
    [ "ok", `Bool false
    ; "error", `String "tool_search_unavailable"
    ; "reason", `String "catalog_provider_not_injected"
    ]
;;

type tool_result_payload =
  | Structured_success
  | Structured_error
  | Plain_text
  | Malformed_structured of string

type execution_outcome =
  [ `Success
  | `Failure
  ]

type executed_tool_result =
  { raw_output : string
  ; outcome : execution_outcome
  ; payload_shape : tool_result_payload
  }

let looks_like_structured_payload payload =
  let len = String.length payload in
  let rec find_first_nonspace i =
    if i >= len
    then None
    else (
      match payload.[i] with
      | ' ' | '\t' | '\n' | '\r' -> find_first_nonspace (i + 1)
      | c -> Some c)
  in
  match find_first_nonspace 0 with
  | Some ('{' | '[') -> true
  | Some _ | None -> false
;;

let classify_tool_result_payload payload =
  if not (looks_like_structured_payload payload)
  then Plain_text
  else (
    match
      Safe_ops.parse_json_safe
        ~context:"Keeper_tool_dispatch_runtime.classify_tool_result_payload"
        payload
    with
    | Error msg -> Malformed_structured msg
    | Ok (`Assoc fields) ->
      let is_error =
        match List.assoc_opt "ok" fields with
        | Some (`Bool false) -> true
        | _ -> List.mem_assoc "error" fields
      in
      if is_error then Structured_error else Structured_success
    | Ok _ -> Structured_success)
;;

let inferred_outcome_of_result ~payload_shape =
  match payload_shape with
  | Structured_success | Plain_text -> `Success
  | Structured_error -> `Failure
  | Malformed_structured _ -> `Failure
;;

let make_executed_tool_result ?outcome raw_output =
  let payload_shape = classify_tool_result_payload raw_output in
  let outcome =
    match outcome with
    | Some explicit -> explicit
    | None -> inferred_outcome_of_result ~payload_shape
  in
  { raw_output; outcome; payload_shape }
;;

(* Descriptor and registered-only routes are distinct dispatch sources.
   Outcome is inferred from raw JSON via [classify_tool_result_payload]. *)

type descriptor_dispatch =
  | Descriptor_route of Keeper_tool_descriptor.t * string option
  | Validation_rejected of string
  | Undescribed_route

type descriptor_dispatch_resolution =
  | Return_output of string
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
  Yojson.Safe.to_string payload
;;

(* ── Tool execution dispatch ──────────────────────────────────── *)

let execute_keeper_tool_call_with_outcome
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
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
  let meta =
    match Keeper_registry.get_with_health ~base_path:config.base_path meta.name with
    | Some (entry, Keeper_registry.Healthy) -> entry.meta
    | Some (_, health) ->
      let reason_label =
        match health with
        | Keeper_registry.Healthy -> "healthy"
        | Keeper_registry.Meta_validation_failed _ -> "meta_validation_failed"
        | Keeper_registry.Lifecycle_transaction_reserved _ ->
          "lifecycle_transaction_reserved"
        | Keeper_registry.Required_field_missing _ -> "required_field_missing"
        | Keeper_registry.Base_path_mismatch _ -> "base_path_mismatch"
        | Keeper_registry.Name_mismatch _ -> "name_mismatch"
      in
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string RegistryInvalidEntry)
        ~labels:
          [ "operation", "tool_dispatch_fallback"
          ; "name", meta.name
          ; "reason", reason_label
          ]
        ();
      meta
    | None -> meta
  in
  let observe_malformed_result (result : executed_tool_result) =
    match result.outcome, result.payload_shape with
    | (`Success | `Failure), Malformed_structured parse_error ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string AgentToolDispatchRuntimeFailures)
        ~labels:[ "keeper", meta.name; "tool", name ]
        ();
      Log.Keeper.error ~keeper_name:meta.name
        "tool:%s produced malformed structured payload: %s"
        name
        parse_error;
      result
    | (`Success | `Failure),
      (Structured_error | Structured_success | Plain_text) ->
      result
  in
  observe_malformed_result
    (
       let effective_search_fn =
         match search_fn with
         | Some f -> f
         | None -> unavailable_tool_search
       in
       let keeper_tool_runtime_context =
         Keeper_tool_runtime.
                       { config
                       ; meta
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
           let raw_payload = Yojson.Safe.to_string (Tool_result.data validation_result) in
           Validation_rejected raw_payload
         | None -> Undescribed_route
       in
       match resolve_descriptor_dispatch descriptor_dispatch with
       | Return_output raw_output -> make_executed_tool_result raw_output
       | Return_descriptor_invariant descriptor ->
         make_executed_tool_result
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
            Keeper_tool_registered_runtime.handle_registered_tool
              ~config
              ~keeper_name:meta.name
              ~name:unknown_name
              ~args
          with
          | Some raw_output -> make_executed_tool_result raw_output
          | None ->
            let fields =
              [ "ok", `Bool false
              ; "error", `String "unknown_tool"
              ; "tool", `String unknown_name
              ]
            in
            make_executed_tool_result (Yojson.Safe.to_string (`Assoc fields))))
;;

let execute_keeper_tool_call
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
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
    match resolve_descriptor_dispatch (Descriptor_route (descriptor, output)) with
    | Return_output _ -> Output
    | Return_descriptor_invariant _ -> Invariant
    | Try_registered_only_route -> Registered_only
  ;;
end
