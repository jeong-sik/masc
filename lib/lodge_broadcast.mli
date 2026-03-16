(** Lodge Broadcast — Content-Aware Routing for broadcasts.

    Analyzes broadcast content and routes to relevant agents
    using keyword matching + LLM-based semantic analysis.

    Extracted from Lodge_heartbeat to reduce module size.

    @since 2.91.0
*)

(** {1 Agent Specialties} *)

val get_agent_specialties : unit -> (string * string list) list
(** Get cached agent specialties (refreshed every 5 minutes from Neo4j). *)

(** {1 Keyword Matching} *)

val keyword_match_score : agent_name:string -> content:string -> float
(** Calculate keyword match score between agent specialties and content. *)

(** {1 Agent Routing} *)

val find_relevant_agents : content:string -> threshold:float -> string list
(** Find agents relevant to the given content. Uses keyword matching first,
    falls back to LLM analysis if no keyword matches exceed threshold. *)

(** {1 Broadcast Handling} *)

type generate_content_fn =
  agent_name:string ->
  context:string ->
  action_type:[`Post of string | `Comment of string] ->
  string option
(** Content generation function type, injected from Lodge_heartbeat. *)

val handle_broadcast :
  generate_content:generate_content_fn ->
  sender:string ->
  content:string ->
  (string * string) list
(** Handle a single broadcast: find relevant agents, generate responses, post replies.
    Returns list of (agent_name, response) pairs. *)

val poll_and_handle_broadcasts :
  generate_content:generate_content_fn ->
  since_timestamp:float ->
  float
(** Poll for recent broadcasts and handle them.
    Returns new timestamp for next poll. *)
