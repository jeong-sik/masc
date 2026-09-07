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
      channel_name : string option;
      parent_channel_id : string option;
      thread_id : string option;
    }
  | Slack of {
      team_id : string option;
      channel_id : string;
      channel_name : string option;
          (** What the room is called, where the workspace let us ask. The id
              is the identity and stays; the name is for the reader, who has
              no way to tell [C09TK9L4DV4] from [C09TK9L4DV5]. *)
      thread_ts : string option;
    }
  | Webhook of { source : string; event_id : string }
  | Agent
  | Broadcast
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

(** What the store records: an external message arrived and this is what it
    was. Whether a Keeper still owes it an answer is not here -- that is the
    event queue's pending entry, which is what a turn consumes and settles.
    Two stores answering one question is how they came to disagree. *)
type event = Recorded of item

val event_id_of_dedupe_key : string -> string

(** {1 Labels and JSON codecs} *)

val urgency_to_string : urgency -> string

val surface_ref_to_json : surface_ref -> Yojson.Safe.t
val surface_ref_of_json : Yojson.Safe.t -> (surface_ref, string) result

val conversation_ref_to_json : conversation_ref -> Yojson.Safe.t
val conversation_ref_of_json : Yojson.Safe.t -> (conversation_ref, string) result

val external_message_ref_to_json : external_message_ref -> Yojson.Safe.t

val external_message_ref_of_json :
  Yojson.Safe.t -> (external_message_ref, string) result

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

val record : base_path:string -> item -> record_result
(** Appends [Recorded item] unless [event_id] already appears within the
    last {!dedup_window_bytes} of the log. The dedup scan is bounded to
    that recent tail (gateway redelivery is always recent), so a
    duplicate older than the window is re-appended rather than
    suppressed — a rare, harmless duplicate, never data loss. *)

val attention_path : base_path:string -> keeper_name:string -> string

val load_events : base_path:string -> keeper_name:string -> event list

val recorded_items_by_event_ids :
  base_path:string -> keeper_name:string -> event_ids:string list ->
  (string * item) list
(** One-scan batch counterpart to [load_events] +
    per-id [Recorded] lookup: loads the event log exactly once, then
    resolves every id in [event_ids] against that one in-memory load
    (first [Recorded] match per id, same semantics as looking each id up
    individually). An id with no [Recorded] entry is simply absent from
    the result; the returned pairs preserve [event_ids]' order. Calling
    [load_events] once per id here is the same O(file)-per-call trap the
    [dedup_window_bytes] comment above documents for [record]'s dedup
    scan — this is the read-side counterpart, for RFC-0377's turn-batched
    Connector_attention intake (N companions must not cost N full-file
    reads). *)

val load_recent_evidence_events :
  base_path:string -> keeper_name:string -> event list
(** Read a bounded recent tail sized for prompt evidence rather than connector
    redelivery. The first and last partial lines are excluded when the file is
    larger than the internal evidence window. This is not a whole-history API. *)

val store_read_error : base_path:string -> keeper_name:string -> string option
(** [Some detail] when the store exists and this build cannot decode it, [None]
    otherwise. A log that will not parse is the Keeper's own evidence failing,
    which no other surface reports; the operator inventory raises a row on it.
    Reading is all-or-nothing by line, so one bad row fails the whole load. *)
