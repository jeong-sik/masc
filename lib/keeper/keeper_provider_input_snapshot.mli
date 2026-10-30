(** Exact canonical model input retained per Keeper turn.

    The provider SDK intentionally exposes only the serialized HTTP body's
    digest and byte count. At that same pre-dispatch boundary MASC owns the
    final projected message list, system prompt, and effective tool surface.
    This store persists those values as content-addressed artifacts and joins
    them to the TurnRecord with the same [turn_ref]. Repeated history messages
    therefore occupy one blob even when many turns transmit them, and a
    newest durable snapshot lets the next turn derive an immutable per-Keeper
    reuse map. A map miss uses the blob store's existing strict-publication
    memo: it reuses a physical file only after checking the same owned file
    snapshot and exact bytes, otherwise strictly republishes it. Ordinary
    non-strict writes cannot establish that memo. Snapshot rows keep empty
    artifact previews, so message text lives
    only in the blob. The administrator-only endpoints list a row's parts and
    return one listed part's bytes at a time. *)

type artifact =
  { art_bytes : int
  ; art_content_ref : string
  }

type message =
  { msg_index : int
  ; msg_role : string
  ; msg_artifact : artifact
  ; msg_media : (string * Agent_core.History.stored) list
    (** The [Stored] media the message blob names, with their media types.
        Blob retention reads this row, not the message blob, so the row
        keeps those bytes live while it is retained. *)
  }

type tool_schema =
  { ts_index : int
  ; ts_name : string
  ; ts_artifact : artifact
  }

type t =
  { keeper : string
  ; trace_id : string
  ; absolute_turn : int
  ; turn_ref : Ids.Turn_ref.t
  ; runtime_profile : string
  ; captured_at : float
  ; wire : Llm_provider.Request_wire_observer.observation
  ; system_prompt : artifact option
  ; messages : message list
  ; tool_schemas : tool_schema list
  }

(** One retained part of a request. Parts are listed in the order the request
    carries them: the system prompt, the messages, the tool schemas.
    [part_index] is the position in that order. *)
type part_kind =
  | System_prompt
  | Message of { role : string }
  | Tool_schema of { name : string }

type part =
  { part_index : int
  ; part_kind : part_kind
  ; part_bytes : int
  ; part_sha256 : string
  }

(** A row and its parts, read without opening any blob. *)
type manifest =
  { mf_snapshot : t
  ; mf_parts : part list
  }

(** One part's exact stored bytes. *)
type part_content =
  { pc_keeper : string
  ; pc_turn_ref : Ids.Turn_ref.t
  ; pc_part : part
  ; pc_text : string
  }

type read_error =
  | Unknown_keeper of string
  | Store_read_failed of Dated_jsonl.read_error
  | Malformed_snapshot of string
  | Snapshot_not_found of Ids.Turn_ref.t
  | Invalid_artifact_reference of string
  | Artifact_read_failed of string
  | Artifact_missing of string
  | Artifact_length_mismatch of
      { sha256 : string
      ; expected : int
      ; actual : int
      }
  | Part_not_found of
      { turn_ref : Ids.Turn_ref.t
      ; index : int
      }

val read_error_to_string : read_error -> string

val write_best_effort :
  config:Workspace.config ->
  keeper:string ->
  trace_id:string ->
  absolute_turn:int ->
  runtime_profile:string ->
  wire:Llm_provider.Request_wire_observer.observation ->
  system_prompt:string ->
  messages:Agent_core.Types.message list ->
  tools:Agent_core.Tool.t list ->
  unit
(** Persist one immutable snapshot. Payload preparation uses the shared CPU
    pool; each artifact reuse miss uses the shared IO pool for its content
    addressing and strict durable reuse. A cold, changed or evicted blob still
    requires strict payload and parent sync; concurrent cold misses may each
    publish. Reuse lookup, map updates and the
    snapshot append remain on the caller. The pool adapters retain their
    inline policy when no pool is available, outside Eio, or when the caller is
    already a worker.
    Cancellation propagates; storage failures are logged and do not fail the
    Keeper turn. Accepted work is never retried inline. *)

val read_manifest :
  config:Workspace.config ->
  keeper:string ->
  turn_ref:Ids.Turn_ref.t ->
  (manifest, read_error) result
(** The row for exactly [turn_ref] and the kind, byte count and SHA-256 of
    each part. The digests come from the row's artifact markers; no blob is
    read. *)

val read_part :
  config:Workspace.config ->
  keeper:string ->
  turn_ref:Ids.Turn_ref.t ->
  index:int ->
  (part_content, read_error) result
(** The stored bytes of one part the row for [turn_ref] lists.
    [Part_not_found] when the row has no part at [index]: a digest alone
    never opens a blob, because the blob store is shared by the whole
    workspace. The blob store checks the bytes against their digest. *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result

val manifest_schema : string
val part_schema : string
val manifest_to_json : manifest -> Yojson.Safe.t
val part_content_to_json : part_content -> Yojson.Safe.t

(** {1 Payloads} *)

(** The bytes of one artifact and their SHA-256 hex digest: what the domain
    pool computes for every message and tool schema of a snapshot before the
    writer looks up reuse and stores what is new. *)
type payload =
  { payload_bytes : string
  ; payload_sha256 : string
  }

(** The canonical message encoding as the snapshot stores it, with its
    digest. Pure; safe on any domain. *)
val message_payload : Agent_core.Types.message -> payload

(** The tool schema encoding as the snapshot stores it, with its digest. Pure;
    safe on any domain. *)
val tool_schema_payload : Agent_core.Tool.t -> payload
