(** Keeper tool-name canonicalisation over the descriptor-owned routing table. *)

type runtime_decision_outcome =
  | Route_hit of { internal : string }
  | Already_internal of { canonical : string }
  | Miss

(** [runtime_decision name] returns the pure routing decision for a
    runtime-reported or model-reported tool name. This module is the
    low-dependency SSOT for runtime tool-name routing.

    Result variants:
    - [Route_hit { internal }] — alias-table hit; internal name returned.
    - [Already_internal { canonical }] — name is already in internal form.
    - [Miss] — name does not resolve through any runtime route. *)
val runtime_decision : string -> runtime_decision_outcome

(** Pure canonicalisation — no telemetry side-effect.

    Used by set-logic call sites (tool canonicalisation, surface
    composition, satisfaction checks) where every invocation should NOT
    count as an observation event. *)
val canonical_tool_name : string -> string

(** Observation-emitting canonicalisation.

    Emits exactly one [masc_keeper_tool_call_total] sample with bounded
    [tool] / [routed_to] / [result] labels. Use only at the keeper turn
    observation boundary. Non-observation call sites should use
    [canonical_tool_name] to avoid double-counting. *)
val canonical_tool_name_observed : string -> string
