(** Dashboard API types — [GET /dashboard/b/api/keepers/summary] response.

    Single-endpoint projection consumed by four Bonsai visualisations:
    focus card, roster grid, cycle-activity swimlane, context-pressure chart.

    SSOT for the JSON wire contract — any change here must be reflected in
    [dashboard_bonsai/src/keepers_fetch.ml]. *)

type keeper_status =
  | Live
  | Warn
  | Dead

(** One tool-span in a keeper's cycle, positioned as a percentage of the
    last-60-min window. *)
type keeper_lane_frame = {
  kind : string;   (** ["llm" | "tool" | "think" | "wait" | "err"] *)
  left : int;      (** left %, 0..100 *)
  width : int;     (** width %, 0..100 *)
  label : string;
}

(** One sample on the 60-min context-pressure polyline. *)
type keeper_ctx_sample = {
  t_minus_min : int;   (** minutes ago, 0..60 *)
  ctx_pct : int;       (** 0..100 *)
}

(** Total run-state classification (#16, 38-bug campaign PR-5). Mirrors
    [Keeper_composite_observer.run_state] one-to-one; kept as a separate
    type here because this library does not depend on [Keeper_registry] /
    [Keeper_composite_observer] (see README) — the server-side converter
    lives in [server_routes_http_pages.ml]. *)
type keeper_run_state_kind =
  | In_turn
  | Waiting
  | Suspended

(** Per-kind fields are [None] / [[]] when not applicable to [kind] — e.g.
    [wake_kind] is only present for [In_turn]. *)
type keeper_run_state = {
  kind : keeper_run_state_kind;
  wake_kind : string option;
  stimulus_kinds : string list;
  started_at : float option;
  active_tool_count : int option;
  queue_depth : int option;
  skip_reasons : string list;
  phase : string option;
}

(** Per-keeper summary. *)
type keeper = {
  name : string;
  stat : string;               (** short human state, e.g. "reading", "retrying" *)
  status : keeper_status;
  ctx_pct : int;               (** current context utilisation, 0..100 *)
  turn : int;
  turn_cap : int;
  mem_kb : int;
  latency_ms : int;
  last_tool : string option;
  lane_frames : keeper_lane_frame list;
  ctx_history : keeper_ctx_sample list;
  run_state : keeper_run_state;
}

(** Top-level response. *)
type response = {
  keepers : keeper list;
  cycle : int;                 (** current cycle number *)
  workspace : string option;
  generated_at : string;       (** ISO-8601 UTC *)
}

val response_to_yojson : response -> Yojson.Safe.t
