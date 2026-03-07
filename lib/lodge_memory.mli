(** Lodge Memory — Agent experience recall & store

    Read: Council thread + Memory Stream
    Write: Council thread + Memory Stream

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
    Combines Council thread (short-term) + Memory Stream (scored).
    Returns (content, relevance_score) pairs sorted by relevance. *)
val recall : agent_name:string -> query:string -> limit:int
  -> (string * float) list

(** Format recalled memories for inclusion in LLM prompt *)
val format_for_prompt : (string * float) list -> string

(** {1 Write — Store new experiences} *)

(** Record an agent's experience to memory stores.
    Writes to Council thread (short-term) and Memory Stream (scored). *)
val store : experience -> unit
