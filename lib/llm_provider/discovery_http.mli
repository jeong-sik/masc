(** Discovery_http — HTTP-client → typed-result helpers for the
    llama-server / OpenAI-compat discovery surface.

    Extracted from {!Discovery} (lines 93-121 in the pre-split
    [discovery.ml]) so the HTTP error-translation surface can be
    reused outside the discover loop — and so {!Discovery} no longer
    inlines [Http_client.http_error] pattern matching that has to be
    kept exhaustive twice.

    {!Discovery} binds these result-returning helpers for its protocol-specific
    probes. No boolean liveness helper exists: losing transport error context
    would create a silent diagnostic boundary. *)

(** GET [url] and decode the body as JSON.  Returns [Error msg] for
    non-2xx responses, transport errors, parser errors, and the
    closed-sum [Http_client.http_error] variants ([AcceptRejected],
    [NetworkError], [TimeoutError],
    [ProviderTerminal], [ProviderFailure]).  [ProviderTerminal] is
    surfaced defensively — discovery hits HTTP endpoints only, so
    CLI-subprocess terminals cannot reach this match. *)
val get_json
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> string
  -> (Yojson.Safe.t, string) result

(** GET [url] and return [Ok ()] iff the response status is 2xx. Non-2xx and
    transport failures retain explicit error context for endpoint-local
    observability. *)
val probe_liveness
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> string
  -> (unit, string) result
