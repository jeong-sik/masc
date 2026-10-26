(** Pure requested Apple guest identity and comparison with runtime facts.
    This module grants no start/adopt/delete authority. The lifecycle caller
    must also validate the guest's credential snapshot and shim before adoption. *)

type guest_mount =
  | Tmpfs of { destination : string }
  | Host_dir of { source : string; destination : string; read_only : bool }
  | Named_volume of { name : string; destination : string }

type network =
  | Network_none
  | Network_inherit
  | Network_policy of { name : string }

type t =
  { image : string
  ; guest_size : Keeper_microvm_guest_size.t
  ; user : string
  ; working_directory : string
  ; command : string list
  ; mounts : guest_mount list
  ; isolation : Keeper_microvm_backend.guest_constraint list
  ; network : network
  ; environment : (string * string) list
  ; labels : (string * string) list
  }
(** [environment] and [labels] contain only stable requested values. DNS,
    policy gateway/port, owner PID and start time belong to boot execution,
    not to the plan. Credential mount paths are those of the guest snapshot. *)

val label_key : string

type invalid_plan =
  | Duplicate_environment_key of string
  | Duplicate_label_key of string
  | Duplicate_mount_destination of string
  | Duplicate_constraint of Keeper_microvm_backend.guest_constraint
  | Invalid_environment_key of string
  | Invalid_label_key of string
  | Reserved_plan_label of string
  | Unexpected_lifecycle_label of string
  | Duplicate_lifecycle_label of string
  | Execution_environment_collision of string

val validate : t -> (unit, invalid_plan list) result
(** Pure admission before canonical identity or argv can be used as authority.
    Rejects duplicate keys/destinations/constraints, including collisions with
    constraint-provided scratch mounts. Stable labels cannot contain the plan
    digest, owner PID or start time. Error lists are nonempty. *)

val validate_boot :
  plan:t -> lifecycle_labels:(string * string) list ->
  execution_environment:(string * string) list -> (unit, invalid_plan list) result
(** Also forbids lifecycle metadata overriding stable labels, or execution
    routing variables colliding with stable requested environment keys. *)

val invalid_plan_message : invalid_plan -> string
(** Names the malformed key/constraint/destination, never environment values. *)

val digest : t -> string
(** Canonical SHA-256 for valid plans: mounts, constraints, labels and environment
    do not depend on enumeration order. Command order is significant. *)

val expected_mounts : t -> guest_mount list
(** Includes the scratch tmpfs requested by [Scratch_tmpfs], without asking
    callers to repeat that constraint in [mounts]. *)

type facts =
  { plan_label : string option
  ; image : string
  ; cpus : int
  ; memory_bytes : int64
  ; user : string
  ; working_directory : string
  ; command : string list
  ; mounts : guest_mount list
  ; read_only : bool
  ; cap_drop : string list
  ; cap_add : string list
  ; networks : string list
  ; environment : (string * string) list
  ; labels : (string * string) list
  }

type reading = Facts of facts | Unreadable of string

type difference =
  | Plan_label
  | Image
  | Resources
  | User
  | Working_directory
  | Command
  | Mounts
  | Root_filesystem
  | Capabilities
  | Network
  | Environment
  | Labels
  | Policy_route
  | Identity_snapshot

type refusal =
  | Invalid_requested_plan of invalid_plan list
  | Guest_facts_unreadable of string
  | Runtime_reports_other_than_asked of difference list

type assessment =
  | Matches_plan
  | Replace of difference list
  | Refuse of refusal

type identity_reading = Identity_readable | Identity_unreadable

val differences : t -> facts -> difference list
(** Compares requested facts, allowing image-provided extra environment
    variables and runtime/transient labels. Never logs credential values. *)

val assess :
  plan:t -> policy_environment:(string * string) list ->
  identity_reading:identity_reading -> reading -> assessment
(** An absent/different plan label permits replacement. With the same label,
    unreadable/different runtime facts refuse while preserving the guest.
    A stale policy route permits replacement independently of the stable
    digest. After the label and route checks, an unreadable identity permits
    replacement before same-label runtime differences are considered. Unreadable
    facts always refuse. [Matches_plan] is a comparison result, not lifecycle authority. *)
