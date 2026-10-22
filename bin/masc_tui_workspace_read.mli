(** Workspace-owned JSON reads. The caller fiber binds the expected root;
    the concrete path is prepared before transport crosses an IO boundary. *)
type proof = Request_precondition | Health_identity

val with_binding
  : host:string
  -> port:int
  -> expected:Masc.Tui_decode.server_identity
  -> proof:proof
  -> (unit -> 'a)
  -> 'a

val read_json
  : kept_reads:Yojson.Safe.t Masc_tui_kept_reads.t
  -> address_of:(path:string -> string)
  -> send:(path:string -> headers:(string * string) list -> (Masc_http_client.response, string) result)
  -> decode:(allow_empty:bool -> status_code:int -> body:string -> (Yojson.Safe.t, string) result)
  -> host:string
  -> port:int
  -> path:string
  -> (Yojson.Safe.t, string) result
(** Bound reads reject endpoint changes and require a matching server admission
    receipt, including for 304, before publishing or reusing JSON. Health proof
    validates the returned identity instead. Unbound reads retain their existing
    behavior. This authorizes observation only, never effects or replay. *)

type response_failure = Transport_failed of string | Workspace_refused of string

val read_response
  : send:(path:string -> (Masc_http_client.response, string) result)
  -> host:string -> port:int -> path:string
  -> (Masc_http_client.response, response_failure) result
(** Uncached response under the original request precondition. Prepares the
    concrete path before transport, rejects endpoint changes and validates the
    response admission receipt. Status/body decoding stays with the typed
    consumer. Health-identity bindings refuse here because raw responses cannot
    establish the decoded health identity. Unbound callers retain raw reads. *)

val read_bytes
  : send:(path:string -> (Masc_http_client.response, string) result)
  -> host:string -> port:int -> path:string -> (string, string) result
(** Bind the actual binary GET and validate the same workspace admission
    receipt as JSON reads. The transport caller enforces the body size bound.
    Unbound and health-identity-only contexts cannot authorize binary content.
    No cache, content decoding or effect authorization is involved. *)
