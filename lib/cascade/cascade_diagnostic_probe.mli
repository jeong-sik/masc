(** Provider-agnostic native-runtime diagnostic probe adapter.

    This is the sibling of {!Cascade_capacity_probe}. Where the
    capacity adapter answers "how many slots does this URL have free
    right now?", this adapter answers "what runtime diagnostics can
    we read from this URL right now?" — loaded model list, KV
    occupancy assessment, prompt-eval / decode timing per probe run,
    think-mode behaviour, etc.

    Probes carry vendor-specific knowledge (e.g. Ollama exposes
    [/api/ps] + [/api/generate]). Callers must never spell out a
    vendor name — they go through {!find_owner} or the top-level
    [*_json] functions, which delegate to the first registered probe
    that recognises the URL.

    Result type is intentionally raw {!Yojson.Safe.t}: each provider
    returns a different shape, and the dashboard / MCP tool surface
    pass the JSON through unchanged. Forcing a closed result variant
    here would push vendor structure back into the core types, which
    is exactly what RFC-0058 §2.4 forbids. *)

(** {1 Module type} *)

module type Diagnostic_probe = sig
  val can_probe : url:string -> bool

  (** [loaded_models_json] calls the provider's "what models are
      currently loaded into memory" endpoint and returns the raw JSON
      response. *)
  val loaded_models_json
    :  sw:Eio.Switch.t
    -> net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t
    -> url:string
    -> ?timeout_sec:int
    -> unit
    -> Yojson.Safe.t

  (** [runtime_probe_json] issues one or more short generate calls
      against [url] with a controlled prompt to measure warm-state
      behaviour (decode timing, KV-cache assessment, think-mode
      effect). The JSON shape is documented per-provider. *)
  val runtime_probe_json
    :  sw:Eio.Switch.t
    -> net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t
    -> url:string
    -> probe_runs:int
    -> max_tokens:int
    -> ?think_enabled:bool
    -> unit
    -> Yojson.Safe.t
end

(** {1 First-class module} *)

type t = (module Diagnostic_probe)

(** {1 Registry} *)

(** [register probe] appends [probe] to the registry. Probes are
    consulted in registration order. *)
val register : t -> unit

(** [find_owner ~url] returns the first registered probe that
    recognises [url]. *)
val find_owner : url:string -> t option

(** {1 Generic top-level API}

    Each call routes through {!find_owner}. Returns [`Null] when no
    registered probe recognises the URL — caller can treat that as
    "diagnostics not available at this endpoint". *)

val loaded_models_json
  :  sw:Eio.Switch.t
  -> net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t
  -> url:string
  -> ?timeout_sec:int
  -> unit
  -> Yojson.Safe.t

val runtime_probe_json
  :  sw:Eio.Switch.t
  -> net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t
  -> url:string
  -> probe_runs:int
  -> max_tokens:int
  -> ?think_enabled:bool
  -> unit
  -> Yojson.Safe.t

(** {1 Testing helpers}

    These bypass the registry mutex contract intentionally — tests need
    deterministic registry state and the production code never calls
    [clear_registry]. Production code must not use this module. *)
module For_testing : sig
  (** [clear_registry ()] empties the probe registry. *)
  val clear_registry : unit -> unit

  (** [with_registry probes f] atomically swaps the registry to [probes]
      for the dynamic extent of [f] and restores the previous registry
      afterward (even when [f] raises). The save+install is performed
      under a single mutex critical section so a concurrent [register]
      cannot be lost. *)
  val with_registry : t list -> (unit -> 'a) -> 'a
end
