(** Required exact-output lane backfill, shared by the server bootstrap
    publish path and the runtime.toml save path. *)

val compaction_exact_lane_id : string
(** Lane id the compaction summarizer resolves by name; every published
    exact-output registry must carry it. *)

val seed_lane_declarations : unit -> Runtime_schema.exact_output_lane_decl list
(** Exact-output lane declarations from the binary-embedded seed runtime.toml.
    Returns [] (with a WARN) when the embedded seed is unavailable or invalid. *)

val backfill_required
  :  seed_lanes:Runtime_schema.exact_output_lane_decl list
  -> Runtime_schema.exact_output_lane_decl list
  -> Runtime_schema.exact_output_lane_decl list * bool
(** Append the seed {!compaction_exact_lane_id} declaration when the given
    lane list does not declare the lane (legacy runtime.toml from before
    [runtime.exact_output_lanes] existed). Returns the effective lane list and
    whether a backfill happened. Operator declarations always win. *)

val with_required_backfill
  :  Runtime_schema.exact_output_lane_decl list
  -> Runtime_schema.exact_output_lane_decl list
(** [backfill_required] with the embedded seed declarations, returning only
    the effective lane list. *)
