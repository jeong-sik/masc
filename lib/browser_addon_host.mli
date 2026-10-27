(** Public host admission for the installed browser Add-ons. The caller
    supplies verified host authority; model arguments cannot select an
    installation. One handle retains every serving browser service with its
    own advertised tool across a workflow. Each source is served by exactly
    one of them: a source no service serves, or two do, is unusable alone,
    and the others are still chosen. Calls never retry or fall back to the
    core browser queue. *)
type t
val connect : config:Workspace.config -> access:Lane_addon_sources.access ->
  principal:Lane_addon_call_context.principal -> reserved:string list ->
  (t, Lane_addon_runtime.tool_call_error) result
(** [reserved] is the caller's complete host tool namespace, as in ordinary
    Add-on discovery. Visibility and name-collision checks remain authoritative.
    Only no serving browser service at all is refused here. *)
val call : t -> backend:Browser_lane.Backend.t -> arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result, Lane_addon_runtime.tool_call_error) result
(** Calls the service of [backend] through the ordinary exported-tool path,
    including installation-selected middleware and host mediation. The
    original result and failure metadata are returned without rewriting or
    promoting a partial effect. *)
val error_result : start_time:Tool_timing.started -> Lane_addon_runtime.tool_call_error -> Tool_result.result
val snapshot : t -> backend:Browser_lane.Backend.t -> (Yojson.Safe.t, Browser_addon_client.error) result
(** Read-only observation on the service of [backend]. This is not a tool
    invocation and does not select, start or replace a browser. *)
type snapshot_failure = Snapshot_unavailable of string | Snapshot_unreadable of string
(** The worker gave no snapshot, or gave one the host cannot decode. *)
val selection_snapshot : t -> (Browser_addon_observation.published * Browser_selection.snapshot, snapshot_failure) result
(** Every service's [Snapshot] reply, asked side by side, merged as the host
    chooses from it: the live clients of the services that serve a live
    source, and automation and Stagehand as their own service answered. A
    service that did not answer is left out of this choice only; no answer
    at all is the failure. A worker answers only while it serves, so a live
    lane it reports is on. A lost reply leaves the worker serving
    ({!Browser_addon_wire.changes_nothing}). *)
type receipt = {binding:Browser_binding.t;data:Yojson.Safe.t;
  raw_result:Mcp_protocol.Mcp_types.tool_result}
(** The original successful MCP receipt remains available if a caller's
    observation projection or persistence fails after command completion. *)
val issue : ?upload_paths:string list -> ?required_actions:Browser_capabilities.operation list ->
  t -> preference:Browser_selection.preference -> Browser_lane.verb ->
  (receipt, Tool_result.result) result
(** Choose the browser from the services' snapshots, invoke the advertised
    tool of the service that serves it once on that route, and decode its
    success receipt. A client that two services list is refused. An explicit owned
    route without [required_actions] needs no snapshot. The receipt names the
    browser the host chose; the worker states no identity. A worker refusal
    after the snapshot (the client left, the lane turned off) is returned as
    given, never sent to another browser. The selected schema hooks remain
    optional; wire decoding remains mandatory. Failed/partial replies preserve
    raw data and effect metadata. Malformed post-dispatch replies have unknown
    effect. *)

(** [upload_paths] must be an exact pending host snapshot batch, not caller
    paths, and the selection the owned automation route or an explicit live
    browser. The host prepares worker-owned copies over the original private
    connection, then uses the ordinary exported tool/hooks once. A failed or
    cancelled call is never replayed. *)
val parse_command : Yojson.Safe.t ->
  (Browser_selection.preference * Browser_lane.verb * Browser_capabilities.operation list * string option, string) result
(** The public command shape, decoded before any browser is chosen. *)
val command : t -> arguments:Yojson.Safe.t -> (Mcp_protocol.Mcp_types.tool_result, Tool_result.result) result
(** The public command shape: [lane] and [clientId] are optional, so a missing
    lane leaves the choice to the host, and [requiredActions] and [uploadId]
    pass as before. The host chooses as {!issue} does and returns the worker's
    result with the chosen browser's [browserSelection] and
    [browserConnection], in success and failure alike. *)
