(** Authenticated operator boundary for exact paused-lane work disposition. *)

type request = Keeper_paused_work_operator_request.t =
  | Resume_owner of Keeper_paused_work_resume_transaction.request
  | Cancel_pending of Keeper_paused_work_cancellation_transaction.pending_request
  | Cancel_active_lease of Keeper_paused_work_cancellation_transaction.request
  | Transfer_owner of
      { to_keeper : string
      ; request : Keeper_paused_work_transfer_transaction.request
      }
  | Settle_from_source_terminal of
      Keeper_paused_work_source_terminal_transaction.request

type outcome =
  | Resumed of Keeper_paused_work_resume_transaction.success
  | Cancelled of Keeper_paused_work_cancellation_transaction.success
  | Transferred of Keeper_paused_work_transfer_transaction.success
  | Source_terminal_settled of Keeper_paused_work_source_terminal_transaction.success

type error =
  | Invalid_request of string
  | Resume_rejected of Keeper_paused_work_resume_transaction.error
  | Cancellation_rejected of Keeper_paused_work_cancellation_transaction.error
  | Transfer_rejected of Keeper_paused_work_transfer_transaction.error
  | Source_terminal_rejected of Keeper_paused_work_source_terminal_transaction.error

type error_class =
  [ `Bad_request
  | `Not_found
  | `Conflict
  | `Unavailable
  ]

type inventory_error =
  | Inventory_meta_read_failed of string
  | Inventory_meta_missing
  | Inventory_queue_read_failed of string

val request_of_yojson : Yojson.Safe.t -> (request, string) result
(** Strict request codec. Unknown or extra fields are rejected. Exact source or
    lease JSON comes from {!inventory_json}; no post-id/prose lookup occurs. *)

val execute :
  Workspace.config -> keeper_name:string -> request -> (outcome, error) result

val outcome_to_yojson : outcome -> Yojson.Safe.t
val outcome_projection_complete : outcome -> bool
val error_to_string : error -> string
val error_class : error -> error_class

val inventory_json :
  Workspace.config -> keeper_name:string -> (Yojson.Safe.t, inventory_error) result
val inventory_error_to_string : inventory_error -> string
(** Durable owner identity plus exact queue revision, pending stimuli, active
    lease and transition outbox. Pending rows also carry the typed continuation
    binding and source-terminal receipt kind required to construct an exact
    request. This is intentionally an authenticated admin surface because
    payloads may contain channel/customer content. *)
