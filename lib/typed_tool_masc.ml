(** Typed_tool_masc — MASC-specific typed tool bridge.

    @since 2.260.0 *)

type ('input, 'output) t = {
  oas_tool : ('input, 'output) Agent_sdk.Typed_tool.t;
  module_tag : Tool_dispatch.module_tag;
  is_read_only : bool;
  is_destructive : bool;
  is_idempotent : bool;
  visibility : Tool_catalog.visibility;
  requires_join : bool;
}

let create ~name ~description ~module_tag ~params ~parse ~handler ~encode
    ?(is_read_only = false) ?(is_destructive = false) ?(is_idempotent = false)
    ?(visibility = Tool_catalog.Default) ?(requires_join = false) () =
  let oas_tool = Agent_sdk.Typed_tool.create
    ~name ~description ~params ~parse ~handler ~encode () in
  { oas_tool; module_tag; is_read_only; is_destructive;
    is_idempotent; visibility; requires_join }

(** Build a dispatch handler for the typed tool.
    The handler is registered via [Tool_spec.Direct] for a specific tool name,
    so the [name] parameter will always match — no guard needed. *)
let make_dispatch_handler (tool : (_, _) t) : Tool_dispatch.handler =
  fun ~name:_ ~args ->
    match Agent_sdk.Typed_tool.execute tool.oas_tool args with
    | Ok { content } -> Some (true, content)
    | Error { message; _ } -> Some (false, message)

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
    ~requires_join:tool.requires_join
    ()

let register tool =
  let spec = to_spec tool in
  Tool_spec.register spec

let to_oas tool = tool.oas_tool
let name tool = Agent_sdk.Typed_tool.name tool.oas_tool
let schema tool = Agent_sdk.Typed_tool.schema tool.oas_tool
