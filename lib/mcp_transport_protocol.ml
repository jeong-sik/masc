(** MCP Protocol Utilities.
    HTTP content negotiation for MCP Streamable HTTP transport.
    Delegates parsing to {!Mcp_protocol.Http_negotiation} (SDK);
    adds [accept_mode] with [Legacy_accepted] for backward-compat gating.

    SDK workarounds (case + quality):
    - SDK [parse_accept_header] preserves original case; HTTP media types
      are case-insensitive (RFC 7231 §3.1.1.1).  Wrappers lowercase
      type/subtype before comparison.
    - SDK [accepts_sse] / [accepts_json] do not filter [q=0]
      (mcp-protocol-sdk#80).  Wrappers enforce [q > 0] per §5.3.1. *)

module Http_negotiation = struct
  (** MASC-specific accept classification.
      [Legacy_accepted] has no SDK equivalent — it gates on
      [MASC_ALLOW_LEGACY_ACCEPT] to accept requests that lack both
      JSON and SSE in the Accept header. *)
  type accept_mode =
    | Streamable
    | Legacy_accepted
    | Rejected

  (* Re-export SDK constants so callers' [Http_negotiation.sse_content_type]
     keeps compiling without an extra open. *)
  let sse_content_type = Mcp_protocol.Http_negotiation.sse_content_type
  let json_content_type = Mcp_protocol.Http_negotiation.json_content_type

  (** Quality-aware, case-insensitive predicate using SDK's parser.
      [check ~type_ ~subtype] receives lowercased values. *)
  let exists_accepted h ~check =
    let media_types = Mcp_protocol.Http_negotiation.parse_accept_header h in
    List.exists
      (fun (mt : Mcp_protocol.Http_negotiation.media_type) ->
        mt.quality > 0.0
        && check
             ~type_:(String.lowercase_ascii mt.type_)
             ~subtype:(String.lowercase_ascii mt.subtype))
      media_types

  let accepts_sse_header = function
    | None -> false
    | Some h ->
        exists_accepted h ~check:(fun ~type_ ~subtype ->
            type_ = "text" && subtype = "event-stream")

  let accepts_json = function
    | None -> false
    | Some h ->
        exists_accepted h ~check:(fun ~type_ ~subtype ->
            (type_ = "application" && subtype = "json")
            || (type_ = "*" && subtype = "*"))

  let accepts_streamable_mcp = function
    | None -> false
    | Some h ->
        exists_accepted h ~check:(fun ~type_ ~subtype ->
            type_ = "application" && subtype = "json")
        && exists_accepted h ~check:(fun ~type_ ~subtype ->
               type_ = "text" && subtype = "event-stream")

  let classify_mcp_accept ~allow_legacy accept_header =
    if accepts_streamable_mcp accept_header then Streamable
    else if allow_legacy then Legacy_accepted
    else Rejected
end
