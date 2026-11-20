(** The [/health?full=1] operator rollup: [overall_status] and the reasons
    behind it.

    Extracted from [Server_routes_http_runtime] so the rule has a unit test
    that does not stand up a server, and so the set of sections it reads is
    one value rather than a list of arguments. *)

val operator_field_names : string list
(** The rollup fields that say whether the operator has to act:
    [overall_status], [operator_action_required], [operator_action_reasons]
    and the same observation's typed [operator_actions].
    The snapshot pass computes them; the [/health] probe also carries the
    snapshot's copy so the TUI, which reads the probe on every refresh, can
    show them (RFC-0484 §3.3). *)

type t =
  { overall_status : string
  ; operator_action_required : bool
  ; operator_action_reasons : string list
  ; operator_actions : Operator_action_reason.t list
  ; overall_status_reasons : string list
  }
(** Two lists, because they answer two questions.

    [operator_action_reasons] is what somebody has to answer, and
    [operator_action_required] is whether that list holds anything. Both raw
    reasons and required derive from [operator_actions], the same immutable
    typed observations. Unrecognized causes retain a diagnostic-only item.

    [overall_status_reasons] is what moved [overall_status] off ok, whether or
    not anyone has to answer it. Every section above rank 0 leaves a line
    here. Without it a section at Degraded, Stale, Warning or Unavailable with
    [operator_action_required=false] raised the grade and left no line
    anywhere: the dashboard renders "Runtime health warning · status=warning ·
    operator_action_required=false" and stops, so the operator could not tell
    which section it was (#34895). #34781 made that combination common on
    purpose -- a queue holding only runnable backlog is warning and needs no
    answer. *)

val operator_summary :
  sections:(string * Yojson.Safe.t) list ->
  runtime_startup_degradation:Yojson.Safe.t ->
  keeper_config_schema_status:string ->
  keeper_config_schema_blocking:bool ->
  keeper_config_schema_terminal_reason:string ->
  keeper_config_operator_action_required:bool ->
  t
(** [operator_summary ~sections ...] rolls the sections up.

    Which of [sections] it reads is one list inside this module: a section is
    rolled up when its name is in that list and its ["status"] parses as a
    grade. Before the list the eight it read were named one by one, and
    [keeper_observability_artifacts] -- grade-bearing, and in the payload
    since it was added -- was simply not among them (#34893).

    The list says only what is graded. What the response carries does not
    depend on it: the snapshot keeps every section, and one outside the list
    is served ungraded. The same list used to decide both, so a section that
    was computed and not named in it never reached the response (#53985).

    A section whose ["status"] is a state name rather than a grade is skipped.
    [Health_status.of_string_opt] is what decides: it answers [None] for
    [listening], [active], [disabled], [ready], where the total [of_string]
    folds them to [Unknown] and would rank a listening socket alongside a
    degraded subsystem.

    The reasons it carries are the section's ["operator_action_reasons"] when
    it declares any -- the subset that needs an answer, which is not the same
    list as what is happening. keeper_event_queue reports a paused-dead
    backlog in ["status_reasons"] and leaves it out of those, because a keeper
    the operator paused is their own standing decision. A section that
    declares none falls back to ["status_reasons"]: the gate is already open,
    so the operator is owed a line, and silence is the one answer this list
    must not give (#34894).

    A section with no ["status"] is skipped, which is most of the listed
    fields: [keeper_config_errors] is a list, [keeper_fibers] an int.

    [runtime_startup_degradation] is passed separately because it is rolled up
    and the response does not carry the snapshot's copy of it. The value the
    response carries comes from the probe pass; the value judged here is the
    snapshot's. The two can disagree, and #34893 is where that belongs.

    Three sections carry a grade and are outside the rollup entirely, because
    only the probe pass computes them: [internal_mcp_auth],
    [dashboard_surface], [schedule_runner]. Moving the rollup or moving those
    sections is the open decision in #34893; nothing here can reach them. *)
