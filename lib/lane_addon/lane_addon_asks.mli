(** An installation's questions to the operator (RFC operator-quiz §4.6, K4).

    One append-only log per declaration in the Lane store, with the Keeper
    question lifecycle ({!Keeper_ask.lifecycle_event}): the questions, the
    answer check and the first-terminal-wins fold are the Keeper's own. The
    asker is the installation, named by its declaration id and package title.
    It carries no Keeper continuation and wakes no Keeper.

    There is no expiry. An open question stays open until the operator answers
    it or the package withdraws it. *)

type ask = private
  { ask_id : string  (** The package's request id. *)
  ; declaration_id : string
  ; title : string  (** The package title, which surfaces show as the asker. *)
  ; questions : Keeper_ask.question list
  ; context : string option
  ; asked_at : float
  }

val ask :
  ask_id:string -> declaration_id:string -> title:string -> questions:Keeper_ask.question list ->
  ?context:string -> asked_at:float -> unit -> (ask, string) result
(** At least one question, unique question ids, non-blank ids and title. *)

val questions_of_json : Yojson.Safe.t -> (Keeper_ask.question list, string) result
(** A package's [questions] array, in the Keeper question wire form. *)

type row = string * (ask * Keeper_ask.resolution)

val rows : Lane_addon_store.t -> declaration_id:string -> (row list, string) result
(** The declaration's questions in the order they were asked. No log is no
    question. A log with a damaged line before its last is an error: a reader
    that skipped it would report a shortened history as complete. *)

val declarations : Lane_addon_store.t -> (string list, string) result
(** Every declaration id that has a log, in id order. *)

type record_outcome = Recorded | Already_recorded | Id_reused

val record : Lane_addon_store.t -> ask -> (record_outcome, string) result
(** Appends [Asked] once per request id. The same id asking the same questions
    again is [Already_recorded]; with other questions it is [Id_reused] and
    nothing is appended. *)

type answer_failure =
  | Ask_not_found
  | Already_answered of { answered_at : float }
  | Already_withdrawn of { withdrawn_at : float }
  | Rejected of Keeper_ask.invalid_answer list
  | Store_failed of string

val answer_failure_to_string : answer_failure -> string

val answer :
  Lane_addon_store.t -> declaration_id:string -> ask_id:string ->
  submissions:(string * Keeper_ask.response) list -> responder:Keeper_ask.responder -> now:float ->
  (Keeper_ask.answer list, answer_failure) result
(** Records the operator's answer when the question is open. The first
    terminal event wins: a second answer, or one after the package withdrew,
    is refused with the recorded state. *)

type withdraw_outcome = Withdrawn | Was_answered | Was_withdrawn | Not_asked

val withdraw :
  Lane_addon_store.t -> declaration_id:string -> ask_id:string -> reason:string -> now:float ->
  (withdraw_outcome, string) result
(** Only the package withdraws its own question, through its host request. *)
