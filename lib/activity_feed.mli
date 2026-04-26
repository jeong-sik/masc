(** Activity_feed — Unified activity timeline

    Aggregates events from different JSONL sources into a single
    chronological timeline for agent dashboards and keeper observations.

    @since Phase 3B — Keeper Deliberation Engine
*)

(** A single activity event in the unified timeline. *)
type activity_item =
  { id : string (** Unique ID with "act-" prefix + source kind *)
  ; kind : string (** "task" | "board_post" | "board_comment" | "mention" | "debate" *)
  ; agent_name : string (** Agent who performed the action *)
  ; summary : string (** One-line description *)
  ; detail_json : Yojson.Safe.t (** Full event data *)
  ; created_at : float (** Unix timestamp *)
  }

(** PPX-generated serializer. *)
val activity_item_to_yojson : activity_item -> Yojson.Safe.t

(** PPX-generated deserializer.  Returns [Error msg] on parse failure. *)
val activity_item_of_yojson : Yojson.Safe.t -> (activity_item, string) result

(** Alias for {!activity_item_to_yojson}. *)
val activity_item_to_json : activity_item -> Yojson.Safe.t

(** Wraps {!activity_item_of_yojson}. Returns None on parse failure
    or when [id] is empty. *)
val activity_item_of_json : Yojson.Safe.t -> activity_item option

(** Fetch a unified activity timeline.

    Reads from tasks, board posts, board comments, mention inbox, and debates.
    Results are sorted by [created_at] descending (newest first).
    If [agent_name] is provided, only items from that agent are returned.
    Returns at most [limit] items. *)
val recent_activity
  :  Coord.config
  -> ?agent_name:string
  -> limit:int
  -> unit
  -> activity_item list
