(** Pure current-snapshot codec. File and diagnostic context belong to the store. *)

open Keeper_memory_os_types
open Keeper_memory_os_current_types
open Result.Syntax

module Support = Keeper_memory_os_support_core

(* Wire keys of the snapshot document. The encoder writes them and the decoder
   both reads them and names them in a rejection, so a typo would otherwise
   have to be made identically in three places to be caught. *)
let field_revision = "revision"
let field_updated_at = "updated_at"
let field_source = "source"
let field_facts = "facts"
let field_change = "change"
let field_kind = "kind"
let field_trace_id = "trace_id"
let field_added = "added"
let field_removed = "removed"
let field_retained = "retained"
let field_invalidated = "invalidated"
let field_fact = "fact"
let field_missing_premise_ids = "missing_premise_ids"

let source_kind_to_string = function
  | Librarian -> "librarian"
  | Explicit_write -> "explicit_write"
  | Explicit_retract -> "explicit_retract"
;;

let source_kind_of_string = function
  | "librarian" -> Some Librarian
  | "explicit_write" -> Some Explicit_write
  | "explicit_retract" -> Some Explicit_retract
  | _ -> None
;;

let source_to_json source =
  `Assoc
    [ field_kind, `String (source_kind_to_string source.kind)
    ; field_trace_id, `String source.trace_id
    ]
;;

let source_of_json = function
  | `Assoc fields ->
    let* () = exact_field_names_result [ field_kind; field_trace_id ] fields in
    let* kind_token = wire_string_field field_kind fields in
    let* trace_id = wire_string_field field_trace_id fields in
    let* kind =
      match source_kind_of_string kind_token with
      | Some kind -> Ok kind
      | None -> wire_fail [ Wire_field field_kind ] (Unknown_token kind_token)
    in
    let+ () =
      if String.equal (String.trim trace_id) ""
      then wire_fail [ Wire_field field_trace_id ] Blank_string
      else Ok ()
    in
    { kind; trace_id }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

(* Paths are relative to the array itself: this decodes [facts],
   [change.added], and [change.removed], and each caller places the result. *)
let facts_of_json = function
  | `List values ->
    let rec loop index seen acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        let* fact = wire_at (Wire_index index) (fact_of_json value) in
        let identity = memory_id fact in
        if Set_util.StringSet.mem identity seen
        then wire_fail [ Wire_index index ] (Duplicate_entry identity)
        else
          loop (index + 1) (Set_util.StringSet.add identity seen) (fact :: acc) rest
    in
    loop 0 Set_util.StringSet.empty [] values
  | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _ ->
    wire_here Expected_array
;;

let facts_to_json facts =
  `List (List.map fact_to_json facts)
;;

