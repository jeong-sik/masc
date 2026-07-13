(** Dashboard_goals_types — pure types + task helpers extracted from
    Dashboard_goals (1998 LoC godfile).

    See dashboard_goals_types.mli for rationale and contract.

    Stage 22 (godfile decomposition build plan, 2026-05-18) split the
    1608-line body into five cohesive submodules behind this facade.
    The public API is unchanged; callers continue to use
    [Dashboard_goals.task_is_done], etc. via the [include] chain in
    [Dashboard_goals]. Submodule layering:

    - [Dashboard_goals_types_accessor]   — types + task/list/receipt/trust
                                            inspectors + iso/duration helpers
    - [Dashboard_goals_types_attainment] — metric tokenizer + attainment JSON
    - [Dashboard_goals_types_health]     — explicit Goal FSM + linkage helpers
    - [Dashboard_goals_types_timeline]   — color helpers, goal-detail JSON,
                                            timeline composition
    - [Dashboard_goals_types_builder]    — recursive build_tree *)

include Dashboard_goals_types_accessor
include Dashboard_goals_types_attainment
include Dashboard_goals_types_health
include Dashboard_goals_types_timeline
include Dashboard_goals_types_builder
