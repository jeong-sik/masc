(** Fetch an OAuth Client ID Metadata Document named by a client id.

    The authorization endpoint calls this for an https [client_id]
    (MCP 2026-07-28 client registration). The fetch is a plain GET: the host
    must resolve only to public addresses ({!Server_outbound_address}), no
    redirect is followed, the body may be at most
    {!Auth_oauth_client_metadata.max_document_bytes}, and only HTTP 200 is a
    document. Every fetch goes to the network; nothing is cached. *)

val fetch_timeout_sec : float

val fetch :
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  net:Eio_context.eio_net ->
  Auth_oauth_client_metadata.document_url ->
  (string, string) result
(** [Ok body] for an HTTP 200 answer. [Error] says why there is no document:
    a refused address, a network or timeout failure, an oversized body, or
    another status. *)

val of_server_state :
  Mcp_server.server_state ->
  Auth_oauth_client_metadata.document_url ->
  (string, string) result
(** {!fetch} with the server's clock and network, falling back to the
    process-wide ones. [Error] when neither exists. *)
