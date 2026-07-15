(** Lane-scoped durable obligations for atomic capability publication.

    The caller opens and owns [registry_root]. This module is the sole owner of
    the fixed capability-relative layout
    [fs-publication-recovery/lanes/<owner>/{active,owned,forensic}]. It never
    reopens an absolute path and never searches target trees for staging
    entries.

    A [Prepared] record is durable before the caller creates a staging
    directory. [bind] then installs a full, self-contained [Bound] record that
    includes the staging inode before removing the exact matching [Prepared]
    record. Recovery policy remains outside this module: callers reacquire the
    persisted allowed-root path, inject already-validated capabilities, inspect
    only the exact derived staging leaf, and select an explicit typed forensic
    outcome. *)

type owner
type operation_id

type identity
type permissions

type locator
type prepared
type bound
type forensic
type registry
type store

type area =
  | Active
  | Owned
  | Forensic

type entry_observation =
  | Absent
  | Present of
      { kind : Eio.File.Stat.kind
      ; identity : identity
      }

type resource_mismatch =
  { expected : identity
  ; observed : entry_observation
  }

type prepared_recovery_outcome =
  | Recovered_unmaterialized
  | Prepared_allowed_root_mismatch of resource_mismatch
  | Prepared_parent_mismatch of resource_mismatch
  | Preserved_unbound_stage of
      { kind : Eio.File.Stat.kind
      ; identity : identity
      }

type bound_recovery_outcome =
  | Bound_stage_absent of
      { observed_target : entry_observation
      }
  | Bound_allowed_root_mismatch of resource_mismatch
  | Bound_parent_mismatch of resource_mismatch
  | Bound_stage_mismatch of
      { mismatch : resource_mismatch
      ; observed_target : entry_observation
      }
  | Preserved_bound_stage of
      { kind : Eio.File.Stat.kind
      ; identity : identity
      ; observed_target : entry_observation
      }

