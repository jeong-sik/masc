(** Strict wire request for an exact paused-work operator disposition. *)

type t =
  | Resume_owner of Keeper_paused_work_resume_transaction.request
  | Cancel_pending of Keeper_paused_work_cancellation_transaction.pending_request
  | Cancel_active_lease of Keeper_paused_work_cancellation_transaction.request
  | Transfer_owner of
      { to_keeper : string
      ; request : Keeper_paused_work_transfer_transaction.request
      }
  | Settle_from_source_terminal of
      Keeper_paused_work_source_terminal_transaction.request

val schema : string
val of_yojson : Yojson.Safe.t -> (t, string) result
(** Unknown operations, extra fields, invalid numeric fences and mismatched
    source-terminal receipt kinds are rejected. *)
