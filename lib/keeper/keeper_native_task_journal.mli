(** Durable observations for one authenticated Keeper, separate from the root
    chat stream and its terminal boundary. No stream/UI publication occurs here. *)

type source =
  | Operation of Keeper_chat_operation.Operation_id.t
  | Autonomous_turn of Ids.Turn_ref.t

type error =
  | Invalid_scope of string
  | Invalid_observation of string
  | Corrupt of { line : int; detail : string }
  | Conflicting_uuid of string
  | Sequence_exhausted
  | Io_failed of exn
  | Directory_prepare_failed of Keeper_fs_durable_directory.failure
  | Append_failed of Fs_compat.durable_append_error
  | Read_failed of Fs_compat.Private_jsonl_rows.error

type record = private
  { seq : int
  ; recorded_at : float
  ; observation : Runtime_native_tasks.t
  }

type commit = Appended of record | Replayed of record

type 'a outcome =
  { result : ('a, error) result
  ; cleanup_failure : Fs_compat.private_jsonl_operation_failure option
  }
(** A cleanup warning does not turn a durable commit into a failed append.
    [None] means descriptor settlement completed without a reported failure. *)

type issue =
  { event_uuid : string
  ; error : error option
  ; cleanup_failure : Fs_compat.private_jsonl_operation_failure option
  }
(** Retained observations of failed persistence / descriptor cleanup. A later
    successful write does not erase an earlier issue. No automatic retry. *)

type t
type publication
type reader

val create : base_path:string -> keeper_name:string -> source:source ->
  redact_text:(string -> string) -> t
(** Canonicalizes the authenticated workspace once. An invalid scope is retained
    as a typed error, not raised into the root response callback. *)
val prepare : t -> attempt:Runtime_native_tasks.attempt ->
  Keeper_claude_task_binding.bound -> (publication, error) result
(** Only a private runtime/input binding can mint a publication. Captures the
    original input ticket/native occurrence and redacts metadata leaves only.
    Public JSON decoding cannot mint this capability. *)
val append : publication -> commit outcome
(** Reads, validates every complete row, deduplicates UUID, assigns sequence and
    appends in one fd-lock transaction. Only an uncommitted non-newline suffix is
    recovered. Complete corrupt rows block writes. No compaction/rename/expiry.
    Concurrent callers sharing cold directory preparation must run inside an
    Eio scheduler, as the receiver collectors do: a directory preparation waiter
    uses [Eio.Promise.await]. *)
val observe : t -> attempt:Runtime_native_tasks.attempt ->
  Keeper_claude_task_binding.bound -> commit outcome
(** [prepare] + [append], retaining typed issues for this collector. Does not
    change native effects, model buffers, response/turn status or root outcome. *)
val health : t -> issue list
val report : keeper_name:string -> commit outcome -> unit
(** Reports persistence issues separately from stream protocol/mapping errors. *)

val open_reader : base_path:string -> keeper_name:string ->
  receiver_generation:string -> session_id:string -> (reader, error) result
(** Read-only authenticated scope. Neither reader nor decoded rows grant append
    authority. All opaque path components are encoded injectively. *)
val reader_of_publication : publication -> reader
val path : reader -> string
val read : reader -> record list outcome
(** Full receiver history in commit order under the writer's fd-lock family.
    A torn suffix is uncommitted and excluded; complete malformed rows fail. *)
val error_to_string : error -> string
