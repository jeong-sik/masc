(** Worker-only sampling defaults — provider-specific knobs that do not
    belong in [Llm_provider.Constants.Inference_profile].

    The OAS [Inference_profile] record exposes temperature / max_tokens /
    thinking params but not provider-specific sampling cutoffs
    (top_p / top_k) or the masc-mcp turn-level tool-call cap. This module
    is the SSOT for those values.

    Callers: [Worker_oas], [Worker_container]. *)

(** Nucleus (top-p) sampling cutoff. *)
val top_p : float

(** Top-k sampling cutoff. *)
val top_k : int

(** Maximum number of tool calls a worker is allowed in one turn. *)
val max_tool_calls_per_turn : int
