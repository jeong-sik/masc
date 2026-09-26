(* The indices are closed polymorphic variants rather than abstract types so
   the checker knows the three are distinct and drops the arms a store's
   index rules out. *)
type refuse_boot = [ `Refuse_boot ]
type degrade_typed = [ `Degrade_typed ]
type preflight_only = [ `Preflight_only ]

type _ t =
  | Keeper_meta : refuse_boot t
  | Memory_current : refuse_boot t
  | Goal_store : degrade_typed t
  | Gate_pending : preflight_only t
  | Official_client_session : preflight_only t
  | Librarian_range_receipts : preflight_only t
  | Memory_source_current : preflight_only t
  | Disposition_receipts : preflight_only t
  | Board_posts : preflight_only t
  | Provider_inputs : preflight_only t
  | Turn_records : preflight_only t
  | Turn_boundaries : preflight_only t
  | Librarian_progress : preflight_only t
  | Librarian_official_progress : preflight_only t
  | Turn_fragments : preflight_only t
  | Memory_absorbed : preflight_only t
  | Memory_os_events : preflight_only t

type _ boot_policy =
  | Refuse_boot : refuse_boot boot_policy
  | Degrade_typed : degrade_typed boot_policy
  | Preflight_only : preflight_only boot_policy

let policy : type a. a t -> a boot_policy = function
  | Keeper_meta -> Refuse_boot
  | Memory_current -> Refuse_boot
  | Goal_store -> Degrade_typed
  | Gate_pending -> Preflight_only
  | Official_client_session -> Preflight_only
  | Librarian_range_receipts -> Preflight_only
  | Memory_source_current -> Preflight_only
  | Disposition_receipts -> Preflight_only
  | Board_posts -> Preflight_only
  | Provider_inputs -> Preflight_only
  | Turn_records -> Preflight_only
  | Turn_boundaries -> Preflight_only
  | Librarian_progress -> Preflight_only
  | Librarian_official_progress -> Preflight_only
  | Turn_fragments -> Preflight_only
  | Memory_absorbed -> Preflight_only
  | Memory_os_events -> Preflight_only
;;

(* [\[@@deriving enumerate\]] does not apply to a GADT, so the list is derived
   from this flat twin and the two exhaustive maps below bind them: a
   constructor added to one type fails to compile until the other has it. *)
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

type any = Any : _ t -> any

let id : type a. a t -> Id.t = function
  | Keeper_meta -> Id.Keeper_meta
  | Memory_current -> Id.Memory_current
  | Goal_store -> Id.Goal_store
  | Gate_pending -> Id.Gate_pending
  | Official_client_session -> Id.Official_client_session
  | Librarian_range_receipts -> Id.Librarian_range_receipts
  | Memory_source_current -> Id.Memory_source_current
  | Disposition_receipts -> Id.Disposition_receipts
  | Board_posts -> Id.Board_posts
  | Provider_inputs -> Id.Provider_inputs
  | Turn_records -> Id.Turn_records
  | Turn_boundaries -> Id.Turn_boundaries
  | Librarian_progress -> Id.Librarian_progress
  | Librarian_official_progress -> Id.Librarian_official_progress
  | Turn_fragments -> Id.Turn_fragments
  | Memory_absorbed -> Id.Memory_absorbed
  | Memory_os_events -> Id.Memory_os_events
;;

let of_id : Id.t -> any = function
  | Id.Keeper_meta -> Any Keeper_meta
  | Id.Memory_current -> Any Memory_current
  | Id.Goal_store -> Any Goal_store
  | Id.Gate_pending -> Any Gate_pending
  | Id.Official_client_session -> Any Official_client_session
  | Id.Librarian_range_receipts -> Any Librarian_range_receipts
  | Id.Memory_source_current -> Any Memory_source_current
  | Id.Disposition_receipts -> Any Disposition_receipts
  | Id.Board_posts -> Any Board_posts
  | Id.Provider_inputs -> Any Provider_inputs
  | Id.Turn_records -> Any Turn_records
  | Id.Turn_boundaries -> Any Turn_boundaries
  | Id.Librarian_progress -> Any Librarian_progress
  | Id.Librarian_official_progress -> Any Librarian_official_progress
  | Id.Turn_fragments -> Any Turn_fragments
  | Id.Memory_absorbed -> Any Memory_absorbed
  | Id.Memory_os_events -> Any Memory_os_events
;;

let all = List.map of_id Id.all

type report = Keeper_durable_store_scan.report =
  { rows : int
  ; refused : int
  ; first_refusal : string option
  }

let store_scan : type a. a t -> Keeper_durable_store_scan.store_scan = function
  | Keeper_meta -> Keeper_durable_store_scan.keeper_meta_store
  | Memory_current -> Keeper_durable_store_scan.memory_os_current_store
  | Goal_store -> Keeper_durable_store_scan.goal_store_store
  | Gate_pending -> Keeper_durable_store_scan.gate_pending_store
  | Official_client_session -> Keeper_durable_store_scan.official_client_session_store
  | Librarian_range_receipts -> Keeper_durable_store_scan.librarian_range_receipt_store
  | Memory_source_current -> Keeper_durable_store_scan.memory_source_current_store
  | Disposition_receipts -> Keeper_durable_store_scan.disposition_receipt_store
  | Board_posts -> Keeper_durable_store_scan.board_posts_store
  | Provider_inputs -> Keeper_durable_store_scan.provider_input_store
  | Turn_records -> Keeper_durable_store_scan.turn_record_store
  | Turn_boundaries -> Keeper_durable_store_scan.turn_boundary_store
  | Librarian_progress -> Keeper_durable_store_scan.librarian_progress_store
  | Librarian_official_progress -> Keeper_durable_store_scan.librarian_official_progress_store
  | Turn_fragments -> Keeper_durable_store_scan.turn_fragment_store
  | Memory_absorbed -> Keeper_durable_store_scan.memory_absorbed_store
  | Memory_os_events -> Keeper_durable_store_scan.memory_os_events_store
;;

let name store = (store_scan store).Keeper_durable_store_scan.store
let on_refusal store = (store_scan store).on_refusal
let scan store ~base_path = (store_scan store).scan ~base_path
