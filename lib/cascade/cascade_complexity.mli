(** Heuristic task-complexity classification for tiered cascade routing.

    Classifies a pending LLM call as [Simple], [Moderate], or [Complex]
    based on request metadata (goal length, tool presence, max_tokens).
    The classification maps to a cascade profile name so keepers can
    route simple tasks to local/small models and reserve expensive cloud
    models for complex ones.

    RFC-0025 §3.1: heuristic first, ML later.  Thresholds are env-tunable
    for online calibration.

    @since 0.185.0 *)

(** {1 Complexity classification} *)

type t = Simple | Moderate | Complex
(** Task complexity tiers.  [Simple] targets local 4B-class models,
    [Moderate] targets 9B-class, [Complex] targets 70B+ cloud models. *)

val to_string : t -> string
val of_string : string -> t option

(** {1 Detection}

    Thresholds default to the values from RFC-0025 §3.1 and are tunable
    via env vars for online calibration. *)

val detect :
  ?goal:string ->
  ?tools:(** any type with length *) 'a list ->
  ?max_tokens:int ->
  unit ->
  t
(** Classify task complexity from request metadata.

    @param goal  the prompt / user message.  Length in characters is
      compared against [MASC_COMPLEXITY_SIMPLE_GOAL_CHARS] and
      [MASC_COMPLEXITY_MODERATE_GOAL_CHARS].
    @param tools  non-empty list triggers [Complex] (tool_choice required).
    @param max_tokens  compared against
      [MASC_COMPLEXITY_SIMPLE_MAX_TOKENS] and
      [MASC_COMPLEXITY_MODERATE_MAX_TOKENS].

    Tools always escalate to [Complex] — tool use requires structured
    output support that small models may lack. *)

(** {1 Thresholds (env-tunable)} *)

val simple_goal_chars_max : int
(** Default 2000, env [MASC_COMPLEXITY_SIMPLE_GOAL_CHARS]. *)

val simple_max_tokens_max : int
(** Default 1000, env [MASC_COMPLEXITY_SIMPLE_MAX_TOKENS]. *)

val moderate_goal_chars_max : int
(** Default 8000, env [MASC_COMPLEXITY_MODERATE_GOAL_CHARS]. *)

val moderate_max_tokens_max : int
(** Default 4000, env [MASC_COMPLEXITY_MODERATE_MAX_TOKENS]. *)

(** {1 Routing} *)

val cascade_profile_of_complexity : t -> string
(** Map complexity tier to a cascade profile name:
    [Simple] → ["tier_small"], [Moderate] → ["tier_medium"],
    [Complex] → ["big_three"]. *)

val routing_enabled : bool
(** [true] iff [MASC_COMPLEXITY_ROUTING_ENABLED=true].  When [false],
    {!maybe_reroute} returns the original cascade name unchanged —
    observe-only mode. *)

val maybe_reroute : original_cascade_name:string -> t -> string
(** When {!routing_enabled}, return the complexity-appropriate cascade
    profile.  Otherwise return [original_cascade_name] unchanged.
    This lets operators deploy the classifier alongside existing routing
    and enable enforcement with a single env flip. *)
