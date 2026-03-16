(** Conversation - Multi-agent persistent conversation system for MASC

    Implements topic-based threaded conversations with turn-taking,
    loop prevention, and dual-stream persistence (file + Neo4j).

    Based on academic research:
    - MAGMA (2026.01): Dual-stream Write pattern
    - A-MEM (NeurIPS 2025): Zettelkasten-style linking
    - SSJ 1974: Turn-taking systematics (Adjacency Pair)
    - Hashgraph: Gossip + Virtual Voting for loop prevention
*)

(** {1 Types} *)

(** Turn types following SSJ adjacency pair model *)
type turn_type =
  | Initiate   (** Start a new topic/question *)
  | Respond    (** Direct response to previous turn *)
  | FollowUp   (** Elaboration or continuation *)
  | Conclude   (** Final summary/decision *)

(** Thread lifecycle status *)
type thread_status =
  | Active     (** Conversation in progress *)
  | Concluded  (** Properly closed with conclusion *)
  | Stalled    (** No activity, auto-timeout *)
  | Archived   (** Moved to long-term storage *)

(** Individual turn in a conversation *)
type turn = {
  id: string;              (** Unique turn ID: {thread_id}-turn-{seq} *)
  seq: int;                (** Sequence number in thread *)
  speaker: string;         (** Agent name *)
  content: string;         (** Turn content *)
  turn_type: turn_type;    (** Type of turn *)
  created_at: float;       (** Unix timestamp *)
  confidence: float option;(** Speaker's confidence (0.0-1.0) *)
  reply_to: string option; (** ID of turn being replied to *)
  mentions: string list;   (** @mentioned agents *)
}

(** Conversation thread *)
type thread = {
  id: string;              (** Unique thread ID *)
  topic: string;           (** Conversation topic *)
  room: string;            (** MASC room name *)
  status: thread_status;   (** Current status *)
  turns: turn list;        (** All turns in order *)
  participants: string list; (** Agents who have spoken *)
  started_at: float;       (** Unix timestamp *)
  concluded_at: float option; (** When concluded *)
  conclusion: string option;  (** Final summary *)
  max_turns: int;          (** Loop prevention limit *)
  current_turn: int;       (** Next turn sequence *)
  floor_holder: string option; (** Who has the floor (SSJ) *)
  source_post_id: string option; (** Board post that spawned this thread *)
}

(** Configuration for conversation storage *)
type config = {
  base_path: string;       (** Root path, e.g., ".masc" *)
  room: string;            (** Room name *)
}

(** {1 JSON Serialization} *)

val turn_type_to_string : turn_type -> string
val turn_type_of_string : string -> (turn_type, string) result

val thread_status_to_string : thread_status -> string
val thread_status_of_string : string -> (thread_status, string) result

val turn_to_yojson : turn -> Yojson.Safe.t
val turn_of_yojson : Yojson.Safe.t -> (turn, string) result

val thread_to_yojson : thread -> Yojson.Safe.t
val thread_of_yojson : Yojson.Safe.t -> (thread, string) result

(** {1 Core Operations} *)

(** Start a new conversation thread.
    @param room MASC room name
    @param topic Conversation topic/question
    @param initiator Agent starting the conversation
    @param max_turns Optional turn limit (default: 50)
    @return New thread or error *)
val start :
  config:config ->
  topic:string ->
  initiator:string ->
  ?max_turns:int ->
  ?initial_content:string ->
  ?mentions:string list ->
  ?source_post_id:string ->
  unit ->
  (thread, string) result

(** Add a reply to a thread.
    @param thread_id Thread to reply in
    @param speaker Agent speaking
    @param content Message content
    @param confidence Optional confidence level
    @param reply_to Optional turn ID being replied to
    @param mentions Optional list of @mentioned agents
    @return Updated thread or error *)
val reply :
  config:config ->
  thread_id:string ->
  speaker:string ->
  content:string ->
  ?confidence:float ->
  ?reply_to:string ->
  ?mentions:string list ->
  unit ->
  (thread, string) result

(** Conclude a conversation with a summary.
    @param thread_id Thread to conclude
    @param concluder Agent writing conclusion
    @param conclusion Summary/decision text
    @return Concluded thread or error *)
val conclude :
  config:config ->
  thread_id:string ->
  concluder:string ->
  conclusion:string ->
  unit ->
  (thread, string) result

(** Get a thread by ID.
    @return Thread if found *)
val get :
  config:config ->
  thread_id:string ->
  thread option

(** List all active threads in a room.
    @param room Room name
    @return List of active threads *)
val list_active :
  config:config ->
  thread list

(** List all threads (any status) in a room.
    @return List of all threads *)
val list_all :
  config:config ->
  thread list

(** {1 Persistence} *)

(** Save a thread to file storage *)
val save_thread : config -> thread -> unit

(** {1 Thread State Helpers} *)

(** Check if a thread can accept new turns *)
val can_reply : thread -> bool

(** Get the last turn in a thread *)
val last_turn : thread -> turn option

(** Count turns by a specific speaker *)
val count_turns_by : thread -> speaker:string -> int
