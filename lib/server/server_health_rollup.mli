(** The [/health?full=1] operator rollup: [overall_status] and the reasons
    behind it.

    Extracted from [Server_routes_http_runtime] so the rule has a unit test
    that does not stand up a server, and so the set of sections it reads is
    one value rather than a list of arguments. *)

val cached_field_names : string list
(** The fields the background snapshot worker keeps. Everything else in the
    full-health payload is recomputed by the probe pass on each request, and
    the two sets are disjoint, which is why the response carries no duplicate
    key. [overall_status] is in here, so the rollup runs in the snapshot pass
    and can only read what that pass keeps. *)

val is_cached : string -> bool
(** [is_cached name] is whether the snapshot worker keeps that field. *)

val operator_summary :
  sections:(string * Yojson.Safe.t) list ->
  runtime_startup_degradation:Yojson.Safe.t ->
  keeper_config_schema_status:string ->
  keeper_config_schema_blocking:bool ->
  keeper_config_schema_terminal_reason:string ->
  keeper_config_operator_action_required:bool ->
  lazy_task_boot_guard_fires_total:int ->
  string * bool * string list
(** [operator_summary ~sections ...] is
    [(overall_status, operator_action_required, operator_action_reasons)].

    Which of [sections] it reads is derived, not listed: a section is rolled up
    when [is_cached] holds for its name and its ["status"] parses as a grade.
    Before this the eight it read were named one by one, and
    [keeper_observability_artifacts] -- cached, grade-bearing, and in the
    payload since it was added -- was simply not among them (#34893).

    A section whose ["status"] is a state name rather than a grade is skipped.
    [Health_status.of_string_opt] is what decides: it answers [None] for
    [listening], [active], [disabled], [ready], where the total [of_string]
    folds them to [Unknown] and would rank a listening socket alongside a
    degraded subsystem.

    A section with no ["status"] is skipped, which is most cached fields:
    [keeper_config_errors] is a list, [keeper_fibers] an int.

    [runtime_startup_degradation] is passed separately because it is rolled up
    and *not* cached. The value the response carries comes from the probe pass;
    the value judged here is the snapshot's. The two can disagree, and #34893
    is where that belongs.

    Three sections carry a grade and are outside the rollup entirely, because
    only the probe pass computes them: [internal_mcp_auth],
    [dashboard_surface], [schedule_runner]. Moving the rollup or moving those
    sections is the open decision in #34893; nothing here can reach them. *)
