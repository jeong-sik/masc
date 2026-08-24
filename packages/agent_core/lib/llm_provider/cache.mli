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

(** Compute a deterministic cache key from request parameters.

    Every {!Provider_config.t} field that changes what the provider is asked
    reaches the key, along with the messages and tools. Transport limits,
    delivery-shape flags, the local rotation counter, and the capability
    overrides that gate which fields may be sent are excluded; [cache.ml]
    names each exclusion at the destructuring. The record is matched field by
    field, so a new field stops the build until it is placed on one side.

    Two identical requests always produce the same key. *)
val request_fingerprint
  :  config:Provider_config.t
  -> messages:Types.message list
  -> ?tools:Yojson.Safe.t list
  -> unit
  -> string

(** Serialize an [api_response] to JSON for caching. *)
val response_to_json : Types.api_response -> Yojson.Safe.t

(** Deserialize a cached JSON back to [api_response].
    Returns [None] if the JSON is malformed or schema-incompatible. *)
val response_of_json : Yojson.Safe.t -> Types.api_response option