let support_invalidation_to_json invalidation =
  let missing_premise_ids = invalidation.missing_premise_ids in
  if
    missing_premise_ids = []
    || not (List.for_all Keeper_memory_os_types.is_memory_id missing_premise_ids)
    || not
         (List.equal
            String.equal
            missing_premise_ids
            (List.sort_uniq String.compare missing_premise_ids))
  then invalid_arg "support invalidation must carry canonical missing premise identities";
  `Assoc
    [ field_fact, fact_to_json invalidation.fact
    ; ( field_missing_premise_ids
      , `List
          (List.map
             (fun premise_id -> `String premise_id)
             invalidation.missing_premise_ids) )
    ]
;;

let support_invalidation_of_json = function
  | `Assoc fields ->
    let* () =
      exact_field_names_result [ field_fact; field_missing_premise_ids ] fields
    in
    let* fact_json = wire_json_field field_fact fields in
    let* premise_values = wire_list_field field_missing_premise_ids fields in
    let* fact = wire_at (Wire_field field_fact) (fact_of_json fact_json) in
    let rec premise_ids index previous acc = function
      | [] -> Ok (List.rev acc)
      | `String premise_id :: rest ->
        let at reason =
          wire_fail [ Wire_field field_missing_premise_ids; Wire_index index ] reason
        in
        if not (Keeper_memory_os_types.is_memory_id premise_id)
        then at (Not_a_memory_id premise_id)
        else (
          match previous with
          | Some previous when String.compare previous premise_id >= 0 ->
            at Not_ascending
          | Some _ | None ->
            premise_ids (index + 1) (Some premise_id) (premise_id :: acc) rest)
      | _ :: _ ->
        wire_fail
          [ Wire_field field_missing_premise_ids; Wire_index index ]
          Expected_string
    in
    let* missing_premise_ids = premise_ids 0 None [] premise_values in
    (match missing_premise_ids with
     | [] -> wire_fail [ Wire_field field_missing_premise_ids ] Empty_list
     | _ :: _ -> Ok { fact; missing_premise_ids })
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

let change_to_json change =
  `Assoc
    [ field_added, facts_to_json change.added
    ; field_removed, facts_to_json change.removed
    ; field_retained, `Int change.retained
    ; ( field_invalidated
      , `List (List.map support_invalidation_to_json change.invalidated) )
    ]
;;

let change_of_json = function
  | `Assoc fields ->
    let* () =
      exact_field_names_result
        [ field_added; field_removed; field_retained; field_invalidated ]
        fields
    in
    let* added_json = wire_json_field field_added fields in
    let* removed_json = wire_json_field field_removed fields in
    let* retained = wire_int_field field_retained fields in
    let* invalidated_json = wire_list_field field_invalidated fields in
    let* added = wire_at (Wire_field field_added) (facts_of_json added_json) in
    let* removed = wire_at (Wire_field field_removed) (facts_of_json removed_json) in
    let rec invalidations index seen acc = function
      | [] -> Ok (List.rev acc)
      | json :: rest ->
        let* invalidation =
          wire_at_element field_invalidated index (support_invalidation_of_json json)
        in
        let identity = memory_id invalidation.fact in
        if Set_util.StringSet.mem identity seen
        then
          wire_fail
            [ Wire_field field_invalidated; Wire_index index ]
            (Duplicate_entry identity)
        else
          invalidations
            (index + 1)
            (Set_util.StringSet.add identity seen)
            (invalidation :: acc)
            rest
    in
    let* invalidated = invalidations 0 Set_util.StringSet.empty [] invalidated_json in
    let+ () =
      if retained >= 0
      then Ok ()
      else wire_fail [ Wire_field field_retained ] Negative
    in
    { added; removed; retained; invalidated }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

(** A snapshot whose parts each decoded but do not agree with each other.
    Separate from {!Keeper_memory_os_types.wire_error} because nothing here is
    a JSON shape problem: the document is well formed and its own [change] does
    not describe its own [facts]. Closed, so a new consistency rule has to name
    itself before it can refuse a file that is already on disk. *)
type snapshot_inconsistency =
  | Stored_rows_are_unsupported of string list
      (** Rows whose derivation premises are absent from the maintained fixed
          point, so support maintenance would not have kept them. *)
  | Added_row_is_not_current of string
  | Removed_row_is_still_current of string
  | Invalidated_row_is_current of string
  | Invalidated_row_is_observed of string
  | Invalidated_row_is_still_supported of string
  | Invalidated_premises_do_not_match of string
  | Retained_does_not_add_up of
      { retained : int
      ; added : int
      ; facts : int
      }

type snapshot_rejection =
  | Snapshot_undecodable of Keeper_memory_os_types.wire_error
  | Snapshot_inconsistent of snapshot_inconsistency

let snapshot_inconsistency_to_string = function
  | Stored_rows_are_unsupported memory_ids ->
    Printf.sprintf
      "%s: %s no longer has a complete support path"
      field_facts
      (String.concat "," memory_ids)
  | Added_row_is_not_current memory_id ->
    Printf.sprintf
      "%s.%s: %s is not the row %s currently holds"
      field_change
      field_added
      memory_id
      field_facts
  | Removed_row_is_still_current memory_id ->
    Printf.sprintf
      "%s.%s: %s is still the row %s currently holds"
      field_change
      field_removed
      memory_id
      field_facts
  | Invalidated_row_is_current memory_id ->
    Printf.sprintf
      "%s.%s: %s is still in %s"
      field_change
      field_invalidated
      memory_id
      field_facts
  | Invalidated_row_is_observed memory_id ->
    Printf.sprintf
      "%s.%s: %s is observed, so it has no support to lose"
      field_change
      field_invalidated
      memory_id
  | Invalidated_row_is_still_supported memory_id ->
    Printf.sprintf
      "%s.%s: %s still has a complete support path"
      field_change
      field_invalidated
      memory_id
  | Invalidated_premises_do_not_match memory_id ->
    Printf.sprintf
      "%s.%s: %s names premises other than the ones missing from the maintained fixed point"
      field_change
      field_invalidated
      memory_id
  | Retained_does_not_add_up { retained; added; facts } ->
    Printf.sprintf
      "%s.%s: %d retained plus %d added does not equal %d %s"
      field_change
      field_retained
      retained
      added
      facts
      field_facts
;;

let snapshot_rejection_to_string = function
  | Snapshot_undecodable error -> Keeper_memory_os_types.wire_error_to_string error
  | Snapshot_inconsistent inconsistency ->
    snapshot_inconsistency_to_string inconsistency
;;

(* Report the first inconsistent row in added, removed, then invalidated order;
   check the retained count after the row-level checks. *)
let snapshot_change_rejection ~facts ~current_ids ~change =
  let current_by_id =
    List.fold_left
      (fun by_id fact -> Support.Identity_map.add (memory_id fact) fact by_id)
      Support.Identity_map.empty
      facts
  in
  let rec added_rejection = function
    | [] -> None
    | added :: rest ->
      (match Support.Identity_map.find_opt (memory_id added) current_by_id with
       | Some current
         when String.equal (Support.fact_payload added) (Support.fact_payload current) ->
         added_rejection rest
       | Some _ | None -> Some (Added_row_is_not_current (memory_id added)))
  in
  let rec removed_rejection = function
    | [] -> None
    | removed :: rest ->
      (match Support.Identity_map.find_opt (memory_id removed) current_by_id with
       | Some current
         when String.equal (Support.fact_payload removed) (Support.fact_payload current) ->
         Some (Removed_row_is_still_current (memory_id removed))
       | Some _ | None -> removed_rejection rest)
  in
  let rec invalidated_rejection = function
    | [] -> None
    | invalidation :: rest ->
      let identity = memory_id invalidation.fact in
      if Set_util.StringSet.mem identity current_ids
      then Some (Invalidated_row_is_current identity)
      else (
        match invalidation.fact.basis with
        | Observed _ -> Some (Invalidated_row_is_observed identity)
        | Derived derivations ->
          if Support.derivations_supported current_ids derivations
          then Some (Invalidated_row_is_still_supported identity)
          else if
            not
              (List.equal
                 String.equal
                 invalidation.missing_premise_ids
                 (Support.missing_premises_for current_ids derivations))
          then Some (Invalidated_premises_do_not_match identity)
          else invalidated_rejection rest)
  in
  let retained_rejection () =
    let added = List.length change.added in
    let facts = List.length facts in
    if change.retained + added = facts
    then None
    else Some (Retained_does_not_add_up { retained = change.retained; added; facts })
  in
  match added_rejection change.added with
  | Some _ as rejection -> rejection
  | None ->
    (match removed_rejection change.removed with
     | Some _ as rejection -> rejection
     | None ->
       (match invalidated_rejection change.invalidated with
        | Some _ as rejection -> rejection
        | None -> retained_rejection ()))
;;

let to_json snapshot =
  `Assoc
    [ field_revision, `Int snapshot.revision
    ; field_updated_at, `Float snapshot.updated_at
    ; field_source, source_to_json snapshot.source
    ; field_facts, facts_to_json snapshot.facts
    ; field_change, change_to_json snapshot.change
    ]
;;

let snapshot_bytes snapshot =
  Yojson.Safe.pretty_to_string (to_json snapshot) ^ "\n"
;;

let of_json json =
  let wire result = Result.map_error (fun error -> Snapshot_undecodable error) result in
  match json with
  | `Assoc fields ->
    let* () =
      wire
        (exact_field_names_result
           [ field_revision; field_updated_at; field_source; field_facts; field_change ]
           fields)
    in
    let* revision = wire (wire_int_field field_revision fields) in
    let* updated_at = wire (wire_number_field field_updated_at fields) in
    let* source_json = wire (wire_json_field field_source fields) in
    let* facts_json = wire (wire_json_field field_facts fields) in
    let* change_json = wire (wire_json_field field_change fields) in
    let* source =
      wire (wire_at (Wire_field field_source) (source_of_json source_json))
    in
    let* facts = wire (wire_at (Wire_field field_facts) (facts_of_json facts_json)) in
    let* change =
      wire (wire_at (Wire_field field_change) (change_of_json change_json))
    in
    let* () =
      wire
        (if revision >= 1
         then Ok ()
         else wire_fail [ Wire_field field_revision ] Not_positive)
    in
    let* () =
      wire
        (if Float.is_finite updated_at
         then Ok ()
         else wire_fail [ Wire_field field_updated_at ] Not_finite)
    in
    let* () =
      wire
        (if updated_at >= 0.0
         then Ok ()
         else wire_fail [ Wire_field field_updated_at ] Negative)
    in
    (* [facts_of_json] has already refused a repeated identity, so a closure
       smaller than the stored set can only mean a row lost its support. *)
    let current_ids = Support.support_closure_ids facts in
    let* () =
      match
        List.filter
          (fun fact -> not (Set_util.StringSet.mem (memory_id fact) current_ids))
          facts
      with
      | [] -> Ok ()
      | _ :: _ as unsupported ->
        Error
          (Snapshot_inconsistent
             (Stored_rows_are_unsupported (List.map memory_id unsupported)))
    in
    (match snapshot_change_rejection ~facts ~current_ids ~change with
     | Some inconsistency -> Error (Snapshot_inconsistent inconsistency)
     | None -> Ok { revision; updated_at; source; facts; change })
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire (wire_here Expected_object)
;;
