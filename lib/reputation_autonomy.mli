(** Reputation_autonomy — Dynamic autonomy level derived from agent reputation.

    Maps multi-dimensional reputation scores to an operational envelope that
    controls tool access breadth and budget headroom.  Per the v2 roadmap
    this is advisory only until calibration Phase 5 lands.

    @since v2 Accountability & Reputation Roadmap
*)

(** Autonomy level for an agent. *)
type autonomy_level =
  | Restricted
  (** Low reputation.  Read-only tools only; human-in-the-loop required for
      consequential actions.  Token budget reduced. *)
  | Standard
  (** Default baseline.  Standard tool set; normal budget. *)
  | Elevated
  (** High reputation.  Access to higher-impact tools; expanded budget. *)
  | Full
  (** Excellent reputation across all dimensions.  Broadest tool surface;
      may participate in peer approval of other agents. *)

val autonomy_level_to_string : autonomy_level -> string
(** ["restricted" | "standard" | "elevated" | "full"] *)

val autonomy_level_of_string : string -> autonomy_level option
(** Parse from string.  Returns [None] for unrecognised values. *)

val compute_autonomy_level :
  execution_reliability:float ->
  goal_adherence:float ->
  safety_compliance:float ->
  accountability_score:float ->
  autonomy_level
(** Derive autonomy from the four core reputation dimensions.
    The result is advisory; hard enforcement requires an explicit caller
    decision to use it as a gate. *)

val autonomy_level_to_json : autonomy_level -> Yojson.Safe.t
(** JSON representation for dashboard / A2A protocol exposure. *)

val describe_autonomy_constraints : autonomy_level -> string
(** Human-readable description of what the autonomy level permits. *)
