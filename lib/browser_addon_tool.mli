(** Browser execution exposed through ordinary Add-on discovery and selected
    input/output middleware. The caller identity comes only from the private
    host-context envelope. Neither this tool nor its schemas grant authority. *)
val definition : Mcp_protocol.Mcp_types.tool
val command : Yojson.Safe.t -> (Browser_lane.route * Browser_lane.verb, string) result
(** Decode the route the host chose and the original command. No dispatch
    takes place. Shared with mandatory host artifact finalization, which runs
    before the host names the browser in the receipt. *)
val invoke : owner:Browser_addon_owner.t -> principal:Lane_addon_call_context.principal ->
  Yojson.Safe.t -> Mcp_protocol.Mcp_types.tool_result
(** Run the command once on the route the host chose. A route to a client that
    is not connected here, or to a browser this worker does not run, is refused
    before dispatch. The worker chooses nothing and states no browser identity;
    the host adds it to the receipt. Failed and partial receipts retain their
    payload and effect disposition. Their failure class is what the reply
    says: a refusal before effect, a browser that is not here or did not
    finish, an argument the caller can correct, or a reply this tool cannot
    read.
    Uploads consume a private host grant bound to the original caller/command.
    Completed owned downloads carry caller-bound grants for host finalization. *)
