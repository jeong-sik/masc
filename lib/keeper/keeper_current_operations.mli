(** Immutable Keeper work projection with no inferred progress, ETA, or store. *)

type source = private
  | Event_queue_pending of
      { revision : int64
      ; stimulus : Keeper_event_queue.stimulus
      }
  | Event_queue_lease of
      { revision : int64
      ; lease : Keeper_event_queue_state.lease
      }
  | Event_queue_outbox of
      { revision : int64
      ; entry : Keeper_event_queue_state.outbox_entry
      }
  | Event_queue_parked of
      { revision : int64
      ; entry : Keeper_event_queue_state.parked_entry
      }
  | Async_request of Keeper_msg_async.entry

type t =
  { keeper_name : string
  ; source : source
  }

type source_name =
  | Event_queue_source
  | Async_request_source

type read_error =
  | Durable_read_failed of string
  | Access_rejected of Keeper_msg_async.access_rejection
  | Async_keeper_mismatch of
      { request_id : string
      ; expected_keeper : string
      ; actual_keeper : string
      }
  | Async_terminal_entry of
      { request_id : string
      ; status : Keeper_msg_async.request_status
      }
  | Async_active_entry_has_completion_time of
      { request_id : string
      ; completed_at : float
      }

type unavailable =
  { source : source_name
  ; keeper_name : string
  ; error : read_error
  }

type 'a availability =
  | Available of 'a
  | Unavailable of unavailable

type snapshot =
  { keeper_name : string
  ; event_queue : t list availability
  ; async_requests : t list availability
  }

val project_event_queue_state :
  keeper_name:string -> Keeper_event_queue_state.t -> t list

val project_async_entries :
  keeper_name:string -> Keeper_msg_async.entry list -> (t list, read_error) result

val project_snapshot :
  keeper_name:string ->
  event_queue:(Keeper_event_queue_state.t, read_error) result ->
  async_requests:(Keeper_msg_async.entry list, read_error) result ->
  snapshot
(** Pure adapter seam. Callers must supply reads from canonical durable
    sources; a process-local cache is not a substitute. *)

val to_yojson : t -> Yojson.Safe.t
val snapshot_to_yojson : snapshot -> Yojson.Safe.t
val render : t -> string
