(** Keeper_skill_routing — automated and model-assisted skill routing.

    Keepers always have access to all 'keeper' shard tools, but they
    are routed to specific meta-skills (heartbeat, autonomy) based on
    the user's request. *)

type selection_mode =
  | Heuristic
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

(** Case-insensitive substring match on UTF-8 strings. *)
val contains_ci : string -> string -> bool

(** Count keywords in [keywords] that occur (case-insensitively) in
    [text]. *)
val skill_match_count_ci : text:string -> keywords:string list -> int

(** Lower-is-higher priority used as a secondary sort key when scores
    tie. *)
val keeper_skill_priority : string -> int

(** Heuristic routing of [message] to a primary/secondary keeper skill. *)
val route_keeper_skill : message:string -> keeper_skill_route

val format_skill_route_line : keeper_skill_route -> string
val format_skill_route_reason : keeper_skill_route -> string

(** Drop SKILL: / SKILL_REASON: lines from a model response. *)
val strip_skill_route_lines : string -> string

(** Parse a model response's SKILL: / SKILL_REASON: header into a
    route. Falls back to [fallback_route] (with adjusted
    [selection_mode]) if the header is missing or invalid. *)
val parse_skill_route_response :
  string -> fallback_route:keeper_skill_route -> keeper_skill_route

(** Build the model-facing instruction block describing the skill
    routing contract and the heuristic fallback. *)
val keeper_skill_routing_instructions :
  fallback_route:keeper_skill_route -> string

(** Compose [keeper_skill_routing_instructions] with the current
    heuristic route into a wrapped " SKILL ROUTING " context block. *)
val skill_route_context_text : fallback_route:keeper_skill_route -> string
