(** One Telegram poll/commit step. The authenticated bot owns a durable next
    offset. Fetching at that offset acknowledges only previously committed
    updates. No background fiber, retry policy, sleep or lifecycle budget lives
    here. Server integration supplies the loop and the actual Keeper acceptor. *)
type t

type error =
  | Api of Telegram_rest_client.error
  | Cursor_refused of string
  | Acceptance_refused of { update_id : int64; detail : string }
  | Storage_failed of string

val pp_error : Format.formatter -> error -> unit

val open_cursor :
  ?post:Telegram_rest_client.post ->
  ?clock:[> float Eio.Time.clock_ty] Eio.Resource.t ->
  client:Telegram_rest_client.t -> path:string -> unit -> (t, error) result
(** Calls getMe and binds the cursor to its actual bot identity. A cursor from
    another bot or malformed/unreadable persisted state refuses construction.
    Missing state starts with no offset, preserving the unconfirmed queue. *)

val bot_user_id : t -> int64
val operation_id : t -> Telegram_rest_client.update -> string
(** Stable across token rotation, process restart and redelivery. *)

type ignored_reason = Unbound_chat | Bot_message | Unsupported_update | Empty_message

type disposition =
  | Accepted of Gate_protocol.outbound_message
  | Intentionally_ignored of ignored_reason

(** Observational counters; none governs admission or terminates polling. *)
type report = {
  next_offset : int64 option;
  accepted : int;
  ignored : int;
  already_committed : int;
}

val step :
  ?post:Telegram_rest_client.post ->
  ?clock:[> float Eio.Time.clock_ty] Eio.Resource.t ->
  t -> poll_timeout_sec:int ->
  accept:(operation_id:string -> Telegram_rest_client.update -> (disposition, string) result) ->
  unit -> (report, error) result
(** Re-reads and syncs the cursor before the HTTP request, then serializes page
    settlement against other fibers/processes at the same cursor path. A stale
    concurrent page cannot replay already committed updates. The accept callback
    must only durably submit an operation, never run a model or send a reply.
    Accepted receipts must identify this update, Keeper and Telegram channel and
    have confirmed acceptance. Missing, wrong, Lost or Acceptance_uncertain
    receipts refuse the update; no later update is accepted past that frontier.

    Each accepted/explicitly ignored update is persisted with the shared strict
    atomic writer before its successor offset is usable. A failed sync does not
    authorize acknowledgment; every read must establish sync again, including
    after an uncertain rename. This guarantees process-restart recovery under
    the Fs_compat strict-writer contract, not hardware/power-loss persistence.
    Cancellation remains cancellable while fetching or waiting for the lock;
    settlement holds the shared durable lock through acceptance and publication. *)
