(** Activity_feed — Unified activity timeline

    Aggregates events from different JSONL sources into a single
    chronological timeline for agent dashboards and keeper observations.

    @since Phase 3B — Keeper Deliberation Engine
*)

(** A single activity event in the unified timeline. *)
type activity_item = {
  id: string;                (** Unique ID with "act-" prefix + source kind *)
  kind: string;              (** "task" | "board_post" | "board_comment" | "mention" | "debate" *)
  agent_name: string;        (** Agent who performed the action *)
  summary: string;           (** One-line description *)
  detail_json: Yojson.Safe.t; (** Full event data *)
  created_at: float;         (** Unix timestamp *)
}

val activity_item_to_json : activity_item -> Yojson.Safe.t
(** Serialize an activity item to JSON. *)

val activity_item_of_json : Yojson.Safe.t -> activity_item option
(** Deserialize an activity item from JSON. Returns None on parse failure. *)

val recent_activity :
  Room.config -> ?agent_name:string -> limit:int -> unit -> activity_item list
(** Fetch a unified activity timeline.

    Reads from tasks, board posts, board comments, mention inbox, and debates.
    Results are sorted by [created_at] descending (newest first).
    If [agent_name] is provided, only items from that agent are returned.
    Returns at most [limit] items. *)
