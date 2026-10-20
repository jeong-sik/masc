(** Browser execution exposed through ordinary Add-on discovery and selected
    input/output middleware. The caller identity comes only from the private
    host-context envelope. Neither this tool nor its schemas grant authority. *)
val definition : Mcp_protocol.Mcp_types.tool
val invoke : owner:Browser_addon_owner.t -> principal:Lane_addon_call_context.principal ->
  Yojson.Safe.t -> Mcp_protocol.Mcp_types.tool_result
(** Select once, retain the concrete client in the receipt, and dispatch once.
    Failed and partial receipts retain their payload and effect disposition.
    Upload paths and downloads require the still-pending host artifact broker. *)