type validation_error =
  | Invalid_owner of string
  | Invalid_operation_id of string
  | Invalid_identity of identity
  | Invalid_allowed_root_path of string
  | Empty_parent_path_identity_mismatch of
      { allowed_root : identity
      ; parent : identity
      }
  | Invalid_parent_component of
      { index : int
      ; value : string
      }
  | Invalid_target_leaf of string
  | Invalid_permissions of int
  | Invalid_record_json of
      { exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Invalid_record_shape
  | Unsupported_record_version of int
  | Record_state_mismatch
  | Record_owner_mismatch of
      { expected : owner
      ; actual : owner
      }
  | Record_operation_id_mismatch of
      { expected : operation_id
      ; actual : operation_id
      }
  | Record_stage_leaf_mismatch of
      { expected : string
      ; actual : string
      }
  | Record_identity_mismatch of
      { expected : identity
      ; actual : identity
      }
  | Record_kind_mismatch of
      { expected : Eio.File.Stat.kind
      ; actual : Eio.File.Stat.kind
      }
  | Record_permissions_mismatch of
      { expected : int
      ; actual : int
      }
  | Record_outcome_observation_not_mismatch of identity
  | Record_field_invalid of
      { field : string
      ; value : Yojson.Safe.t
      }

type subject =
  | Registry_root
  | Recovery_root
  | Lanes_root
  | Lane_root of owner
  | Lane_entry of owner * string
  | Area of area * owner
  | Record of area * owner * operation_id

type operation =
  | Inspect_directory
  | Create_directory
  | Open_directory
  | Close_directory
  | Sync_directory
  | Read_directory
  | Inspect_record
  | Open_record
  | Read_record
  | Decode_record
  | Create_record
  | Apply_permissions
  | Write_record
  | Sync_record
  | Close_record
  | Verify_record_identity
  | Remove_record

type failure_cause =
  | Validation_failed of validation_error
  | Io_failed of
      { exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Write_failed of
      { exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      ; bytes_written : int
      }
  | Unexpected_resource_kind of Eio.File.Stat.kind
  | Resource_identity_changed of
      { expected : identity
      ; actual : identity
      }
  | Posix_descriptor_unavailable
  | Existing_record_does_not_match
  | Created_record_identity_unavailable
  | Missing_record

type failure =
  { operation : operation
  ; subject : subject
  ; cause : failure_cause
  }

type transition_effect =
  | No_record_change
  | Layout_may_be_incomplete
  | Layout_ready
  | Active_record_state_unknown
  | Active_record_durable
  | Active_record_discharged
  | Owned_record_state_unknown_with_active
  | Owned_record_durable_with_active
  | Owned_record_durable
  | Owned_record_discharged
  | Forensic_record_state_unknown_with_source
  | Forensic_record_durable_with_source
  | Forensic_record_durable
  | Source_removal_durability_unknown of removal_transition

and removal_transition =
  | Discharge_active
  | Discharge_owned
  | Active_to_owned
  | Active_to_forensic
  | Owned_to_forensic

type transition_error =
  { store_effect : transition_effect
  ; failure : failure
  ; cleanup_failures : failure list
  }

type callback_and_release_failure =
  { store_effect : transition_effect
  ; callback : Eio.Exn.with_bt
  ; release : failure
  }

(** An unexpected callback exception and the exact resource-release failure
    occurred at the same private scope. Neither cause is relabelled or
    discarded. *)
exception Resource_scope_callback_and_release_failed of
  callback_and_release_failure

(** Raised as the reason inside [Eio.Cancel.Cancelled] whenever cancellation is
    observed after a meaningful store effect, or when cancellation cleanup
    fails. The original reason, effect, and cleanup failures remain available. *)
exception Recovery_store_cancelled of
  exn * transition_effect * failure list

val owner_of_string : string -> (owner, validation_error) result
val owner_to_string : owner -> string
val equal_owner : owner -> owner -> bool

val operation_id_to_string : operation_id -> string
val equal_operation_id : operation_id -> operation_id -> bool

(** Canonical whole registry filename. There is no prefix or suffix. *)
val record_name : operation_id -> string

(** Exact target-parent staging name, total from the operation id. *)
val stage_name : operation_id -> string

val identity : dev:int64 -> ino:int64 -> (identity, validation_error) result
val identity_dev : identity -> int64
val identity_ino : identity -> int64
val equal_identity : identity -> identity -> bool

val permissions_of_int : int -> (permissions, validation_error) result
val permissions_to_int : permissions -> int

(** [locator] persists the caller-certified canonical absolute
    [allowed_root_path] exactly. This constructor proves only non-empty absolute
    syntax; it deliberately neither calls realpath nor normalizes the value. Every
    relative parent component and [target_leaf] is parsed through the shared
    [Capability_leaf] contract. When [parent_components] is empty, [parent]
    must equal [allowed_root]; non-empty traversal remains caller-certified. *)
val locator
  :  allowed_root_path:string
  -> allowed_root:identity
  -> parent_components:string list
  -> parent:identity
  -> target_leaf:string
  -> initial_target:entry_observation
  -> (locator, validation_error) result

val locator_allowed_root_path : locator -> string
val locator_allowed_root : locator -> identity
val locator_parent_components : locator -> string list
val locator_parent : locator -> identity
val locator_target_leaf : locator -> string
val locator_initial_target : locator -> entry_observation

val prepared_owner : prepared -> owner
val prepared_operation_id : prepared -> operation_id
val prepared_locator : prepared -> locator
val prepared_permissions : prepared -> permissions

val bound_prepared : bound -> prepared
val bound_stage_identity : bound -> identity
val bound_stage_name : bound -> string

type forensic_source =
  | Prepared_source of prepared * prepared_recovery_outcome
  | Bound_source of bound * bound_recovery_outcome

val forensic_source : forensic -> forensic_source
val forensic_owner : forensic -> owner
val forensic_operation_id : forensic -> operation_id

(** Idempotently complete and pin the fixed registry prefix. Existing
    components must already be real 0700 directories; symbolic links, other
    kinds, and wrong permissions are rejected without repair. Newly created
    components are fchmodded after umask filtering. Every call repeats both
    directory and parent durability barriers. Retain the returned registry for
    the process lifetime rather than reopening it on the publication hot path.
    Only the final [lanes] capability is retained on [sw]; the intermediate
    recovery-directory capability is short-scoped. *)
val open_registry
  :  sw:Eio.Switch.t
  -> registry_root:Eio.Fs.dir_ty Eio.Path.t
  -> (registry, transition_error) result

type owner_discovery_row =
  | Discovered_owner of owner
  | Invalid_owner_name of string

type owner_inspection =
  | Valid_owner
  | Unexpected_owner_kind of
      Eio.File.Stat.kind
  | Missing_owner_entry
  | Owner_entry_unavailable of transition_error

(** Strict, non-recursive discovery of the names directly below [lanes].
    [Invalid_owner_name] means the entry fails the generic exact
    [Capability_leaf] grammar; MASC must still parse every [Discovered_owner]
    through its stricter [Keeper_name] type. This operation deliberately does
    not inspect an entry's kind, so one slow or faulty entry cannot delay
    discovery of another. Only failure to read [lanes] itself returns [Error].
    Row order is the deterministic lexical order guaranteed by
    [Eio.Path.read_dir]. *)
val discover_owners
  :  registry
  -> (owner_discovery_row list, transition_error) result

(** Inspect exactly one already-discovered owner with a no-follow [Path.kind].
    Disappearance races, unexpected kinds, and expected I/O failures are
    returned as typed evidence for this owner only. Cancellation and truly
    unexpected exceptions propagate with their original backtraces. *)
val inspect_owner
  :  registry
  -> owner
  -> owner_inspection

(** Idempotently complete and pin one owner's fixed three-store layout inside
    a module-owned switch, then call [f]. The intermediate lane capability is
    short-scoped; the active, owned, and forensic capabilities remain pinned
    for exactly the callback lifetime. Normal return, exceptions,
    cancellation, and partial layout failure all close every capability owned
    by that switch. Trusted callers must not return or otherwise retain [store]
    beyond [f]. Layout failures are returned; callback exceptions and
    cancellation propagate unchanged. A Keeper should run its whole lane
    lifetime inside one callback rather than reopening the store per
    publication. *)
val with_store
  :  registry:registry
  -> owner:owner
  -> (store -> 'a)
  -> ('a, transition_error) result

type resource_release_failure =
  { failure : failure
  ; exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

type 'a existing_store_scope_outcome =
  | Existing_store_scope_released of 'a
  | Existing_store_scope_release_failed of
      { value : 'a
      ; release_failure : resource_release_failure
      }
  | Existing_store_scope_cancelled of
      { value : 'a option
      ; reason : exn
      ; backtrace : Printexc.raw_backtrace
      ; release_failure : resource_release_failure option
      }

(** Pin an already-existing owner lane without creating, chmodding, syncing, or
    otherwise repairing any registry entry. The lane and every area component
    are observed without following symbolic links; opened capabilities are
    checked against those exact observations. A lane failure returns [Error].
    Each area failure is retained inside [store] so {!inventory} can report it
    while continuing through the other areas. Startup reconciliation uses this
    entry point so its only possible durable mutation is an explicit
    source-record transition to an available, successfully inventoried
    [forensic] area. *)
val with_existing_store
  :  registry:registry
  -> owner:owner
  -> (store -> 'a)
  -> ('a existing_store_scope_outcome, transition_error) result

val store_owner : store -> owner

(** Generate one operation id at the module-owned entropy boundary and durably
    create its [Prepared] record: exclusive write, file fsync, close, then
    active-directory fsync. A collision with any lane record generates another
    id and retries without a cap; record existence never drives policy. *)
val prepare
  :  store:store
  -> locator:locator
  -> permissions:permissions
  -> (prepared, transition_error) result

(** Install a self-contained [Bound] record durably, then remove and fsync the
    exact matching [Prepared] source. An exact already-installed Bound record
    completes the transition idempotently. *)
val bind
  :  store:store
  -> prepared:prepared
  -> stage_identity:identity
  -> (bound, transition_error) result

(** Remove and fsync the exact matching active obligation after a normal
    failure/cancellation that occurred before [bind]. *)
type discharge_outcome =
  | Discharged
  | Already_discharged

val discharge_prepared
  :  store:store
  -> prepared:prepared
  -> (discharge_outcome, transition_error) result

(** Remove and fsync the exact matching owned obligation after publication and
    its target-parent durability barrier. *)
val discharge_bound
  :  store:store
  -> bound:bound
  -> (discharge_outcome, transition_error) result

(** Preserve an unexpected pre-existing exact staging leaf without reusing or
    deleting it. Kind and inode are both retained. The forensic record is
    durable before the exact active source is removed. *)
val preserve_unbound
  :  store:store
  -> prepared:prepared
  -> kind:Eio.File.Stat.kind
  -> stage_identity:identity
  -> (forensic, transition_error) result

(** Durably record an explicit Prepared recovery result, then remove the exact
    active source. Exact matching forensic completion is idempotent. *)
val record_forensic_prepared
  :  store:store
  -> prepared:prepared
  -> outcome:prepared_recovery_outcome
  -> (forensic, transition_error) result

(** Durably record an explicit Bound recovery result, then remove the exact
    owned source. Outcomes reached after validating the parent retain the
    current no-follow target observation; root/parent mismatch outcomes omit it
    because traversal must stop. Stage absence never claims a known target
    effect or durability. [Preserved_bound_stage] keeps the stage in place and
    retains both its recorded identity (inside [bound]) and current no-follow
    observation. Exact matching forensic completion is idempotent. This module
    deliberately exposes no quarantine rename: OCaml 5.4/Eio rename replaces
    an existing destination and cannot prove never-mutate-unproven semantics. *)
val record_forensic_bound
  :  store:store
  -> bound:bound
  -> outcome:bound_recovery_outcome
  -> (forensic, transition_error) result

type 'a lookup =
  | Missing
  | Found of 'a

val read_prepared
  :  store:store
  -> operation_id
  -> (prepared lookup, transition_error) result

val read_bound
  :  store:store
  -> operation_id
  -> (bound lookup, transition_error) result

val read_forensic
  :  store:store
  -> operation_id
  -> (forensic lookup, transition_error) result

type corrupt_record =
  { area : area
  ; operation_id : operation_id
  ; raw : string
  ; validation_error : validation_error
  }

type inventory_row =
  | Unexpected_lane_entry of
      { name : string
      ; kind : Eio.File.Stat.kind
      }
  | Missing_lane_entry of { name : string }
  | Lane_entry_unavailable of
      { name : string
      ; error : transition_error
      }
  | Area_inventory_unavailable of
      { area : area
      ; error : transition_error
      }
  | Active_record of prepared
  | Owned_record of bound
  | Forensic_record of forensic
  | Invalid_record_name of
      { area : area
      ; name : string
      }
  | Unexpected_record_kind of
      { area : area
      ; operation_id : operation_id
      ; kind : Eio.File.Stat.kind
      }
  | Missing_record_entry of
      { area : area
      ; operation_id : operation_id
      }
  | Record_entry_unavailable of
      { area : area
      ; operation_id : operation_id
      ; error : transition_error
      }
  | Corrupt_record of corrupt_record

type inventory = inventory_row list

(** Strict, non-recursive inventory of the exact owner lane and its three fixed
    stores. Unexpected lane entries, unavailable areas, invalid record names,
    non-regular records, corrupt payloads, disappearance races, and per-entry
    inspection/read failures are preserved as rows. Failure in one area never
    prevents inventory of the others. No entry is created, chmodded, synced,
    removed, or otherwise repaired. Lane-residue rows retain lane lexical
    order, followed by [Active], [Owned], and [Forensic] rows in each area's
    lexical order. *)
val inventory : store -> (inventory, transition_error) result

module For_testing : sig
  val operation_id_of_uuid : Uuidm.t -> operation_id

  val prepare_with_operation_id
    :  store:store
    -> operation_id:operation_id
    -> locator:locator
    -> permissions:permissions
    -> (prepared, transition_error) result

  val area_directory : store -> area -> Eio.Fs.dir_ty Eio.Path.t
end

val validation_error_to_string : validation_error -> string
val failure_to_string : failure -> string
val transition_error_to_string : transition_error -> string
