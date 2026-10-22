(** The public error vocabulary of Keeper chat operations, shared by the
    server that sends it and the TUI that reads it back: one closed kind, its
    wire code and fixed message, and what a failure of that kind before
    acceptance says about admission. Diagnostic text never travels here; it
    stays with the server's typed cause and operator log. *)

type kind =
  | Invalid_input | Unknown_operation | Not_queued | Idempotency_conflict
  | Native_call_unsettled | Store_unavailable | Owner_unavailable | Owner_stopping
  | Interrupt_failed | Operation_forbidden | Keeper_paused | Unknown_keeper
  | Journal_unreadable | Journal_corrupt | Journal_missing | Journal_pruned
  | Cursor_refusal of Keeper_chat_event_log.cursor_refusal

val all : kind list
(** Every kind, derived. *)

val code : kind -> string
(** The wire value of [error] / [error_code] / a run error's [code]. *)

val message : kind -> string

val of_code : string -> kind option
(** The kind whose {!code} is [wire], read off {!all}; [None] for any other
    value. *)

(** What a failure that arrived before the client observed acceptance says
    about the operation. *)
type pre_acceptance =
  | Not_accepted
      (** The server answered before any Keeper Owner wrote the operation, so
          nothing was admitted under its id. *)
  | Acceptance_unknown
      (** The failure may follow a durable admission; only a read of the exact
          operation settles it. *)

val pre_acceptance : kind -> pre_acceptance
(** [Owner_unavailable] is [Not_accepted]: the request never reached an
    Owner, because the inventory was not installed or the keeper's Owner was
    absent or failed to start. [Store_unavailable] stays
    [Acceptance_unknown]: the Owner may have committed before its store
    failed. *)
