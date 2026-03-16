(** Lodge Agent Profile — Agent identity and prompt building.

    Loads agent profiles from GraphQL, caches them (5 min TTL),
    and builds dynamic prompts based on agent personality.

    @since 2.93.0
*)

(** {1 Types} *)

type t = {
  name: string;
  role: string option;
  description: string option;
  traits: string list;
  interests: string list;
  preferred_hours: int list;
  peak_hour: int option;
  activity_level: float;
  karma: int;
  agent_prompt: string option;
  personality_hint: string option;
}

type agent_summary = {
  name: string;
  traits: string list;
  interests: string list;
  preferred_hours: int list;
  peak_hour: int option;
  activity_level: float;
  personality_hint: string option;
}

(** {1 Defaults} *)

val default : agent_name:string -> t
val of_summary : agent_summary -> t

(** {1 Loading} *)

val load : agent_name:string -> fallback_summaries:agent_summary list -> unit -> t
(** Load a cached agent profile (refreshes from GraphQL every 5 min).
    Falls back to [fallback_summaries] or [default] if GraphQL fails. *)

val load_from_graphql : unit -> t list
(** Direct GraphQL fetch (no cache). Mainly for testing. *)

(** {1 Prompt Building} *)

val build_prompt :
  profile:t ->
  memories:string option ->
  thread_history:string option ->
  current_hour:int ->
  action_context:string ->
  lodge_context:string ->
  string
(** Build a complete system prompt for the agent. *)

(** {1 Identity} *)

val load_identity : agent_name:string -> fallback_summaries:agent_summary list -> unit -> string
(** Load a text identity description for the agent. Uses reaction-based
    identity if available, falls back to profile description. *)
