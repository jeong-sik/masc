(** Response cache interface for LLM completions.

    Consumers inject their own cache backend (in-memory, file, Redis, etc.)
    via the [cache] record. AGENT_CORE never depends on a specific implementation.

    @since 0.54.0

    @stability Internal
    @since 0.93.1 *)

(** Cache backend interface. Implementations must be fiber-safe. *)
type t =
  { get : key:string -> Yojson.Safe.t option
    (** Look up a cached response by key. Returns [None] on miss. *)
  ; set : key:string -> ttl_sec:int -> Yojson.Safe.t -> unit
    (** Store a response with a TTL in seconds. *)
  }

(** Compute a deterministic identity component from request parameters.

    This retains conservative caller parameters, endpoint and secret identity.
    Transport-only settings are excluded; the config record is matched field
    by field so a new field requires an explicit decision.

    This component does not include provider projection or resolved catalog
    defaults. Use {!http_request_fingerprint} for HTTP response-cache lookup.
    Two identical inputs always produce the same component. *)
val request_fingerprint
  :  config:Provider_config.t
  -> messages:Types.message list
  -> ?tools:Yojson.Safe.t list
  -> unit
  -> string

(** Bind the parameter identity, including endpoint and credential identity,
    to the exact serialized HTTP body that will be dispatched. *)
val http_request_fingerprint
  :  config:Provider_config.t
  -> messages:Types.message list
  -> ?tools:Yojson.Safe.t list
  -> http_codec:Provider_http_codec.t
  -> body:string
  -> unit
  -> string

(** Serialize an [api_response] to JSON for caching, preserving its original
    inference telemetry and reasoning source. *)
val response_to_json : Types.api_response -> Yojson.Safe.t

(** Deserialize a cached JSON back to [api_response].
    Returns [None] if the JSON or telemetry is malformed, missing required
    fields, or schema-incompatible. No source is inferred from a new request. *)
val response_of_json : Yojson.Safe.t -> Types.api_response option
