(** Dashboard API types — [GET /dashboard/b/api/keepers/summary] response.

    Single-endpoint projection consumed by four Bonsai visualisations:
    focus card, roster grid, cycle-activity swimlane, context-pressure chart.

    SSOT for the JSON wire contract — any change here must be reflected in
    [dashboard_bonsai/src/keepers_fetch.ml]. *)

type keeper_status =
  | Live
  | Warn
  | Dead

val keeper_status_of_yojson : Yojson.Safe.t -> keeper_status Ppx_deriving_yojson_runtime.error_or
val keeper_status_to_yojson : keeper_status -> Yojson.Safe.t

(** One tool-span in a keeper's cycle, positioned as a percentage of the
    last-60-min window. *)
type keeper_lane_frame = {
  kind : string;   (** ["llm" | "tool" | "think" | "wait" | "err"] *)
  left : int;      (** left %, 0..100 *)
  width : int;     (** width %, 0..100 *)
  label : string;
}

val keeper_lane_frame_of_yojson : Yojson.Safe.t -> keeper_lane_frame Ppx_deriving_yojson_runtime.error_or
val keeper_lane_frame_to_yojson : keeper_lane_frame -> Yojson.Safe.t

(** One sample on the 60-min context-pressure polyline. *)
type keeper_ctx_sample = {
  t_minus_min : int;   (** minutes ago, 0..60 *)
  ctx_pct : int;       (** 0..100 *)
}

val keeper_ctx_sample_of_yojson : Yojson.Safe.t -> keeper_ctx_sample Ppx_deriving_yojson_runtime.error_or
val keeper_ctx_sample_to_yojson : keeper_ctx_sample -> Yojson.Safe.t

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
}

val keeper_of_yojson : Yojson.Safe.t -> keeper Ppx_deriving_yojson_runtime.error_or
val keeper_to_yojson : keeper -> Yojson.Safe.t

(** Top-level response. *)
type response = {
  keepers : keeper list;
  cycle : int;                 (** current cycle number *)
  room : string option;
  generated_at : string;       (** ISO-8601 UTC *)
}

val response_of_yojson : Yojson.Safe.t -> response Ppx_deriving_yojson_runtime.error_or
val response_to_yojson : response -> Yojson.Safe.t
