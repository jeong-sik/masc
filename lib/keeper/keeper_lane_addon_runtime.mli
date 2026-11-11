val snapshot : config:Workspace.config -> keeper_name:string ->
  Lane_addon_runtime.export_snapshot
val data_of_worker_result : Mcp_protocol.Mcp_types.tool_result -> Yojson.Safe.t
(** The worker's reply as the call's [data]: the reply's JSON with each image
    or audio block cut to its type, MIME type and base64 length. On a
    successful reply the bytes stay in the call's [content_blocks], so a model
    still reads them once. A failed result has no [content_blocks], so the
    bytes of an image in an error reply reach no model; the DOS and MSX
    workers attach images to successful replies only. Text blocks,
    [structuredContent], [isError] and [_meta] are unchanged. *)

val call :
  config:Workspace.config -> keeper_name:string ->
  export:Lane_addon_tool_export.t -> arguments:Yojson.Safe.t -> Keeper_tool_execution.t
