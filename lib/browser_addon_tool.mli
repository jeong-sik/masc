(** Browser execution exposed through ordinary Add-on discovery and selected
    input/output middleware. The caller identity comes only from the private
    host-context envelope. Neither this tool nor its schemas grant authority. *)
val definition : Mcp_protocol.Mcp_types.tool
val command : Yojson.Safe.t -> (Browser_lane.verb, string) result
(** Decode the original command with its original route preference. No selection
    or dispatch takes place. Shared with mandatory host artifact finalization. *)
val invoke : owner:Browser_addon_owner.t -> principal:Lane_addon_call_context.principal ->
  Yojson.Safe.t -> Mcp_protocol.Mcp_types.tool_result
(** Select once, retain the concrete client in the receipt, and dispatch once.
    Failed and partial receipts retain their payload and effect disposition.
    Uploads consume a private host grant bound to the original caller/command.
    Completed owned downloads carry caller-bound grants for host finalization. *)
