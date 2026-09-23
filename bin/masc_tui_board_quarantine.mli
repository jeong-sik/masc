(** The Board-attention rows of a Keeper's Info tab.

    A partition the judgment worker cannot finish is blocked and its candidate
    put in quarantine: a restart that cut the judgment call, every judgment
    model refusing, a call step that could not be recorded, and the other
    causes in {!category_words}. The worker never retries these on its own.
    Only an operator's requeue takes one out. This module says how many of a
    Keeper's partitions are waiting for that, grouped by what stopped them,
    and which one the requeue key acts on. *)

(** One row of a Keeper's Board-attention quarantine inventory
    ([GET /api/v1/keepers/<name>/board-attention/quarantines]). A row this
    binary cannot read -- a failure category a newer server added -- is kept
    as [Unreadable_row] and counted, not dropped: a count that silently shrank
    would tell the operator fewer partitions are stuck than are. *)
type row =
  | Item of Masc.Keeper_board_attention_quarantine_command.inventory_item
  | Unreadable_row of string

type t =
  { rows : row list
  ; errors : Masc.Keeper_board_attention_quarantine_command.inventory_error list
  ; unreadable_errors : string list
  }

val decode : Yojson.Safe.t -> (t, string) result
(** [Error] only when the body is not the inventory's shape at all (not an
    object, or [items] / [errors] not lists). Each row is read by the
    inventory's own reader, beside the writer the server uses. *)

type tone =
  | Plain
  | Dim
  | Warn
  | Bad

val category_words :
  Masc.Keeper_board_attention_candidate.quarantine_failure_category -> string
(** What stopped the partition, in words an operator reads. *)

val waiting :
  t ->
  Masc.Keeper_board_attention_quarantine_command.inventory_item list
(** The rows still waiting for an operator: quarantined, or requeue asked for
    and not finished. Oldest first. A row whose candidate says requeued is
    left out: the inventory reads only the candidate ledger, so it is counted
    as requeued on that ledger, not as finished. *)

val oldest_waiting :
  t ->
  Masc.Keeper_board_attention_quarantine_command.inventory_item option
(** The row the requeue key acts on: the head of {!waiting}. *)

val requeue_request :
  Masc.Keeper_board_attention_quarantine_command.inventory_item ->
  Masc.Keeper_board_attention_quarantine_command.request
(** The recovery request for one row, fenced by the quarantine id the row was
    read with, so a newer quarantine of the same partition is not requeued by
    a press made against the old one. *)

val lines :
  now:float ->
  (string, t) Masc_tui_fetched.t ->
  keeper_name:string ->
  (tone * string) list
(** The section body: a summary, then one line per failure category with its
    count and its oldest row (the first line holds the requeue key's target).
    Every wire string is put through [Terminal_text] before it is returned. *)
