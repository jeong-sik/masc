(** Keeper_skill_routing -- model-assisted skill routing.

    Keepers always have access to all 'keeper' shard tools, but they
    can ask the model to choose a meta-skill for the current turn. The
    local route is only a deterministic default. *)

type selection_mode =
  | Default_route
  | Model_selected of string
  | Model_rejected of string

type keeper_skill_route =
  { primary_skill : string
  ; secondary_skill : string option
  ; reason : string
  ; selection_mode : selection_mode
  }

(** Skills routable to keepers. *)
val keeper_allowed_skills : string list

val is_valid_keeper_skill : string -> bool

(** Deterministic default route used until the model emits a valid
    [SKILL:] header. [message] is accepted for caller compatibility and is not
    inspected locally. *)
val route_keeper_skill : message:string -> keeper_skill_route

val format_skill_route_line : keeper_skill_route -> string
val format_skill_route_reason : keeper_skill_route -> string

(** Drop skill-routing protocol lines from a model response. *)
val strip_skill_route_lines : string -> string

(** [count_skill_route_lines s] returns the number of lines in [s]
    parsed as skill-routing protocol lines. Pure, no side effects.
    Main-library callers use this alongside {!strip_skill_route_lines}
    to emit a Otel_metric_store counter for resonance-loop input
    detection without violating the dependency-leaf boundary of this
    sub-library (RFC-0056 Phase 1B). *)
val count_skill_route_lines : string -> int

(** Parse a model response's skill-routing protocol header into a route.
    Returns [fallback_route] with [Model_rejected _] if the header is
    missing or invalid. *)
val parse_skill_route_response :
  string -> fallback_route:keeper_skill_route -> keeper_skill_route

(** Build the model-facing instruction block describing the skill
    routing contract and default route. *)
val keeper_skill_routing_instructions :
  fallback_route:keeper_skill_route -> string

(** Compose [keeper_skill_routing_instructions] with the default route
    into a wrapped " SKILL ROUTING " context block. *)
val skill_route_context_text : fallback_route:keeper_skill_route -> string
