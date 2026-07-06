(** Keeper_external_attention — durable, connector-neutral attention lifecycle.

    This store records external attention before keeper dispatch. Adapter
    policy decides which platform events become attention; this module only
    persists the typed surface/conversation coordinates and folds lifecycle
    events into a pending projection.

    Stored at:
    [<base_path>/.masc/external_attention/<sanitized-keeper>.jsonl]. *)

(** {1 Coordinates} *)

(** Re-export of the shared surface vocabulary (RFC-0232 P5); see
    {!Surface_ref}. *)
type surface_ref = Surface_ref.t =
  | Dashboard of { session_id : string option }
  | Discord of {
      guild_id : string option;
      channel_id : string;
      parent_channel_id : string option;
      thread_id : string option;
    }
  | Slack of {
      team_id : string option;
      channel_id : string;
      thread_ts : string option;
    }
  | Github of { repo : string; notification_id : string option }
  | Webhook of { source : string; event_id : string }
  | Agent
  | Gate of { label : string; address : (string * string) list }

type conversation_ref = {
  conversation_id : string;
  surface : surface_ref;
}

type external_message_ref = {
  surface : surface_ref;
  message_id : string;
  reply_to_message_id : string option;
}

(** {1 Attention event model} *)

type urgency =
  | Mention
  | Direct_message
  | Ambient
  | System

type actor = {
  actor_id : string option;
  display_name : string option;
  authority : Keeper_chat_store.speaker_authority;
}

type item = {
  event_id : string;
  dedupe_key : string;
  keeper_name : string;
  conversation : conversation_ref;
  external_message : external_message_ref option;
  source_label : string;
  actor : actor;
  urgency : urgency;
  content_preview : string;
  content_ref : string option;
  received_at : float;
  metadata : (string * string) list;
}

type event =
  | Recorded of item
  | Claimed_for_turn of {
      event_id : string;
      claim_id : string;
      turn_id : int option;
      claimed_at : float;
    }
  | Resolved of {
      event_id : string;
      resolved_at : float;
      reason : string;
    }
  | Ignored of {
      event_id : string;
      ignored_at : float;
      reason : string;
    }

(** Default stale claim timeout used by {!pending_for_keeper}. *)
val default_claim_stale_after_s : float

val event_id_of_dedupe_key : string -> string

(** {1 Labels and JSON codecs} *)

val urgency_to_string : urgency -> string
val urgency_of_string : string -> urgency option

val surface_ref_to_json : surface_ref -> Yojson.Safe.t
val surface_ref_of_json : Yojson.Safe.t -> (surface_ref, string) result

val conversation_ref_to_json : conversation_ref -> Yojson.Safe.t
val conversation_ref_of_json : Yojson.Safe.t -> (conversation_ref, string) result

val external_message_ref_to_json : external_message_ref -> Yojson.Safe.t

val external_message_ref_of_json :
  Yojson.Safe.t -> (external_message_ref, string) result

val actor_to_json : actor -> Yojson.Safe.t
val actor_of_json : Yojson.Safe.t -> (actor, string) result

val item_to_json : item -> Yojson.Safe.t
val item_of_json : Yojson.Safe.t -> (item, string) result

val event_to_json : event -> Yojson.Safe.t
val event_of_json : Yojson.Safe.t -> (event, string) result

(** {1 Store operations} *)

type record_result =
  [ `Recorded
  | `Duplicate of item
  | `Error of string
  ]

val dedup_window_bytes : int
(** Size of the recent-tail window [record] scans for duplicate
    [event_id]s. The store is append-only and unbounded; scanning only
    this tail keeps [record] O(1) in file size. Exposed for tests that
    need to size input past the window. *)

val attention_path : base_path:string -> keeper_name:string -> string

val record : base_path:string -> item -> record_result
(** Appends [Recorded item] unless [event_id] already appears within the
    last {!dedup_window_bytes} of the log. The dedup scan is bounded to
    that recent tail (gateway redelivery is always recent), so a
    duplicate older than the window is re-appended rather than
    suppressed — a rare, harmless duplicate, never data loss. *)

val claim_for_turn :
  base_path:string ->
  keeper_name:string ->
  event_ids:string list ->
  claim_id:string ->
  turn_id:int option ->
  ?now:float ->
  unit ->
  (unit, string) result

val mark_resolved :
  base_path:string ->
  keeper_name:string ->
  event_ids:string list ->
  reason:string ->
  ?now:float ->
  unit ->
  (unit, string) result

val mark_ignored :
  base_path:string ->
  keeper_name:string ->
  event_ids:string list ->
  reason:string ->
  ?now:float ->
  unit ->
  (unit, string) result

val load_events_result :
  base_path:string -> keeper_name:string -> (event list, string) result

val load_events : base_path:string -> keeper_name:string -> event list

val pending_for_keeper :
  base_path:string ->
  keeper_name:string ->
  ?now:float ->
  ?claim_stale_after:float ->
  limit:int ->
  unit ->
  item list
(** Returns pending items ordered by [received_at], capped to [limit].
    A non-terminal claim older than [claim_stale_after] is projected back
    to pending instead of dropped. *)

val pending_for_keeper_result :
  base_path:string ->
  keeper_name:string ->
  ?now:float ->
  ?claim_stale_after:float ->
  limit:int ->
  unit ->
  (item list, string) result
