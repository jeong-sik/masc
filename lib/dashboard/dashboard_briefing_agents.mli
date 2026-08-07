(** Dashboard_briefing_agents — agent briefs and per-entity context
    records for the mission dashboard.

    {b Runtime chain}: starts with [include Dashboard_utils], so
    {!Dashboard_briefing_assembly} (which does [include
    Dashboard_briefing_agents]) re-exports the full
    Dashboard_utils + this module surface to
    {!Dashboard_briefing}.

    Internal helpers stay private unless a runtime consumer needs them. *)

include module type of struct
  include Dashboard_utils
end

(** {1 Dashboard JSON helpers (runtime-visible)} *)

val dedup_strings : string list -> string list
(** [dedup_strings items] is [List.sort_uniq String.compare items].
    Used by Dashboard_briefing_assembly during agent / keeper list
    aggregation. *)

(** {1 Per-entity context records}

    Each context record bundles (a) sort / rank fields used by
    cross-section ordering and (b) the rendered JSON payload.
    Concrete records because runtime consumers
    ({!Dashboard_briefing_assembly},
    {!Dashboard_briefing}) construct them field-by-field. *)

type attention_context = {
  severity : string;
  related_agent_names : string list;
  json : Yojson.Safe.t;
}

type agent_context = {
  status_rank : int;
  related_attention_count : int;
  last_seen_ts : float;
  json : Yojson.Safe.t;
}

type keeper_context = {
  pressure_rank : int;
  last_seen_ts : float;
  json : Yojson.Safe.t;
}

(** {1 Brief builder} *)

val latest_message_to :
  string -> Masc_domain.message list -> Masc_domain.message option
(** [latest_message_to agent_name messages] returns the most recent message
    that mentions [agent_name] and was not sent by it. Exposed for testing:
    tolerates an empty/whitespace-only [agent_name] (returns [None] rather than
    raising). *)

val build_agent_briefs :
  Workspace.config ->
  attention_context list ->
  Yojson.Safe.t list ->
  Yojson.Safe.t list
(** [build_agent_briefs config attention_queue keepers]
    aggregates per-agent briefs from workspace agents, attention, and keepers.

    Returns a JSON list, one entry per workspace agent,
    sorted for dashboard display. *)
