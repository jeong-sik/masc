(** OAuth Client ID Metadata Documents for the built-in authorization server.

    An MCP client may use an https URL as its [client_id]. The URL names a
    JSON document that lists the client's name and redirect URIs
    (draft-ietf-oauth-client-id-metadata-document-00; MCP 2026-07-28 client
    registration). This module decides which client ids are such URLs, reads
    a fetched document, and matches a requested redirect URI against it.
    Fetching, and the address policy for the fetch, belong to the caller. *)

type document_url = private string
(** An https client id that names a metadata document, kept byte-for-byte as
    the client sent it: the document's [client_id] must equal it exactly. *)

type client_id =
  | Registered of string
      (** Any client id that is not an https URL, such as one issued by
          Dynamic Client Registration. *)
  | Document of document_url

val has_control_character : string -> bool
(** [true] when the text holds a C0 control, DEL, or a UTF-8 encoded C1
    control (U+0080..U+009F). A terminal or a page may act on any of them,
    so client-chosen text with one is refused. *)

val is_plain_url_text : string -> bool
(** No space, control character or backslash, and ocaml-uri prints the text
    back unchanged. A string it would print differently is not the URL that
    would be fetched or redirected to. *)

val classify_client_id : string -> (client_id, string) result
(** A client id with the https scheme must be a usable document URL. It is
    plain URL text: no space, control character or backslash, and ocaml-uri
    prints it back unchanged. It has a host and a path other than ["/"], and
    no userinfo, fragment, query or ["."] / [".."] segment, percent-encoded
    or not (draft section 3; the draft only says SHOULD NOT for a query, this
    server refuses one). The error names the rule the URL broke. Every other
    client id is [Registered]. *)

val max_document_bytes : int
(** 5 KiB, the limit draft section 6.6 recommends. *)

type document = private
  { client_id : document_url
  ; client_name : string
  ; redirect_uris : string list
  }

val parse_document : document_url -> string -> (document, string) result
(** Read a fetched document. It must be at most [max_document_bytes], a JSON
    object without repeated member names, and carry [client_id] equal to the
    URL, a non-blank [client_name], and a non-empty [redirect_uris] array
    without duplicates (MCP 2026-07-28). A [client_name] with a control
    character is refused; its length is the caller's limit. [client_secret] and
    [client_secret_expires_at] are refused (draft section 4.5).
    [token_endpoint_auth_method], [grant_types] and [response_types] must,
    when present, stay within what this server supports: a public client
    using the authorization code and refresh token grants. Other members are
    ignored. *)

val redirect_uri_allowed : document -> string -> bool
(** [true] when the requested redirect URI is plain URL text (see
    {!classify_client_id}) and equals a listed one, or both are loopback
    [http] URIs with the same host, path and query whatever their ports. A
    native client picks a free port when it starts listening, so its
    document cannot name one. RFC 8252 section 7.3 asks this for loopback IP
    literals; [localhost] is treated the same because Claude Code's document
    lists it, although RFC 8252 section 8.3 does not recommend it.

    Listed entries are not checked here. The caller must still require the
    requested URI to be one it is willing to redirect to. *)
