(** OpenAI-compatible endpoint capacity probe.

    Probes OpenAI-compatible endpoints (RunPod, vLLM, etc.) via
    [/v1/models] for basic health/capacity discovery.  Registered in
    [Cascade_capacity_probe] after the ollama-specific probe; ollama
    URLs take precedence via first-match semantics.

    @since 0.10.0 *)

(* ── Explicit URL registry ──────────────────────────────────── *)

val register_url : url:string -> unit
val is_registered : url:string -> bool
val registered_count : unit -> int

(* ── Cache ──────────────────────────────────────────────────── *)

val cached_capacity : ?now:float -> string -> Cascade_throttle.capacity_info option
val cache_size : unit -> int

(* ── Probe adapter ───────────────────────────────────────────── *)

module Openai_probe : Cascade_capacity_probe.Probe
