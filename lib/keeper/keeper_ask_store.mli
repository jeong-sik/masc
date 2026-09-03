(** Keeper_ask_store — the durable per-Keeper question log.

    Append-only JSONL at
    [<base_path>/.masc/keeper_ask/<sanitized-keeper>.jsonl], folded into open
    questions by {!Keeper_ask.fold_events}. Layout and failure handling mirror
    {!Keeper_external_attention}.

    Writes are optimistic. Two surfaces can submit an answer for the same ask
    at once, and nothing here locks the file: both lines may land. The fold
    settles the log on first write, so every reader agrees on the winner, but a
    caller that needs to know whether its own submission is the one that counts
    must read {!settled} after writing rather than trusting {!answer}'s [Ok]. *)

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
    submissions do not satisfy it. See the optimistic-write note above. *)

val withdraw :
  base_path:string ->
  keeper_name:string ->
  ask_id:string ->
  reason:string ->
  now:float ->
  (unit, withdraw_failure) result
(** Appends [Withdrawn]. Only the asking Keeper withdraws a question; nothing
    withdraws one on its behalf after an interval. *)

val load_events : base_path:string -> keeper_name:string -> Keeper_ask.event list
(** Reads the whole log. A final line that does not decode is dropped: that is
    the shape an append cut short by a crash leaves, and losing every recorded
    question to one truncated tail is worse than dropping the incomplete
    write. A line that does not decode anywhere else fails the read, which
    surfaces as a warning and an empty list rather than reporting a shortened
    history as complete. *)

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
