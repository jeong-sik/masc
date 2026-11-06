open Keeper_types_profile
open Keeper_msg_async_types

type worker_outcome =
  | Worker_finished of tool_result
  | Worker_interrupted of {reason : string}
  | Worker_waiting of
      { dependencies : Keeper_composition_dependency.t list
      ; result : tool_result }

let worker_finished result = Worker_finished result
let worker_interrupted ~reason = Worker_interrupted {reason}

let worker_waiting_for_dependencies ~dependencies result =
  let dependencies = Keeper_composition_dependency.normalize dependencies in
  match result, dependencies with
  | Tool_result.Deferred _, _ :: _ -> Ok (Worker_waiting {dependencies;result})
  | Tool_result.Deferred _, [] -> Error "result waiting requires an original dependency"
  | (Tool_result.Completed _ | Tool_result.Failed _), _ ->
      Error "result waiting requires a typed deferred result"
;;

type durable_queued_proof = { queued_entry : entry }

type canonical_queued_error =
  | Canonical_queued_absent
  | Canonical_queued_unreadable of string
  | Canonical_queued_access_rejected of access_rejection
  | Canonical_queued_runtime_nonqueued of request_status
  | Canonical_queued_publication_ambiguous of request_status
  | Canonical_queued_runtime_conflict
  | Canonical_queued_not_queued of request_status
  | Canonical_queued_noncanonical_location of request_status

let worker_cancel_source_to_string = function
  | Operator_request -> "operator"
  | Runtime_cancellation -> "runtime"
;;

let same_entry_record = Keeper_msg_async_record.same_entry_record
let canonical_terminal_error_to_string = Keeper_msg_async_record.canonical_terminal_error_to_string
let durable_terminal_entry = Keeper_msg_async_record.durable_terminal_entry
let persistence_target_to_string = Keeper_msg_async_record.persistence_target_to_string
let status_to_string = Keeper_msg_async_record.status_to_string
let access_rejection_to_json = Keeper_msg_async_record.access_rejection_to_json
let submit_error_to_json = Keeper_msg_async_record.submit_error_to_json
let submit_outcome_to_json = Keeper_msg_async_record.submit_outcome_to_json
let cancel_result_to_json = Keeper_msg_async_record.cancel_result_to_json

let durable_queued_entry proof = proof.queued_entry

let canonical_queued_error_to_string = function
  | Canonical_queued_absent -> "canonical queued request record is absent"
  | Canonical_queued_unreadable reason ->
    "canonical queued request record is unreadable: " ^ reason
  | Canonical_queued_access_rejected rejection ->
    "canonical queued request access rejected: "
    ^ Yojson.Safe.to_string (access_rejection_to_json rejection)
  | Canonical_queued_runtime_nonqueued status ->
    Printf.sprintf "canonical queued proof rejected process-local status=%s"
      (status_to_string status)
  | Canonical_queued_publication_ambiguous status ->
    Printf.sprintf "canonical queued proof rejected process-local terminal publication status=%s"
      (status_to_string status)
  | Canonical_queued_runtime_conflict ->
    "process-local queued request differs from the canonical durable record"
  | Canonical_queued_not_queued status ->
    Printf.sprintf "canonical request record is not queued status=%s"
      (status_to_string status)
  | Canonical_queued_noncanonical_location status ->
    Printf.sprintf "queued request record is outside the canonical active partition status=%s"
      (status_to_string status)
;;

module Request_key = struct
  type t =
    { base_path : string
    ; submitted_by : string
    ; request_id : string
    }

  let equal a b =
    String.equal a.base_path b.base_path
    && String.equal a.submitted_by b.submitted_by
    && String.equal a.request_id b.request_id
  ;;

  let hash key = Hashtbl.hash (key.base_path, key.submitted_by, key.request_id)
end

module Request_table = Hashtbl.Make (Request_key)

module Store_transition_key = struct
  type t =
    { base_path : string
    ; request_id : string
    }

  let equal a b =
    String.equal a.base_path b.base_path
    && String.equal a.request_id b.request_id
  ;;

  let hash key = Hashtbl.hash (key.base_path, key.request_id)
end

module Store_transition_table = Hashtbl.Make (Store_transition_key)

module Keeper_lane_key = struct
  type t =
    { base_path : string
    ; keeper_name : Keeper_id.Keeper_name.t
    }

  let equal a b =
    String.equal a.base_path b.base_path
    && Keeper_id.Keeper_name.equal a.keeper_name b.keeper_name
  ;;

  let hash key =
    Hashtbl.hash
      (key.base_path, Keeper_id.Keeper_name.to_string key.keeper_name)
  ;;
end

module Keeper_lane_table = Hashtbl.Make (Keeper_lane_key)

type store_transition_lock =
  { mutex : Eio.Mutex.t
  ; mutable users : int
  }

(** Per-Keeper lane gate, deliberately distinct from [store_transition_lock].
    The gate is an [Eio.Semaphore] with one token so admission can be bounded
    by a deadline: [Eio.Semaphore.acquire] is cancellation-safe (a cancelled
    waiter returns its token via the [Sem_state] handoff protocol) and resumes
    waiters FIFO. [Eio.Mutex.lock] offers no bounded wait at all, which is how
    a hung durable write used to leak the lane permanently and hang every
    later submit for that keeper (#25398). *)
type lane_gate =
  { sem : Eio.Semaphore.t
  ; mutable users : int
  }

let mu = Eio.Mutex.create ()
let pending : entry Request_table.t = Request_table.create 16
let transition_locks : Eio.Mutex.t Request_table.t = Request_table.create 16
let active_switches : Eio.Switch.t Request_table.t = Request_table.create 16
let store_transition_locks : store_transition_lock Store_transition_table.t =
  Store_transition_table.create 16
let reserved_request_ids : unit Store_transition_table.t =
  Store_transition_table.create 16
let keeper_submission_locks : lane_gate Keeper_lane_table.t =
  Keeper_lane_table.create 16
let keeper_persistence_locks : lane_gate Keeper_lane_table.t =
  Keeper_lane_table.create 16
