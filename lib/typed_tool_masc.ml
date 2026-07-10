(** Typed_tool_masc — MASC-specific typed tool bridge.

    @since 2.260.0 *)

type ('input, 'output) t = {
  oas_tool : ('input, 'output) Agent_sdk.Typed_tool.t;
  module_tag : Tool_dispatch.module_tag;
  is_read_only : bool;
  is_destructive : bool;
  is_idempotent : bool;
  visibility : Tool_catalog.visibility;
  effect_domain : Tool_catalog.effect_domain option;
  required_permission : Masc_domain.permission;
}

let create ~name ~description ~module_tag ~params ~parse ~handler ~encode
    ~required_permission
    ?(is_read_only = false) ?(is_destructive = false) ?(is_idempotent = false)
    ?(visibility = Tool_catalog.Default)
    ?effect_domain () =
  let oas_tool = Agent_sdk.Typed_tool.create
    ~name ~description ~params ~parse ~handler ~encode () in
  { oas_tool; module_tag; is_read_only; is_destructive;
    is_idempotent; visibility; effect_domain; required_permission }

(** Build a dispatch handler for the typed tool.
    The handler is registered via [Tool_spec.Direct] for a specific tool name,
    so the [name] parameter will always match — no guard needed. *)
let make_dispatch_handler (tool : (_, _) t) : Tool_dispatch.handler =
  fun ~name ~args ->
    let start_time = Time_compat.now () in
    match Agent_sdk.Typed_tool.execute tool.oas_tool args with
    | Ok { content; _ } -> Some (Tool_result.ok ~tool_name:name ~start_time content)
    | Error { message; recoverable; error_class } ->
      (* RFC-0189: source-typed mapping from [Agent_sdk.tool_error]
         to [Tool_result.tool_failure_class].  The SDK's typed
         error already carries the signal — previously discarded
         in favour of the auto-classify path's [Runtime_failure]
         default.

         Mapping (matches the SDK's own [recoverable] /
         [error_class] semantics — see
         [agent_sdk/llm_provider/types.mli]):
         - [recoverable=true] or [error_class=Some Transient]
           -> [Transient_error] (caller retry is safe).
         - [error_class=Some Deterministic] (and not recoverable)
           -> [Workflow_rejection] (caller input rejected;
              retry without changes won't help).
         - Otherwise ([Unknown] / [None] / non-recoverable)
           -> [Runtime_failure] (preserve original auto-classify
              default; surface as severity-elevated upstream). *)
      let failure_class : Tool_result.tool_failure_class =
        if recoverable then Tool_result.Transient_error
        else
          match error_class with
          | Some Agent_sdk.Types.Transient ->
            Tool_result.Transient_error
          | Some Agent_sdk.Types.Deterministic ->
            Tool_result.Workflow_rejection
          | Some Agent_sdk.Types.Unknown | None ->
            Tool_result.Runtime_failure
      in
      Some
        (Tool_result.error
           ~failure_class:(Some failure_class)
           ~tool_name:name ~start_time message)

let to_spec tool =
  let schema = Agent_sdk.Typed_tool.schema tool.oas_tool in
  let input_schema = Agent_sdk.Types.params_to_input_schema schema.parameters in
  Tool_spec.create
    ~name:schema.name
    ~description:schema.description
    ~module_tag:tool.module_tag
    ~input_schema
    ~handler_binding:(Tool_spec.Direct (make_dispatch_handler tool))
    ~is_read_only:tool.is_read_only
    ~is_destructive:tool.is_destructive
    ~is_idempotent:tool.is_idempotent
    ~visibility:tool.visibility
    ~required_permission:tool.required_permission
    ?effect_domain:tool.effect_domain
    ()

let register tool =
  let spec = to_spec tool in
  Tool_spec.register spec

let to_oas tool = tool.oas_tool
let name tool = Agent_sdk.Typed_tool.name tool.oas_tool
let schema tool = Agent_sdk.Typed_tool.schema tool.oas_tool
