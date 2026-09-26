module S = Keeper_durable_store_scan

module Id = struct
  type t =
    | Keeper_meta
    | Memory_current
    | Goal_store
    | Gate_pending
    | Official_client_session
    | Librarian_range_receipts
    | Memory_source_current
    | Disposition_receipts
    | Board_posts
    | Provider_inputs
    | Turn_records
    | Turn_boundaries
    | Librarian_progress
    | Librarian_official_progress
    | Turn_fragments
    | Memory_absorbed
    | Memory_os_events
  [@@deriving enumerate]
end

module Refusing = struct
  type t =
    | Keeper_meta
    | Memory_current
  [@@deriving enumerate]
end

module Reported = struct
  type t = Goal_store [@@deriving enumerate]
end

type report = S.report =
  { rows : int
  ; refused : int
  ; first_refusal : string option
  }

type scan = S.store_scan

type reader =
  | Refuse_boot of Refusing.t * scan
  | Degrade_typed of Reported.t
  | Preflight_only of scan

let reader : Id.t -> reader = function
  | Id.Keeper_meta -> Refuse_boot (Refusing.Keeper_meta, S.keeper_meta_store)
  | Id.Memory_current -> Refuse_boot (Refusing.Memory_current, S.memory_os_current_store)
  | Id.Goal_store -> Degrade_typed Reported.Goal_store
  | Id.Gate_pending -> Preflight_only S.gate_pending_store
  | Id.Official_client_session -> Preflight_only S.official_client_session_store
  | Id.Librarian_range_receipts -> Preflight_only S.librarian_range_receipt_store
  | Id.Memory_source_current -> Preflight_only S.memory_source_current_store
  | Id.Disposition_receipts -> Preflight_only S.disposition_receipt_store
  | Id.Board_posts -> Preflight_only S.board_posts_store
  | Id.Provider_inputs -> Preflight_only S.provider_input_store
  | Id.Turn_records -> Preflight_only S.turn_record_store
  | Id.Turn_boundaries -> Preflight_only S.turn_boundary_store
  | Id.Librarian_progress -> Preflight_only S.librarian_progress_store
  | Id.Librarian_official_progress -> Preflight_only S.librarian_official_progress_store
  | Id.Turn_fragments -> Preflight_only S.turn_fragment_store
  | Id.Memory_absorbed -> Preflight_only S.memory_absorbed_store
  | Id.Memory_os_events -> Preflight_only S.memory_os_events_store
;;

let name id =
  match reader id with
  | Refuse_boot (_, scan) | Preflight_only scan -> scan.S.store
  | Degrade_typed Reported.Goal_store -> "goal store"
;;

let run (scan : scan) ~base_path = scan.S.scan ~base_path
let on_refusal (scan : scan) = scan.S.on_refusal
