(** Keeper_ask_store — the durable per-Keeper question log.

    Append-only JSONL at
    [<base_path>/.masc/keeper_ask/<sanitized-keeper>.jsonl], folded into open
    questions by {!Keeper_ask.fold_events}. Layout and failure handling mirror
    {!Keeper_external_attention}.

    Durable appends are serialized by a per-path mutex and file lock. Answer
    preflight remains optimistic: two surfaces can validate an open ask before
    either appends, so both answer rows may land. The fold chooses the first
    recorded answer. {!answer} rereads the canonical fold before returning
    [Ok], and reports the other winner or a committed-but-unconfirmed append
    explicitly. *)

type answer_failure =
  | Ask_not_found of { ask_id : string }
  | Already_answered of {
      answers : Keeper_ask.answer list;
      responder : Keeper_ask.responder;
      answered_at : float;
    }
      (** Carries the answer that already landed, not a bare rejection: the
          second surface has to be able to show what was chosen. *)
  | Already_withdrawn of { reason : string; withdrawn_at : float }
  | Rejected of Keeper_ask.invalid_answer list
  | Store_failed of string
  | Answer_recorded_unconfirmed of { detail : string }
      (** The answer append committed, but its canonical first-winner read
          did not confirm this submission. Never report it as an absent write
          or wake from the caller's optimistic answer. *)

type read_error =
  | Log_read_failed of { path : string; detail : string }
  | Log_decode_failed of { path : string; line : int; detail : string }

type row = string * (Keeper_ask.ask * Keeper_ask.resolution)
type rows_snapshot = Missing_log | Stored_rows of row list

val read_error_to_string : read_error -> string
val read_error_path : read_error -> string

val rows_result :
  base_path:string -> keeper_name:string -> (rows_snapshot, read_error) result
(** Authoritative fold. A missing log is distinct from an existing empty log;
    read/decode failures never authorize absence. The existing final-line
    crash-reader policy is unchanged. *)

type discovered_log =
  | Canonical_rows of { keeper_name : string; rows : row list }
  | Unreadable_log of read_error

val discover_rows_result : base_path:string -> (discovered_log list, read_error) result
(** Read each discovered owned log once in deterministic order. The canonical
    owner comes from its Asked records, never from a sanitized filename. Every
    Asked record must name that same owner and derive this exact log_path.
    Existing empty logs carry no recovery work. Discovery failures and
    unreadable entries remain explicit while healthy independent owners can
    still recover. A log that disappears between directory listing and its owned
    read returns a transient [Unreadable_log] ("discovered ask log disappeared
    before its owned read") that resolves on the next read once the directory
    listing no longer includes the removed file. *)

type withdraw_failure =
  | Withdraw_ask_not_found of { ask_id : string }
  | Withdraw_already_answered of { answered_at : float }
  | Withdraw_already_withdrawn of { withdrawn_at : float }
  | Withdraw_store_failed of string

val answer_failure_to_string : answer_failure -> string
val withdraw_failure_to_string : withdraw_failure -> string

val log_path : base_path:string -> keeper_name:string -> string
(** The file the Keeper's questions are appended to. Exposed so callers can
    name it in errors and receipts instead of rebuilding the path. *)

val record_ask : base_path:string -> Keeper_ask.ask -> (unit, string) result
(** Appends [Asked]. The Keeper does not wait: recording a question neither
    suspends its lane nor blocks its turn. *)

val answer :
  base_path:string ->
  keeper_name:string ->
  ask_id:string ->
  submissions:(string * Keeper_ask.response) list ->
  responder:Keeper_ask.responder ->
  now:float ->
  (Keeper_ask.answer list, answer_failure) result
(** Validates [submissions] against the recorded ask and appends [Answered].
    Rejects before writing when the ask is unknown, already resolved, or the
    submissions do not satisfy it. A successful append is reread from the
    canonical store before acknowledging the first winner. *)

val withdraw :
  base_path:string ->
  keeper_name:string ->
  ask_id:string ->
  reason:string ->
  now:float ->
  (unit, withdraw_failure) result
(** Appends [Withdrawn]. Only the asking Keeper withdraws a question; nothing
    withdraws one on its behalf after an interval. *)

val rows :
  base_path:string ->
  keeper_name:string ->
  (string * (Keeper_ask.ask * Keeper_ask.resolution)) list

val open_asks : base_path:string -> keeper_name:string -> Keeper_ask.ask list

val settled :
  base_path:string ->
  keeper_name:string ->
  ask_id:string ->
  Keeper_ask.resolution option
(** The current resolution of one ask, or [None] when no such ask was
    recorded. *)

val open_ask_count : base_path:string -> keeper_name:string -> int
(** How many questions this Keeper is waiting on. Counts the stored rows
    without loading every ask into the caller; the ask tool handlers and the
    [/api/v1/keepers/asks] route report it, the waiting inventory does not
    read it. *)

module For_testing : sig
  val answer_with_interleaving :
    before_append:(unit -> unit) -> after_append:(unit -> unit) ->
    base_path:string -> keeper_name:string -> ask_id:string ->
    submissions:(string * Keeper_ask.response) list ->
    responder:Keeper_ask.responder -> now:float ->
    (Keeper_ask.answer list, answer_failure) result
  (** The production append/read boundary with another writer interleaved
      after preflight, or storage made unreadable after a committed append. *)
end
