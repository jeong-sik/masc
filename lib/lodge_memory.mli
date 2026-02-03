(** Lodge Memory — Agent experience recall & store

    Read: Council thread + Memory Stream + Neo4j graph
    Write: Council thread + Memory Stream + Neo4j LodgeActivity

    Self-contained module (no Lodge_heartbeat dependency).

    @since 3.0.0
*)

(** {1 Types} *)

type experience = {
  agent_name: string;
  action_type: string;        (** "post" | "comment" | "upvote" | "skip" *)
  content: string;
  context: string;            (** trigger/reason *)
  board_id: string option;
  timestamp: float;
}

(** {1 Read — Recall memories for prompt context} *)

(** Recall relevant memories for an agent.
    Combines Council thread (short-term) + Memory Stream (scored) + Neo4j graph (long-term).
    Returns (content, relevance_score) pairs sorted by relevance. *)
val recall : agent_name:string -> query:string -> limit:int
  -> (string * float) list

(** Format recalled memories for inclusion in LLM prompt *)
val format_for_prompt : (string * float) list -> string

(** {1 Write — Store new experiences} *)

(** Record an agent's experience to memory stores.
    Writes to Council thread (short-term), Memory Stream (scored),
    and optionally to Neo4j (long-term, skips "skip" actions). *)
val store : experience -> unit

(** {1 Utilities — shared across Lodge modules} *)

(** Escape string for Cypher single-quoted literals.
    Handles all Neo4j Cypher escape sequences per specification. *)
val cypher_escape : string -> string

(** Build a shell command to run a Neo4j Cypher query via sb CLI.
    Uses Filename.quote to prevent shell injection. *)
val neo4j_query_cmd : string -> string
