(** Record model of the publication recovery obligations: the owner, operation
    id, identity, locator, prepared, bound and forensic values, the validation
    errors, and the constructors and accessors that keep those values valid.

    This module is private to [fs_compat_internal] and has no interface file.
    [Capability_recovery_obligation] includes it, and its interface keeps
    [owner], [operation_id], [identity], [permissions], [locator], [prepared],
    [bound] and [forensic] abstract. [Capability_recovery_record_codec] reads and
    writes the same values as JSON. *)

type owner = Capability_leaf.t
type operation_id = Uuidm.t
type permissions = int

type identity =
  { dev : int64
  ; ino : int64
  }

type entry_observation =
  | Absent
  | Present of
      { kind : Eio.File.Stat.kind
      ; identity : identity
      }

type locator =
  { allowed_root_path : string
  ; allowed_root : identity
  ; parent_components : Capability_leaf.t list
  ; parent : identity
  ; target_leaf : Capability_leaf.t
  ; initial_target : entry_observation
  }

type publication = Replace | Create_exclusive

type prepared =
  { owner : owner
  ; operation_id : operation_id
  ; publication : publication
  ; locator : locator
  ; permissions : int
  }

type bound =
  { prepared : prepared
  ; stage_identity : identity
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

type forensic_source =
  | Prepared_source of prepared * prepared_recovery_outcome
  | Bound_source of bound * bound_recovery_outcome

type forensic = { source : forensic_source }

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

exception Record_validation_failed of validation_error

let stage_prefix = ".masc_atomic_stage_"
let stage_suffix = ".dir"

let owner_of_string value =
  match Capability_leaf.of_string value with
  | Some owner -> Ok owner
  | None -> Error (Invalid_owner value)
;;

let owner_to_string = Capability_leaf.to_string
let equal_owner = Capability_leaf.equal

let operation_id_to_string operation_id = Uuidm.to_string operation_id
let equal_operation_id = Uuidm.equal

let operation_id_of_string value =
  match Uuidm.of_string value with
  | Some operation_id
    when String.equal (Uuidm.to_string operation_id) value ->
    Ok operation_id
  | None | Some _ -> Error (Invalid_operation_id value)
;;

let stage_name operation_id =
  Printf.sprintf
    "%s%s%s"
    stage_prefix
    (operation_id_to_string operation_id)
    stage_suffix
;;

let equal_identity (left : identity) (right : identity) =
  Int64.equal left.dev right.dev && Int64.equal left.ino right.ino
;;

let identity_dev (identity : identity) = identity.dev
let identity_ino (identity : identity) = identity.ino

let identity ~dev ~ino =
  let value = { dev; ino } in
  if Int64.compare dev 0L < 0 || Int64.compare ino 0L < 0
  then Error (Invalid_identity value)
  else Ok value
;;

let valid_absolute_path value =
  not (String.equal value "")
  && not (Filename.is_relative value)
  && not (String.contains value '\x00')
;;

(* With no parent components the parent is the allowed root itself. *)
let empty_parent_path_mismatch ~allowed_root ~parent parent_components =
  parent_components = [] && not (equal_identity allowed_root parent)
;;

let locator
      ~allowed_root_path
      ~allowed_root
      ~parent_components
      ~parent
      ~target_leaf
      ~initial_target
  =
  if not (valid_absolute_path allowed_root_path)
  then Error (Invalid_allowed_root_path allowed_root_path)
  else
    let rec parse_components index parsed = function
      | [] -> Ok (List.rev parsed)
      | value :: rest ->
        (match Capability_leaf.of_string value with
         | None -> Error (Invalid_parent_component { index; value })
         | Some component ->
           parse_components (index + 1) (component :: parsed) rest)
    in
    (match parse_components 0 [] parent_components with
     | Error _ as error -> error
     | Ok parent_components ->
       if empty_parent_path_mismatch ~allowed_root ~parent parent_components
       then
         Error
           (Empty_parent_path_identity_mismatch { allowed_root; parent })
       else
         (match Capability_leaf.of_string target_leaf with
          | None -> Error (Invalid_target_leaf target_leaf)
          | Some target_leaf ->
            Ok
              { allowed_root_path
              ; allowed_root
              ; parent_components
              ; parent
              ; target_leaf
              ; initial_target
              }))
;;

(* [locator] for a caller that already holds parsed components. The two
   component errors cannot occur here; the other two can. *)
let locator_of_leaves
      ~allowed_root_path
      ~allowed_root
      ~parent_components
      ~parent
      ~target_leaf
      ~initial_target
  =
  if not (valid_absolute_path allowed_root_path)
  then Error (Invalid_allowed_root_path allowed_root_path)
  else if empty_parent_path_mismatch ~allowed_root ~parent parent_components
  then Error (Empty_parent_path_identity_mismatch { allowed_root; parent })
  else
    Ok
      { allowed_root_path
      ; allowed_root
      ; parent_components
      ; parent
      ; target_leaf
      ; initial_target
      }
;;

let locator_allowed_root_path (locator : locator) = locator.allowed_root_path
let locator_allowed_root (locator : locator) = locator.allowed_root
let locator_parent_components (locator : locator) = locator.parent_components
let locator_parent (locator : locator) = locator.parent
let locator_target_leaf (locator : locator) = locator.target_leaf

let prepared_publication (prepared : prepared) = prepared.publication
let prepared_operation_id (prepared : prepared) = prepared.operation_id
let prepared_locator (prepared : prepared) = prepared.locator
let bound_prepared (bound : bound) = bound.prepared
let bound_stage_identity (bound : bound) = bound.stage_identity
let bound_stage_name (bound : bound) = stage_name bound.prepared.operation_id
let forensic_source (forensic : forensic) = forensic.source

let forensic_owner (forensic : forensic) =
  match forensic.source with
  | Prepared_source (prepared, _) -> prepared.owner
  | Bound_source (bound, _) -> bound.prepared.owner
;;

let forensic_operation_id (forensic : forensic) =
  match forensic.source with
  | Prepared_source (prepared, _) -> prepared.operation_id
  | Bound_source (bound, _) -> bound.prepared.operation_id
;;

let permissions_of_int permissions =
  if permissions < 0 || permissions land lnot 0o7777 <> 0
  then Error (Invalid_permissions permissions)
  else Ok permissions
;;

let permissions_to_int permissions = permissions

let validation_error_to_string = function
  | Invalid_owner value -> Printf.sprintf "invalid owner component %S" value
  | Invalid_operation_id value ->
    Printf.sprintf "invalid canonical operation id %S" value
  | Invalid_identity { dev; ino } ->
    Printf.sprintf "invalid identity dev=%Ld ino=%Ld" dev ino
  | Invalid_allowed_root_path value ->
    Printf.sprintf "invalid absolute allowed-root path %S" value
  | Empty_parent_path_identity_mismatch { allowed_root; parent } ->
    Printf.sprintf
      "empty parent path identity mismatch allowed_root=%Ld:%Ld parent=%Ld:%Ld"
      allowed_root.dev
      allowed_root.ino
      parent.dev
      parent.ino
  | Invalid_parent_component { index; value } ->
    Printf.sprintf "invalid parent component index=%d value=%S" index value
  | Invalid_target_leaf value ->
    Printf.sprintf "invalid target leaf %S" value
  | Invalid_permissions permissions ->
    Printf.sprintf "invalid permissions %#o" permissions
  | Invalid_record_json { exception_; _ } ->
    Printf.sprintf "invalid record JSON: %s" (Printexc.to_string exception_)
  | Invalid_record_shape -> "record has an unexpected field set or shape"
  | Unsupported_record_version version ->
    Printf.sprintf "unsupported record version %d" version
  | Record_state_mismatch -> "record state does not match its store"
  | Record_owner_mismatch { expected; actual } ->
    Printf.sprintf
      "record owner mismatch expected=%S actual=%S"
      (owner_to_string expected)
      (owner_to_string actual)
  | Record_operation_id_mismatch { expected; actual } ->
    Printf.sprintf
      "record operation id mismatch expected=%s actual=%s"
      (operation_id_to_string expected)
      (operation_id_to_string actual)
  | Record_stage_leaf_mismatch { expected; actual } ->
    Printf.sprintf
      "record stage leaf mismatch expected=%S actual=%S"
      expected
      actual
  | Record_identity_mismatch { expected; actual } ->
    Printf.sprintf
      "record identity mismatch expected=%Ld:%Ld actual=%Ld:%Ld"
      expected.dev
      expected.ino
      actual.dev
      actual.ino
  | Record_kind_mismatch { expected; actual } ->
    Format.asprintf
      "record kind mismatch expected=%a actual=%a"
      Eio.File.Stat.pp_kind
      expected
      Eio.File.Stat.pp_kind
      actual
  | Record_permissions_mismatch { expected; actual } ->
    Printf.sprintf
      "record directory permissions mismatch expected=%#o actual=%#o"
      expected
      actual
  | Record_outcome_observation_not_mismatch identity ->
    Printf.sprintf
      "recovery outcome observation still confirms directory identity=%Ld:%Ld"
      identity.dev
      identity.ino
  | Record_field_invalid { field; value } ->
    Printf.sprintf
      "record field %S is invalid: %s"
      field
      (Yojson.Safe.to_string value)
;;
