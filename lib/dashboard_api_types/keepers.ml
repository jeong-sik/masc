(** Dashboard API types — [GET /dashboard/b/api/keepers/summary] response.

    Single-endpoint projection consumed by four Bonsai visualizations:
    - focus card (ctx / turn / mem / latency)
    - roster (4 slot status grid)
    - cycle activity swimlane (lane_frames)
    - context pressure chart (ctx_history polyline)

    Server assembles this record from {!Keeper_status_bridge}, cycle trace
    buffer, and context metrics. See also:
      /dashboard/b/api/keepers/summary  — route entry
      dashboard_bonsai/src/keepers_fetch.ml  — client consumer

    SSOT for the JSON wire contract. Phase 1 artifact per
    planning/claude-plans/masc-eventual-parrot.md. *)

type keeper_status =
  | Live
  | Warn
  | Dead
[@@deriving yojson]

(** One tool-span in a keeper's cycle, positioned as a percentage of the
    last-60-min window. *)
type keeper_lane_frame = {
  kind : string;                (* "llm" | "tool" | "think" | "wait" | "err" *)
  left : int;                   (* left %, 0..100 *)
  width : int;                  (* width %, 0..100 *)
  label : string;
}
[@@deriving yojson { strict = false }]

(** One sample on the 60-min context-pressure polyline. *)
type keeper_ctx_sample = {
  t_minus_min : int;            (* minutes ago, 0..60 *)
  ctx_pct : int;                (* 0..100 *)
}
[@@deriving yojson { strict = false }]

(** Total run-state classification (#16, 38-bug campaign PR-5). Mirrors
    [Keeper_composite_observer.run_state]; see .mli for why this library
    keeps its own copy instead of depending on that module. *)
type keeper_run_state_kind =
  | In_turn
  | Waiting
  | Suspended
[@@deriving yojson]

(** Per-kind fields are [None] / [[]] when not applicable to [kind]. *)
type keeper_run_state = {
  kind : keeper_run_state_kind;
  wake_kind : string option;      [@default None]
  stimulus_kinds : string list;   [@default []]
  started_at : float option;      [@default None]
  active_tool_count : int option; [@default None]
  queue_depth : int option;       [@default None]
  skip_reasons : string list;     [@default []]
  phase : string option;          [@default None]
}
[@@deriving yojson { strict = false }]

(** Per-keeper summary. *)
type keeper = {
  name : string;
  stat : string;                (* short human state: "reading", "retrying" *)
  status : keeper_status;
  ctx_pct : int;                (* current context utilization, 0..100 *)
  turn : int;
  turn_cap : int;
  mem_kb : int;
  latency_ms : int;
  last_tool : string option;     [@default None]
  lane_frames : keeper_lane_frame list;   [@default []]
  ctx_history : keeper_ctx_sample list;   [@default []]
  run_state : keeper_run_state;
}
[@@deriving yojson { strict = false }]

(** Top-level response. *)
type response = {
  keepers : keeper list;
  cycle : int;                  (* current cycle number *)
  workspace : string option;         [@default None]
  generated_at : string;        (* ISO-8601 UTC *)
}
[@@deriving yojson { strict = false }]
