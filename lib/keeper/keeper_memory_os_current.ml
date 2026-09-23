(** Keeper-owned current Memory OS snapshot. *)

open Keeper_memory_os_types
open Result.Syntax

let suffix = ".memory-current.json"

type source_kind =
  | Librarian
  | Explicit_write
  | Explicit_retract

type source =
  { kind : source_kind
  ; trace_id : string
  }

type support_invalidation =
  { fact : fact
  ; missing_premise_ids : string list
  }

type change =
  { added : fact list
  ; removed : fact list
  ; retained : int
  ; invalidated : support_invalidation list
  }

type upsert_error =
  | Unsupported_derivation of support_invalidation
  | Upsert_persistence_failed of string

type retract_error =
  | Retract_memory_id_invalid
  | Retract_reason_empty
  | Retract_fact_not_found of string
  | Retract_persistence_failed of string

type supersede_error =
  | Supersede_memory_id_invalid
  | Supersede_self
  | Supersede_target_not_current of string
  | Supersede_target_not_authored of string
  | Supersede_successor_rests_on_target of support_invalidation
  | Supersede_unsupported_derivation of support_invalidation
  | Supersede_persistence_failed of string

type retraction =
  { memory_id : string
  ; reason : string
  }

type retract_batch_error =
  | Retract_batch_empty
  | Retract_batch_memory_id_invalid of { index : int }
  | Retract_batch_reason_empty of { index : int }
  | Retract_batch_duplicate_memory_id of string
  | Retract_batch_snapshot_sha256_invalid
  | Retract_batch_snapshot_conflict of
      { expected_revision : int
      ; observed_revision : int option
      ; expected_snapshot_sha256 : string
      ; observed_snapshot_sha256 : string option
      }
  | Retract_batch_fact_not_found of string
  | Retract_batch_plan_evidence_pending of
      { plan_id : string
      ; snapshot_revision : int
      ; snapshot_sha256 : string
      ; detail : string
      }
  | Retract_batch_persistence_failed of string

let upsert_error_to_string = function
  | Unsupported_derivation invalidation ->
    Printf.sprintf
      "derived Memory OS fact has no complete support path memory_id=%s missing_premise_ids=%s"
      (memory_id invalidation.fact)
      (String.concat "," invalidation.missing_premise_ids)
  | Upsert_persistence_failed detail -> detail
;;

type t =
  { revision : int
  ; updated_at : float
  ; source : source
  ; facts : fact list
  ; change : change
  }

type librarian_failure_kind =
  | Prompt_render_failure
  | Execution_clock_unavailable
  | Exact_setup_failure
  | Exact_execution_failure
  | Domain_output_invalid
  | Memory_snapshot_write_failure
  | Runtime_context_unavailable
  | Lane_cancelled
  | Unhandled_exception

type journal_entry =
  | Journal_committed of
      { recorded_at : float
      ; revision : int
      ; source : source
      ; change : change
      ; dropped : Keeper_memory_os_types.dropped_statement list option
      }
  | Journal_failed of
      { recorded_at : float
      ; trace_id : string
      ; kind : librarian_failure_kind
      ; detail : string
      ; snapshot_present : bool
      }
  | Journal_quarantined of
      { recorded_at : float
      ; rejection : string
      ; rejected_path : string
      }

let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ suffix)
;;

let journal_suffix = ".memory-journal.jsonl"

let journal_path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ journal_suffix)
;;

let durable_range_receipt_suffix = ".librarian-range-commit.json"

let durable_range_receipt_path ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ durable_range_receipt_suffix)
;;

let retraction_plan_receipt_suffix = ".memory-retraction-plan.json"

let retraction_plan_receipt_path ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ retraction_plan_receipt_suffix)
;;

type durable_range_id =
  { receipt_scope : string
  ; trace_id : string
  ; history_start_boundary_line : int
  ; start_atom : int
  ; end_atom : int
  ; last_atom_digest : string
  ; end_boundary_line : int
  ; boundary_lines_seen : int
  }

type official_range_id =
  { receipt_scope : string
  ; after_boundary_line : int
  ; turns : (int * Ids.Turn_ref.t) list
  }

type consumed_range =
  | Atom_range of durable_range_id
  | Official_range of official_range_id

type durable_range_receipt =
  | Prepared of
      { range_id : consumed_range
      ; snapshot_revision : int
      ; snapshot_sha256 : string
      }
  | Committed of
      { range_id : consumed_range
      ; snapshot_revision : int
      ; snapshot_sha256 : string
      }

let durable_range_id_to_json (range_id : durable_range_id) =
  `Assoc
    [ "receipt_scope", `String range_id.receipt_scope
    ; "trace_id", `String range_id.trace_id
    ; "history_start_boundary_line", `Int range_id.history_start_boundary_line
    ; "start_atom", `Int range_id.start_atom
    ; "end_atom", `Int range_id.end_atom
    ; "last_atom_digest", `String range_id.last_atom_digest
    ; "end_boundary_line", `Int range_id.end_boundary_line
    ; "boundary_lines_seen", `Int range_id.boundary_lines_seen
    ]
;;

let durable_range_id_of_json = function
  | `Assoc fields ->
    let* () =
      exact_field_names_result
        [ "receipt_scope"
        ; "trace_id"
        ; "history_start_boundary_line"
        ; "start_atom"
        ; "end_atom"
        ; "last_atom_digest"
        ; "end_boundary_line"
        ; "boundary_lines_seen"
        ]
        fields
    in
    let* receipt_scope = wire_string_field "receipt_scope" fields in
    let* trace_id = wire_string_field "trace_id" fields in
    let* history_start_boundary_line =
      wire_int_field "history_start_boundary_line" fields
    in
    let* start_atom = wire_int_field "start_atom" fields in
    let* end_atom = wire_int_field "end_atom" fields in
    let* last_atom_digest = wire_string_field "last_atom_digest" fields in
    let* end_boundary_line = wire_int_field "end_boundary_line" fields in
    let* boundary_lines_seen = wire_int_field "boundary_lines_seen" fields in
    let* () =
      if String.equal (String.trim receipt_scope) ""
      then wire_fail [ Wire_field "receipt_scope" ] Blank_string
      else Ok ()
    in
    let* () =
      if String.equal (String.trim trace_id) ""
      then wire_fail [ Wire_field "trace_id" ] Blank_string
      else Ok ()
    in
    let* () =
      if history_start_boundary_line >= 1
      then Ok ()
      else wire_fail [ Wire_field "history_start_boundary_line" ] Not_positive
    in
    let* () =
      if start_atom >= 0
      then Ok ()
      else wire_fail [ Wire_field "start_atom" ] Negative
    in
    let* () =
      if end_atom > start_atom
      then Ok ()
      else wire_fail [ Wire_field "end_atom" ] Not_positive
    in
    let* () =
      if String_util.is_lowercase_sha256_hex last_atom_digest
      then Ok ()
      else wire_fail [ Wire_field "last_atom_digest" ] (Unknown_token last_atom_digest)
    in
    let* () =
      if end_boundary_line >= history_start_boundary_line
      then Ok ()
      else wire_fail [ Wire_field "end_boundary_line" ] Not_positive
    in
    let+ () =
      if boundary_lines_seen >= end_boundary_line
      then Ok ()
      else wire_fail [ Wire_field "boundary_lines_seen" ] Not_positive
    in
    { receipt_scope
    ; trace_id
    ; history_start_boundary_line
    ; start_atom
    ; end_atom
    ; last_atom_digest
    ; end_boundary_line
    ; boundary_lines_seen
    }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

let official_range_id_to_json (range_id : official_range_id) =
  `Assoc
    [ "receipt_scope", `String range_id.receipt_scope
    ; "after_boundary_line", `Int range_id.after_boundary_line
    ; "turns", `List (List.map (fun (line, turn_ref) ->
        `Assoc [ "line", `Int line; "turn_ref", Ids.Turn_ref.to_yojson turn_ref ]) range_id.turns)
    ]
;;

let official_range_id_of_json = function
  | `Assoc fields ->
    let* () = exact_field_names_result [ "receipt_scope"; "after_boundary_line"; "turns" ] fields in
    let* receipt_scope = wire_string_field "receipt_scope" fields in
    let* after_boundary_line = wire_int_field "after_boundary_line" fields in
    let* turns = wire_list_field "turns" fields in
    let* () =
      if String.equal (String.trim receipt_scope) ""
      then wire_fail [ Wire_field "receipt_scope" ] Blank_string
      else if after_boundary_line < 0
      then wire_fail [ Wire_field "after_boundary_line" ] Negative
      else Ok ()
    in
    let rec parse previous index = function
      | [] -> Ok []
      | json :: rest ->
        let* line, turn_ref =
          wire_at (Wire_field "turns") (wire_at (Wire_index index)
            (match json with
             | `Assoc row ->
               let* () = exact_field_names_result [ "line"; "turn_ref" ] row in
               let* line = wire_int_field "line" row in
               let* text = wire_string_field "turn_ref" row in
               let* turn_ref =
                 match Ids.Turn_ref.of_string text with
                 | Some value -> Ok value
                 | None -> wire_fail [ Wire_field "turn_ref" ] (Unknown_token text)
               in
               if line <= previous
               then wire_fail [ Wire_field "line" ] Not_ascending
               else Ok (line, turn_ref)
             | _ -> wire_here Expected_object))
        in
        let+ rest = parse line (index + 1) rest in
        (line, turn_ref) :: rest
    in
    let* turns =
      match turns with
      | [] -> wire_fail [ Wire_field "turns" ] Empty_list
      | _ :: _ -> parse after_boundary_line 0 turns
    in
    Ok { receipt_scope; after_boundary_line; turns }
  | _ -> wire_here Expected_object
;;

(* schema-compat: atom receipts retain their exact [range_id] wire shape.
   Official receipts name a distinct, mutually exclusive identity field. *)
let consumed_range_field = function
  | Atom_range range -> "range_id", durable_range_id_to_json range
  | Official_range range -> "official_range_id", official_range_id_to_json range
;;

let durable_range_receipt_to_json = function
  | Prepared { range_id; snapshot_revision; snapshot_sha256 } ->
    `Assoc
      [ "state", `String "prepared"
      ; consumed_range_field range_id
      ; "snapshot_revision", `Int snapshot_revision
      ; "snapshot_sha256", `String snapshot_sha256
      ]
  | Committed { range_id; snapshot_revision; snapshot_sha256 } ->
    `Assoc
      [ "state", `String "committed"
      ; consumed_range_field range_id
      ; "snapshot_revision", `Int snapshot_revision
      ; "snapshot_sha256", `String snapshot_sha256
      ]
;;

let durable_range_receipt_of_json = function
  | `Assoc fields ->
    let* range_id =
      let decode key parse wrap =
        let* () = exact_field_names_result
          [ "state"; key; "snapshot_revision"; "snapshot_sha256" ] fields in
        let* json = wire_json_field key fields in
        Result.map wrap (wire_at (Wire_field key) (parse json))
      in
      match List.mem_assoc "range_id" fields, List.mem_assoc "official_range_id" fields with
      | true, false -> decode "range_id" durable_range_id_of_json (fun range -> Atom_range range)
      | false, true -> decode "official_range_id" official_range_id_of_json (fun range -> Official_range range)
      | true, true -> wire_here (Field_set_mismatch
          { missing = []; unexpected = [ "official_range_id" ] })
      | false, false -> wire_here (Field_set_mismatch
          { missing = [ "range_id or official_range_id" ]; unexpected = [] })
    in
    let* state = wire_string_field "state" fields in
    let* snapshot_revision = wire_int_field "snapshot_revision" fields in
    let* () =
      if snapshot_revision >= 1
      then Ok ()
      else wire_fail [ Wire_field "snapshot_revision" ] Not_positive
    in
    let* snapshot_sha256 = wire_string_field "snapshot_sha256" fields in
    let* () =
      if String_util.is_lowercase_sha256_hex snapshot_sha256
      then Ok ()
      else wire_fail [ Wire_field "snapshot_sha256" ] (Unknown_token snapshot_sha256)
    in
    (match state with
     | "prepared" -> Ok (Prepared { range_id; snapshot_revision; snapshot_sha256 })
     | "committed" -> Ok (Committed { range_id; snapshot_revision; snapshot_sha256 })
     | unknown -> wire_fail [ Wire_field "state" ] (Unknown_token unknown))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

let durable_range_receipts_to_json receipts =
  `Assoc [ "receipts", `List (List.map durable_range_receipt_to_json receipts) ]
;;

let durable_range_receipts_of_json = function
  | `Assoc fields ->
    let* () = exact_field_names_result [ "receipts" ] fields in
    let* receipts = wire_list_field "receipts" fields in
    List.fold_right
      (fun json accumulated ->
         let* accumulated = accumulated in
         let+ receipt = durable_range_receipt_of_json json in
         receipt :: accumulated)
      receipts
      (Ok [])
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    wire_here Expected_object
;;

let read_durable_range_receipts ~keepers_dir ~keeper_id =
  let path = durable_range_receipt_path ~keepers_dir ~keeper_id in
  match Fs_compat.load_file_opt path with
  | None -> Ok []
  | Some content ->
    (match Yojson.Safe.from_string content with
     | json ->
       durable_range_receipts_of_json json
       |> Result.map_error (fun error ->
         Printf.sprintf
           "durable Librarian range receipt rejected path=%s: %s"
           path
           (wire_error_to_string error))
     | exception Yojson.Json_error message ->
       Error
         (Printf.sprintf
            "durable Librarian range receipt is not JSON path=%s: %s"
            path
            message))
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Error
      (Printf.sprintf
         "durable Librarian range receipt unreadable path=%s: %s"
         path
         (Printexc.to_string exn))
;;

let validate_durable_range_receipts ~keepers_dir ~keeper_id =
  (* See read_durable_range_receipts: the read is the validation; the receipt value is intentionally discarded. *)
  read_durable_range_receipts ~keepers_dir ~keeper_id |> Result.map ignore
;;

let write_durable_range_receipts ~keepers_dir ~keeper_id receipts =
  let path = durable_range_receipt_path ~keepers_dir ~keeper_id in
  Fs_compat.save_file_atomic_strict path
    (Yojson.Safe.to_string (durable_range_receipts_to_json receipts))
  |> Result.map_error (fun message ->
    Printf.sprintf
      "durable Librarian range receipt write failed path=%s: %s"
      path
      message)
;;

let remove_durable_range_receipts ~keepers_dir ~keeper_id =
  let path = durable_range_receipt_path ~keepers_dir ~keeper_id in
  match Sys.remove path with
  | () -> Ok ()
  | exception Sys_error _ when not (Sys.file_exists path) -> Ok ()
  | exception exn -> (* cancel-guard-ok: Sys.remove performs no Eio operation, so Cancelled cannot originate in this body. *)
    Error
      (Printf.sprintf
         "durable Librarian range receipt removal failed path=%s: %s"
         path
         (Printexc.to_string exn))
;;

let sha256 content = Digestif.SHA256.(digest_string content |> to_hex)

let receipt_range_id = function
  | Prepared { range_id; _ } | Committed { range_id; _ } -> range_id
;;

let range_key = function
  | Atom_range range -> range.receipt_scope, `Atom
  | Official_range range -> range.receipt_scope, `Official
;;

let upsert_durable_range_receipt receipts receipt =
  let key = range_key (receipt_range_id receipt) in
  receipt :: List.filter (fun prior -> range_key (receipt_range_id prior) <> key) receipts
;;

let reconcile_durable_range_receipts
      ~keepers_dir
      ~keeper_id
      ~snapshot
  =
  let* receipts = read_durable_range_receipts ~keepers_dir ~keeper_id in
  let reconciled =
    List.filter_map
      (function
        | Prepared { range_id; snapshot_revision; snapshot_sha256 } ->
          (match snapshot with
           | Some (current, content)
             when Int.equal current.revision snapshot_revision
                  && String.equal (sha256 content) snapshot_sha256 ->
             Some (Committed { range_id; snapshot_revision; snapshot_sha256 })
           | None | Some _ -> None)
        | Committed ({ snapshot_revision; snapshot_sha256; _ } as committed) ->
          (match snapshot with
           | Some (current, _content) when current.revision > snapshot_revision ->
             Some (Committed committed)
           | Some (current, content)
             when Int.equal current.revision snapshot_revision
                  && String.equal (sha256 content) snapshot_sha256 ->
             Some (Committed committed)
           | None | Some _ -> None))
      receipts
  in
  if receipts = reconciled
  then Ok reconciled
  else if reconciled = []
  then
    let+ () = remove_durable_range_receipts ~keepers_dir ~keeper_id in
    []
  else
    let+ () = write_durable_range_receipts ~keepers_dir ~keeper_id reconciled in
    reconciled
;;

let keeper_id_of_filename filename = Filename.chop_suffix_opt ~suffix filename
;;

let list_keeper_ids_for_keepers_dir ~keepers_dir =
  if not (Sys.file_exists keepers_dir && Sys.is_directory keepers_dir)
  then []
  else
    Sys.readdir keepers_dir
    |> Array.to_list
    |> List.filter_map keeper_id_of_filename
    |> List.sort String.compare
;;

let list_durable_range_receipt_keeper_ids ~keepers_dir =
  if not (Sys.file_exists keepers_dir && Sys.is_directory keepers_dir)
  then []
  else
    Sys.readdir keepers_dir
    |> Array.to_list
    |> List.filter_map (Filename.chop_suffix_opt ~suffix:durable_range_receipt_suffix)
    |> List.sort String.compare
;;

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

let exact_object_fields required fields =
  List.length required = List.length fields
  && List.for_all
       (fun required_name ->
          match
            List.filter
              (fun (observed_name, _) ->
                 String.equal required_name observed_name)
              fields
          with
          | [ _ ] -> true
          | [] | _ :: _ :: _ -> false)
       required
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

module Identity_map = Map.Make (String)

let fact_payload fact =
  fact_to_json fact |> Yojson.Safe.to_string
;;

let derivations_supported current_ids derivations =
  List.exists
    (fun derivation ->
       List.for_all
         (fun premise_id -> Set_util.StringSet.mem premise_id current_ids)
         derivation.premise_ids)
    derivations
;;

let missing_premises_for current_ids derivations =
  List.fold_left
    (fun missing derivation ->
       List.fold_left
         (fun missing premise_id ->
            if Set_util.StringSet.mem premise_id current_ids
            then missing
            else Set_util.StringSet.add premise_id missing)
         missing
         derivation.premise_ids)
    Set_util.StringSet.empty
    derivations
  |> Set_util.StringSet.elements
;;

let support_closure_ids facts =
  let rules =
    List.concat_map
      (fun fact ->
         match fact.basis with
         | Observed _ -> []
         | Derived derivations ->
           List.map
             (fun derivation -> memory_id fact, derivation.premise_ids)
             derivations)
      facts
    |> Array.of_list
  in
  let remaining = Array.map (fun (_, premise_ids) -> List.length premise_ids) rules in
  let dependents = Hashtbl.create (Array.length rules) in
  Array.iteri
    (fun rule_index (_, premise_ids) ->
       List.iter
         (fun premise_id ->
            let current = Hashtbl.find_opt dependents premise_id |> Option.value ~default:[] in
            Hashtbl.replace dependents premise_id (rule_index :: current))
         premise_ids)
    rules;
  let current = ref Set_util.StringSet.empty in
  let pending = Queue.create () in
  let activate identity =
    if not (Set_util.StringSet.mem identity !current)
    then (
      current := Set_util.StringSet.add identity !current;
      Queue.add identity pending)
  in
  List.iter
    (fun fact ->
       match fact.basis with
       | Observed _ -> activate (memory_id fact)
       | Derived _ -> ())
    facts;
  while not (Queue.is_empty pending) do
    let identity = Queue.take pending in
    Hashtbl.find_opt dependents identity
    |> Option.value ~default:[]
    |> List.iter (fun rule_index ->
      remaining.(rule_index) <- remaining.(rule_index) - 1;
      if remaining.(rule_index) = 0
      then activate (fst rules.(rule_index)))
  done;
  !current
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

(* Each of the four consistency rules names the row it refused. Answering one
   bool for the whole snapshot meant a refused file on disk could only be read
   by re-deriving this function by hand. *)
let snapshot_change_rejection ~facts ~current_ids ~change =
  let current_by_id =
    List.fold_left
      (fun by_id fact -> Identity_map.add (memory_id fact) fact by_id)
      Identity_map.empty
      facts
  in
  let rec added_rejection = function
    | [] -> None
    | added :: rest ->
      (match Identity_map.find_opt (memory_id added) current_by_id with
       | Some current when String.equal (fact_payload added) (fact_payload current) ->
         added_rejection rest
       | Some _ | None -> Some (Added_row_is_not_current (memory_id added)))
  in
  let rec removed_rejection = function
    | [] -> None
    | removed :: rest ->
      (match Identity_map.find_opt (memory_id removed) current_by_id with
       | Some current when String.equal (fact_payload removed) (fact_payload current)
         -> Some (Removed_row_is_still_current (memory_id removed))
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
          if derivations_supported current_ids derivations
          then Some (Invalidated_row_is_still_supported identity)
          else if
            not
              (List.equal
                 String.equal
                 invalidation.missing_premise_ids
                 (missing_premises_for current_ids derivations))
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

let snapshot_sha256 snapshot = sha256 (snapshot_bytes snapshot)

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
    let current_ids = support_closure_ids facts in
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

let parse path content =
  try
    Result.map_error
      (fun rejection ->
         Printf.sprintf
           "%s: current Memory OS snapshot rejected: %s"
           path
           (snapshot_rejection_to_string rejection))
      (of_json (Yojson.Safe.from_string content))
  with
  | Yojson.Json_error message ->
    Error (Printf.sprintf "%s: invalid JSON: %s" path message)
;;

let read_with_content ~keepers_dir ~keeper_id =
  let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  try
    match Fs_compat.load_file_opt snapshot_path with
    | None -> Ok None
    | Some content ->
      let+ snapshot = parse snapshot_path content in
      Some (snapshot, content)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error message ->
    Error
      (Printf.sprintf
         "current Memory OS read failed path=%s: %s"
         snapshot_path
         message)
;;

let read_for_keepers_dir ~keepers_dir ~keeper_id =
  read_with_content ~keepers_dir ~keeper_id
  |> Result.map (Option.map fst)
;;

let read_with_snapshot_sha256 ~keepers_dir ~keeper_id =
  read_with_content ~keepers_dir ~keeper_id
  |> Result.map
       (Option.map (fun (snapshot, content) -> snapshot, sha256 content))
;;

let map_facts facts =
  let rec loop map = function
    | [] -> Ok map
    | fact :: rest ->
      let identity = memory_id fact in
      if Identity_map.mem identity map
      then Error (Printf.sprintf "duplicate Memory OS fact identity: %s" identity)
      else loop (Identity_map.add identity fact map) rest
  in
  loop Identity_map.empty facts
;;

let compute_change ~previous ~next ~invalidated =
  let* previous_by_id = map_facts previous in
  let* next_by_id = map_facts next in
  let added_rev, retained =
    List.fold_left
      (fun (added_rev, retained) next_fact ->
         let identity = memory_id next_fact in
         match Identity_map.find_opt identity previous_by_id with
         | Some previous_fact
           when String.equal (fact_payload previous_fact) (fact_payload next_fact) ->
           added_rev, retained + 1
         | Some _ | None -> next_fact :: added_rev, retained)
      ([], 0)
      next
  in
  let removed_rev =
    List.fold_left
      (fun removed_rev previous_fact ->
         let identity = memory_id previous_fact in
         match Identity_map.find_opt identity next_by_id with
         | Some next_fact
           when String.equal (fact_payload previous_fact) (fact_payload next_fact) ->
           removed_rev
         | Some _ | None -> previous_fact :: removed_rev)
      []
      previous
  in
  Ok
    { added = List.rev added_rev
    ; removed = List.rev removed_rev
    ; retained
    ; invalidated
    }
;;

(* Truth maintenance over positive support sets. Observations seed a worklist;
   each newly supported identity advances only the derivations that name it.
   A derived fact activates when one whole derivation reaches zero missing
   premises. Unsupported cycles never enter the worklist. *)
let maintain_supported_facts facts =
  let current_ids = support_closure_ids facts in
  let current_rev, invalidated_rev =
    List.fold_left
      (fun (current_rev, invalidated_rev) fact ->
         if Set_util.StringSet.mem (memory_id fact) current_ids
         then fact :: current_rev, invalidated_rev
         else
           match fact.basis with
           | Observed _ -> fact :: current_rev, invalidated_rev
           | Derived derivations ->
             let missing_premise_ids =
               missing_premises_for current_ids derivations
             in
             current_rev, { fact; missing_premise_ids } :: invalidated_rev)
      ([], [])
      facts
  in
  List.rev current_rev, List.rev invalidated_rev
;;

(* The same claim bytes seen again: an observation outranks a derivation, and
   a Board reference outranks the transcript because it names a source the
   transcript cannot. Two Board references keep the first unless the second
   names a comment under the same post the first only named as a post; the
   second reading otherwise adds nothing the first did not. *)
let merge_observation existing incoming =
  match existing, incoming with
  | Board { post_id; comment_id = None }, Board { post_id = incoming_post; comment_id = Some _ }
    when Board_types.Post_id.to_string post_id
         = Board_types.Post_id.to_string incoming_post ->
    incoming
  | Board _, (Board _ | Transcript) -> existing
  | Transcript, Board _ -> incoming
  | Transcript, Transcript -> Transcript
;;

let merge_basis existing incoming =
  match existing, incoming with
  | Observed existing, Observed incoming ->
    Observed (merge_observation existing incoming)
  | Observed existing, Derived _ -> Observed existing
  | Derived _, Observed incoming -> Observed incoming
  | Derived existing, Derived incoming ->
    let derivations =
      List.fold_left
        (fun derivations candidate ->
           if
             List.exists
               (fun current -> String.equal current.rule_id candidate.rule_id)
               derivations
           then
             List.map
               (fun current ->
                  if String.equal current.rule_id candidate.rule_id
                  then candidate
                  else current)
               derivations
           else derivations @ [ candidate ])
        existing
        incoming
    in
    Derived derivations
;;

let librarian_failure_kind_to_string = function
  | Prompt_render_failure -> "prompt_render_failure"
  | Execution_clock_unavailable -> "execution_clock_unavailable"
  | Exact_setup_failure -> "exact_setup_failure"
  | Exact_execution_failure -> "exact_execution_failure"
  | Domain_output_invalid -> "domain_output_invalid"
  | Memory_snapshot_write_failure -> "memory_snapshot_write_failure"
  | Runtime_context_unavailable -> "runtime_context_unavailable"
  | Lane_cancelled -> "lane_cancelled"
  | Unhandled_exception -> "unhandled_exception"
;;

let librarian_failure_kind_of_string = function
  | "prompt_render_failure" -> Some Prompt_render_failure
  | "execution_clock_unavailable" -> Some Execution_clock_unavailable
  | "exact_setup_failure" -> Some Exact_setup_failure
  | "exact_execution_failure" -> Some Exact_execution_failure
  | "domain_output_invalid" -> Some Domain_output_invalid
  | "memory_snapshot_write_failure" -> Some Memory_snapshot_write_failure
  | "runtime_context_unavailable" -> Some Runtime_context_unavailable
  | "lane_cancelled" -> Some Lane_cancelled
  | "unhandled_exception" -> Some Unhandled_exception
  | _ -> None
;;

let committed_outcome = "committed"
let failed_outcome = "failed"
let quarantined_outcome = "quarantined"

(* [dropped_statements = None] means the writer makes no drop-reason
   statements (explicit keeper writes, upserts); [Some list] is the
   librarian's own account of every drop in this commit, possibly empty.
   Statements live only on the journal line: the snapshot codec stays
   frozen, so existing on-disk snapshots keep parsing unchanged. *)
let journal_entry_to_json ~dropped_statements snapshot =
  `Assoc
    ([ "outcome", `String committed_outcome
     ; "recorded_at", `Float snapshot.updated_at
     ; "revision", `Int snapshot.revision
     ; "source", source_to_json snapshot.source
     ; "change", change_to_json snapshot.change
     ]
     @
     match dropped_statements with
     | None -> []
     | Some statements ->
       [ ( "dropped"
         , `List (List.map dropped_statement_to_json statements) )
       ])
;;

let journal_failure_to_json ~now ~trace_id ~kind ~detail ~snapshot_present =
  `Assoc
    [ "outcome", `String failed_outcome
    ; "recorded_at", `Float now
    ; "trace_id", `String trace_id
    ; "kind", `String (librarian_failure_kind_to_string kind)
    ; "detail", `String detail
    ; "snapshot_present", `Bool snapshot_present
    ]
;;

(* Ordinary producers retain the historical observation-only behavior: their
   snapshot already reached disk, so append failure warns. The destructive
   batch boundary below uses [append_journal_line_strict] plus a prepared plan
   receipt instead; its exact reasons are part of that API's success contract.
   Cancellation is never absorbed. *)
let append_journal_line ~keepers_dir ~keeper_id json =
  let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  try Fs_compat.append_jsonl path json with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | exn ->
    Log.Keeper.warn
      "memory journal append failed path=%s: %s"
      path
      (Printexc.to_string exn)
;;

let append_journal_entry ~keepers_dir ~keeper_id ~dropped_statements snapshot =
  append_journal_line
    ~keepers_dir
    ~keeper_id
    (journal_entry_to_json ~dropped_statements snapshot)
;;

let append_librarian_failure
      ~keepers_dir
      ~keeper_id
      ~now
      ~trace_id
      ~kind
      ~detail
      ~snapshot_present
  =
  append_journal_line
    ~keepers_dir
    ~keeper_id
    (journal_failure_to_json ~now ~trace_id ~kind ~detail ~snapshot_present)
;;

(* A snapshot this build cannot decode is durable state no producer can leave:
   every writer reads before it writes, so one undecodable file wedges the
   keeper's memory permanently. The bytes move aside rather than being deleted
   and this line says why, so a build that can read them again still has both.
   Recorded on its own outcome because it is neither a pass that committed nor
   a pass that failed. *)
let journal_quarantine_to_json ~now ~rejection ~rejected_path =
  `Assoc
    [ "outcome", `String quarantined_outcome
    ; "recorded_at", `Float now
    ; "rejection", `String rejection
    ; "rejected_path", `String rejected_path
    ]
;;

(* [now] is the caller's own observation time and repeats: two writes in the
   same second share it, and a caller may pass a fixed value. [rename] replaces
   its destination, so a repeated name would delete the snapshot an earlier
   quarantine kept — the one thing this path promises not to do. The search
   runs under the snapshot lock the writer already holds, so the name it
   settles on is still free when the rename happens. *)
let unused_rejected_path ~snapshot_path ~now =
  let base = Printf.sprintf "%s.rejected-%.0f" snapshot_path now in
  if not (Fs_compat.file_exists base)
  then base
  else (
    let rec next attempt =
      let candidate = Printf.sprintf "%s-%d" base attempt in
      if Fs_compat.file_exists candidate then next (attempt + 1) else candidate
    in
    next 2)
;;

let append_snapshot_quarantine ~keepers_dir ~keeper_id ~now ~rejection ~rejected_path =
  append_journal_line
    ~keepers_dir
    ~keeper_id
    (journal_quarantine_to_json ~now ~rejection ~rejected_path)
;;

let committed_entry_of_fields fields =
  let fields_are_exact =
    exact_object_fields
      [ "outcome"; "recorded_at"; "revision"; "source"; "change" ]
      fields
    || exact_object_fields
         [ "outcome"
         ; "recorded_at"
         ; "revision"
         ; "source"
         ; "change"
         ; "dropped"
         ]
         fields
  in
  let dropped_of_json = function
    | `List items ->
      let rec loop index acc = function
        | [] -> Ok (List.rev acc)
        | item :: rest ->
          (match Keeper_memory_os_types.dropped_statement_of_json item with
           | Ok statement -> loop (index + 1) (statement :: acc) rest
           | Error error ->
             Error
               (Printf.sprintf
                  "[%d] %s"
                  index
                  (Keeper_memory_os_types.wire_error_to_string error)))
      in
      loop 0 [] items
    | _ -> Error "is not an array"
  in
  if not fields_are_exact
  then Error "committed line has unknown, duplicate, or missing fields"
  else
  match
    ( List.assoc_opt "recorded_at" fields
    , List.assoc_opt "revision" fields
    , List.assoc_opt "source" fields
    , List.assoc_opt "change" fields )
  with
  | Some (`Float recorded_at), Some (`Int revision), Some source, Some change ->
    (match source_of_json source, change_of_json change with
     | Error error, _ ->
       Error
         (Printf.sprintf
            "committed line has an undecodable source: %s"
            (Keeper_memory_os_types.wire_error_to_string error))
     | Ok _, Error error ->
       Error
         (Printf.sprintf
            "committed line has an undecodable change: %s"
            (Keeper_memory_os_types.wire_error_to_string error))
     | Ok _, Ok _ when revision < 0 -> Error "committed line has a negative revision"
     | Ok source, Ok change ->
       (match List.assoc_opt "dropped" fields with
        | None ->
          Ok (Journal_committed { recorded_at; revision; source; change; dropped = None })
        | Some dropped ->
          (match dropped_of_json dropped with
           | Ok statements ->
             Ok
               (Journal_committed
                  { recorded_at; revision; source; change; dropped = Some statements })
           | Error detail ->
             Error
               (Printf.sprintf
                  "committed line has an undecodable dropped list: %s"
                  detail))))
  | _ -> Error "committed line is missing recorded_at/revision/source/change"
;;

let failed_entry_of_fields fields =
  if
    not
      (exact_object_fields
         [ "outcome"
         ; "recorded_at"
         ; "trace_id"
         ; "kind"
         ; "detail"
         ; "snapshot_present"
         ]
         fields)
  then Error "failed line has unknown, duplicate, or missing fields"
  else
  match
    ( List.assoc_opt "recorded_at" fields
    , List.assoc_opt "trace_id" fields
    , List.assoc_opt "kind" fields
    , List.assoc_opt "detail" fields
    , List.assoc_opt "snapshot_present" fields )
  with
  | ( Some (`Float recorded_at)
    , Some (`String trace_id)
    , Some (`String kind)
    , Some (`String detail)
    , Some (`Bool snapshot_present) ) ->
    (match librarian_failure_kind_of_string kind with
     | Some kind ->
       Ok (Journal_failed { recorded_at; trace_id; kind; detail; snapshot_present })
     | None -> Error (Printf.sprintf "failed line has an unknown kind %S" kind))
  | _ ->
    Error "failed line is missing recorded_at/trace_id/kind/detail/snapshot_present"
;;

let quarantined_entry_of_fields fields =
  if
    not
      (exact_object_fields
         [ "outcome"; "recorded_at"; "rejection"; "rejected_path" ]
         fields)
  then Error "quarantined line has unknown, duplicate, or missing fields"
  else
    match
      ( List.assoc_opt "recorded_at" fields
      , List.assoc_opt "rejection" fields
      , List.assoc_opt "rejected_path" fields )
    with
    | ( Some (`Float recorded_at)
      , Some (`String rejection)
      , Some (`String rejected_path) ) ->
      Ok (Journal_quarantined { recorded_at; rejection; rejected_path })
    | _ ->
      Error "quarantined line is missing recorded_at/rejection/rejected_path"
;;

let journal_entry_of_json = function
  | `Assoc fields ->
    (match List.assoc_opt "outcome" fields with
     | Some (`String outcome) when String.equal outcome committed_outcome ->
       committed_entry_of_fields fields
     | Some (`String outcome) when String.equal outcome failed_outcome ->
       failed_entry_of_fields fields
     | Some (`String outcome) when String.equal outcome quarantined_outcome ->
       quarantined_entry_of_fields fields
     | Some (`String outcome) ->
       Error (Printf.sprintf "journal line has an unknown outcome %S" outcome)
     | Some _ -> Error "journal line has a non-string outcome"
     | None -> Error "journal line has no outcome tag")
  | _ -> Error "journal line is not a JSON object"
;;

type retraction_plan_receipt =
  { plan_id : string
  ; prior_revision : int
  ; prior_snapshot_sha256 : string
  ; target_revision : int
  ; target_snapshot_sha256 : string
  ; dropped_statements : Keeper_memory_os_types.dropped_statement list
  }

let retraction_plan_receipt_to_json receipt =
  `Assoc
    [ "state", `String "prepared"
    ; "plan_id", `String receipt.plan_id
    ; "prior_revision", `Int receipt.prior_revision
    ; "prior_snapshot_sha256", `String receipt.prior_snapshot_sha256
    ; "target_revision", `Int receipt.target_revision
    ; "target_snapshot_sha256", `String receipt.target_snapshot_sha256
    ; ( "dropped"
      , `List
          (List.map
             dropped_statement_to_json
             receipt.dropped_statements) )
    ]
;;

let retraction_plan_receipt_of_json = function
  | `Assoc fields
    when exact_object_fields
           [ "plan_id"
           ; "state"
           ; "prior_revision"
           ; "prior_snapshot_sha256"
           ; "target_revision"
           ; "target_snapshot_sha256"
           ; "dropped"
           ]
           fields ->
    (match
       ( List.assoc_opt "plan_id" fields
       , List.assoc_opt "state" fields
       , List.assoc_opt "prior_revision" fields
       , List.assoc_opt "prior_snapshot_sha256" fields
       , List.assoc_opt "target_revision" fields
       , List.assoc_opt "target_snapshot_sha256" fields
       , List.assoc_opt "dropped" fields )
     with
     | ( Some (`String plan_id)
       , Some (`String "prepared")
       , Some (`Int prior_revision)
       , Some (`String prior_snapshot_sha256)
       , Some (`Int target_revision)
       , Some (`String target_snapshot_sha256)
       , Some (`List dropped_json) )
       when String.trim plan_id <> ""
            && String.equal plan_id (String.trim plan_id)
            && prior_revision > 0
            && target_revision = prior_revision + 1
            && String_util.is_lowercase_sha256_hex prior_snapshot_sha256
            && String_util.is_lowercase_sha256_hex target_snapshot_sha256 ->
       let rec decode_dropped index seen acc = function
         | [] -> Ok (List.rev acc)
         | json :: rest ->
           (match Keeper_memory_os_types.dropped_statement_of_json json with
            | Ok statement
              when not
                     (Set_util.StringSet.mem statement.memory_id seen) ->
              decode_dropped
                (index + 1)
                (Set_util.StringSet.add statement.memory_id seen)
                (statement :: acc)
                rest
            | Ok statement ->
              Error
                (Printf.sprintf
                   "retraction plan dropped repeats memory_id %s"
                   statement.memory_id)
            | Error error ->
              Error
                (Printf.sprintf
                   "retraction plan dropped[%d] is invalid: %s"
                   index
                   (Keeper_memory_os_types.wire_error_to_string error)))
       in
       (match decode_dropped 0 Set_util.StringSet.empty [] dropped_json with
        | Ok (_ :: _ as dropped_statements) ->
          Ok
            { plan_id
            ; prior_revision
            ; prior_snapshot_sha256
            ; target_revision
            ; target_snapshot_sha256
            ; dropped_statements
            }
        | Ok [] -> Error "retraction plan dropped reasons are empty"
        | Error _ as error -> error)
     | _ -> Error "retraction plan receipt fields are invalid")
  | _ ->
    Error "retraction plan receipt has unknown, duplicate, or missing fields"
;;

let read_retraction_plan_receipt ~keepers_dir ~keeper_id =
  let path = retraction_plan_receipt_path ~keepers_dir ~keeper_id in
  match Fs_compat.load_file_opt path with
  | None -> Ok None
  | Some content ->
    (match Yojson.Safe.from_string content with
     | json -> Result.map Option.some (retraction_plan_receipt_of_json json)
     | exception Yojson.Json_error detail ->
       Error
         (Printf.sprintf
            "retraction plan receipt is not JSON path=%s: %s"
            path
            detail))
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Error
      (Printf.sprintf
         "retraction plan receipt unreadable path=%s: %s"
         path
         (Printexc.to_string exn))
;;

let write_retraction_plan_receipt ~keepers_dir ~keeper_id receipt =
  let path = retraction_plan_receipt_path ~keepers_dir ~keeper_id in
  Fs_compat.save_file_atomic_strict path
    (Yojson.Safe.to_string (retraction_plan_receipt_to_json receipt))
  |> Result.map_error (fun detail ->
       Printf.sprintf
         "retraction plan receipt write failed path=%s: %s"
         path
         detail)
;;

let remove_retraction_plan_receipt ~keepers_dir ~keeper_id =
  let path = retraction_plan_receipt_path ~keepers_dir ~keeper_id in
  match Sys.remove path with
  | () -> Ok ()
  | exception Sys_error _ when not (Sys.file_exists path) -> Ok ()
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Error
      (Printf.sprintf
         "retraction plan receipt removal failed path=%s: %s"
         path
         (Printexc.to_string exn))
;;

let append_journal_line_strict ~keepers_dir ~keeper_id json =
  let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  let suffix = Yojson.Safe.to_string json ^ "\n" in
  match Fs_compat.append_private_jsonl_durable_locked_result path suffix with
  | Fs_compat.Private_file_succeeded () -> Ok ()
  | Fs_compat.Private_file_succeeded_with_cleanup_failure
      { cleanup_failure; _ } ->
    Error
      (Printf.sprintf
         "memory journal append committed but descriptor cleanup failed path=%s: %s"
         path
         (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
  | Fs_compat.Private_file_failed error ->
    Error
      (Printf.sprintf
         "memory journal durable append failed path=%s: %s"
         path
         (Fs_compat.private_jsonl_append_error_to_string error))
  | Fs_compat.Private_file_failed_with_cleanup_failure
      { error; cleanup_failure } ->
    Error
      (Printf.sprintf
         "memory journal durable append failed path=%s: %s; descriptor cleanup also failed: %s"
         path
         (Fs_compat.private_jsonl_append_error_to_string error)
         (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
;;

let journal_contains_entry ~keepers_dir ~keeper_id expected =
  let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  match Fs_compat.read_private_jsonl_durable_locked_result path ~after:None with
  | Ok snapshot ->
    let content = snapshot.Fs_compat.bytes in
    let rec scan line_number = function
      | [] -> Ok false
      | line :: rest when String.equal (String.trim line) "" ->
        scan (line_number + 1) rest
      | line :: rest ->
        (match Yojson.Safe.from_string line with
         | json ->
           (match journal_entry_of_json json with
            | Ok observed when observed = expected -> Ok true
            | Ok _ -> scan (line_number + 1) rest
            | Error detail ->
              Error
                (Printf.sprintf
                   "memory journal line %d is undecodable during retraction reconciliation path=%s: %s"
                   line_number
                   path
                   detail))
         | exception Yojson.Json_error detail ->
           Error
             (Printf.sprintf
                "memory journal line %d is not JSON during retraction reconciliation path=%s: %s"
                line_number
                path
                detail))
    in
    scan 1 (String.split_on_char '\n' content)
  | Error error ->
    Error
      (Printf.sprintf
         "memory journal unreadable during retraction reconciliation path=%s: %s"
         path
         (Fs_compat.private_jsonl_transaction_error_to_string error))
;;

let reconcile_retraction_plan_receipt ~keepers_dir ~keeper_id ~snapshot =
  let* receipt = read_retraction_plan_receipt ~keepers_dir ~keeper_id in
  match receipt with
  | None -> Ok ()
  | Some receipt ->
    (match snapshot with
     | Some (current, content)
       when current.revision = receipt.prior_revision
            && String.equal (sha256 content) receipt.prior_snapshot_sha256 ->
      (* Preparation reached disk but replacement did not. Nothing was
         retracted, so the plan can be removed without journal evidence. *)
      remove_retraction_plan_receipt ~keepers_dir ~keeper_id
     | Some (current, content)
       when current.revision = receipt.target_revision
            && String.equal (sha256 content) receipt.target_snapshot_sha256 ->
      let* () =
        match current.source with
        | { kind = Explicit_retract; trace_id }
          when String.equal trace_id receipt.plan_id -> Ok ()
        | _ ->
          Error
            (Printf.sprintf
               "retraction plan target snapshot has another source plan_id=%s"
               receipt.plan_id)
      in
      let journal_entry =
        Journal_committed
          { recorded_at = current.updated_at
          ; revision = current.revision
          ; source = current.source
          ; change = current.change
          ; dropped = Some receipt.dropped_statements
          }
      in
      let* present =
        journal_contains_entry
          ~keepers_dir
          ~keeper_id
          journal_entry
      in
      let* () =
        if present
        then Ok ()
        else
          append_journal_line_strict
            ~keepers_dir
            ~keeper_id
            (journal_entry_to_json
               ~dropped_statements:(Some receipt.dropped_statements)
               current)
      in
      remove_retraction_plan_receipt ~keepers_dir ~keeper_id
     | None | Some _ ->
      Error
        (Printf.sprintf
           "retraction plan receipt conflicts with current snapshot plan_id=%s prior_revision=%d target_revision=%d"
           receipt.plan_id
           receipt.prior_revision
           receipt.target_revision))
;;

(* The journal only grows (10-13 MB on live keepers) and a reader asks for its
   last 20-500 lines. Reading the whole file and splitting every line on each
   dashboard or TUI request put that copy and split on the scheduler domain;
   the tail is read backwards and only the returned lines are parsed, both in
   one pool job. Each line is named by the byte offset it starts at, which
   does not depend on the window it was read in. *)
let read_journal_tail_indexed ~keepers_dir ~keeper_id ~limit =
  if limit <= 0
  then []
  else (
    let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
    Dated_jsonl.map_tail_rows path ~max_lines:limit ~f:(fun { Dated_jsonl.offset; line } ->
      match Yojson.Safe.from_string line with
      | json -> offset, journal_entry_of_json json
      | exception Yojson.Json_error message ->
        offset, Error (Printf.sprintf "journal line is not valid JSON: %s" message)))
;;

let read_journal_tail ~keepers_dir ~keeper_id ~limit =
  read_journal_tail_indexed ~keepers_dir ~keeper_id ~limit |> List.map snd
;;

let update_locked_with_error
      ?on_committed
      ?clock
      ?dropped_statements
      ?before_replace
      ?durable_range_id
      ?official_range_id
      ?retraction_plan
      ~store_error
      ~keepers_dir
      ~keeper_id
      ~now
      build
  =
  let* () =
    match official_range_id with
    | None -> Ok ()
    | Some range ->
      official_range_id_of_json (official_range_id_to_json range)
      |> Result.map (fun _ -> ())
      |> Result.map_error (fun error -> store_error (wire_error_to_string error))
  in
  let dropped_statements_are_valid =
    match dropped_statements with
    | None -> true
    | Some statements ->
      List.for_all
        (fun (statement : Keeper_memory_os_types.dropped_statement) ->
           Keeper_memory_os_types.is_memory_id statement.memory_id
           && not (String.equal (String.trim statement.reason) ""))
        statements
  in
  let retraction_plan_is_valid =
    match retraction_plan with
    | None -> true
    | Some (plan_id, _) ->
      String.trim plan_id <> "" && String.equal plan_id (String.trim plan_id)
  in
  if not dropped_statements_are_valid
  then Error (store_error "dropped statements must carry canonical identities and reasons")
  else if not retraction_plan_is_valid
  then Error (store_error "retraction plan id must be non-empty and already trimmed")
  else (
    Fs_compat.mkdir_p keepers_dir;
    let notification_keepers_dir = Unix.realpath keepers_dir in
    let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
    let committed = ref None in
    let notify () =
      Option.iter Keeper_memory_commit_notifications.notify_committed !committed
    in
    let write () = Keeper_memory_os_aggregate_lock.with_lock
      ?clock
      ~keepers_dir
      ~keeper_id
      (fun () ->
       (* File_lock_eio.with_lock appends ".lock" itself; a pre-suffixed path
          locked "<snapshot>.lock.lock" and left a stray file per keeper. *)
       File_lock_eio.with_lock ?clock snapshot_path (fun () ->
         let* previous, snapshot_content =
           match Fs_compat.load_file_opt snapshot_path with
           | None -> Ok (None, None)
           | Some content ->
             (match
                Domain_pool_ref.submit_cpu_or_inline (fun () ->
                  parse snapshot_path content)
              with
              | Ok snapshot -> Ok (Some snapshot, Some content)
              | Error rejection ->
                (* Every writer reads before it writes, so a snapshot this
                   build cannot decode is durable state no producer can leave:
                   one undecodable file wedged eight live keepers for good on
                   2026-09-01. #32239 declared a hard cut and left the old
                   files in place, and that is the half that was missing — a
                   hard cut is finished when the old state is gone.

                   The bytes move aside instead of being overwritten by the
                   commit below, because recovering by destroying the only copy
                   of the rejected state is not recovery. *)
                let rejected_path = unused_rejected_path ~snapshot_path ~now in
                (match Fs_compat.rename snapshot_path rejected_path with
                 | () ->
                   append_snapshot_quarantine
                     ~keepers_dir
                     ~keeper_id
                     ~now
                     ~rejection
                     ~rejected_path;
                   Log.Keeper.warn
                     ~keeper_name:keeper_id
                     "memory os snapshot quarantined rejected_path=%s rejection=%s"
                     rejected_path
                     rejection;
                   Ok (None, None)
                 | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
                 | exception exn ->
                   (* Failing here keeps the wedge, which is the lesser harm:
                      the alternative overwrites the rejected bytes. *)
                   Error
                     (store_error
                        (Printf.sprintf
                           "current Memory OS snapshot could not be moved aside path=%s: %s (rejected: %s)"
                           snapshot_path
                           (Printexc.to_string exn)
                           rejection))))
         in
         let snapshot =
           match previous, snapshot_content with
           | Some current, Some content -> Some (current, content)
           | None, None -> None
           | Some _, None | None, Some _ -> None
         in
         let* () =
           reconcile_retraction_plan_receipt
             ~keepers_dir
             ~keeper_id
             ~snapshot
           |> Result.map_error store_error
         in
         let* durable_range_receipts =
           reconcile_durable_range_receipts
             ~keepers_dir
             ~keeper_id
             ~snapshot
           |> Result.map_error store_error
         in
         let* next = build ~snapshot_content previous in
         (* The file is 150-330 KB per keeper and every commit reads it, parses
            it, prints it and replaces it. On the scheduler domain that was one
            11-24 ms run per commit (rtev, 2026-09-16), about 80 commits an
            hour across the fleet; for the 330 KB file the parse is 2.6 ms and
            the print 5.4 ms. Both are pure over immutable values, so they run
            in pool jobs. The locks are held across the wait, which delays
            another writer of this same keeper's memory and nothing else. *)
         let content =
           Domain_pool_ref.submit_cpu_or_inline (fun () -> snapshot_bytes next)
         in
         (* Last before the replace, after the pool wait: a write made here and
            a snapshot that is then not replaced are split only by the replace
            failing, not by a cancellation while the print is on the pool. *)
         let* () =
           match before_replace with
           | None -> Ok ()
           | Some write -> write ~previous ~next
         in
         let snapshot_sha256 = sha256 content in
         let* retraction_receipt =
           match retraction_plan with
           | None -> Ok None
           | Some (plan_id, _) ->
             (match snapshot, dropped_statements with
              | Some (prior, prior_content), Some ((_ :: _) as reasons) ->
                (match next.source with
                 | { kind = Explicit_retract; trace_id }
                   when String.equal trace_id plan_id ->
                   let receipt =
                     { plan_id
                     ; prior_revision = prior.revision
                     ; prior_snapshot_sha256 = sha256 prior_content
                     ; target_revision = next.revision
                     ; target_snapshot_sha256 = snapshot_sha256
                     ; dropped_statements = reasons
                     }
                   in
                   let+ () =
                     write_retraction_plan_receipt
                       ~keepers_dir
                       ~keeper_id
                       receipt
                     |> Result.map_error store_error
                   in
                   Some receipt
                 | _ ->
                   Error
                     (store_error
                        "retraction plan source must be an exact explicit-retract plan"))
              | None, _ | _, None | _, Some [] ->
                Error
                  (store_error
                     "retraction plan requires one existing snapshot and non-empty exact reasons"))
         in
         let ranges =
           Option.to_list (Option.map (fun range -> Atom_range range) durable_range_id)
           @ Option.to_list (Option.map (fun range -> Official_range range) official_range_id)
         in
         let receipts_for make =
           List.fold_left (fun receipts range_id ->
             upsert_durable_range_receipt receipts (make range_id)) durable_range_receipts ranges
         in
         let* () =
           match ranges with
           | [] -> Ok ()
           | _ :: _ ->
             write_durable_range_receipts ~keepers_dir ~keeper_id
               (receipts_for (fun range_id ->
                  Prepared { range_id; snapshot_revision = next.revision; snapshot_sha256 }))
             |> Result.map_error store_error
         in
         (* Locks and preparation remain cancellable. Once replacement starts,
            retain its result and publish commit evidence before cancellation
            can interrupt the journal/receipt writes for this snapshot. *)
         let commit () =
           match Fs_compat.save_file_atomic snapshot_path content with
           | Ok () ->
             committed := Some
               { Keeper_memory_commit_notifications.keepers_dir = notification_keepers_dir
               ; keeper_id
               ; store = Ordinary
               ; revision = next.revision
             };
             Option.iter (fun observe -> observe next) on_committed;
             let journal_result =
               match retraction_receipt, retraction_plan with
               | None, _ ->
                 append_journal_entry ~keepers_dir ~keeper_id ~dropped_statements next;
                 Ok ()
               | Some receipt, Some (_, evidence_error) ->
                 reconcile_retraction_plan_receipt
                   ~keepers_dir
                   ~keeper_id
                   ~snapshot:(Some (next, content))
                 |> Result.map_error (fun detail ->
                      evidence_error
                        ~plan_id:receipt.plan_id
                        ~snapshot_revision:receipt.target_revision
                        ~snapshot_sha256:receipt.target_snapshot_sha256
                        ~detail)
               | Some _, None ->
                 Error
                   (store_error
                      "retraction receipt was prepared without an owning plan")
             in
             (match ranges with
              | [] -> ()
              | _ :: _ ->
                (match write_durable_range_receipts ~keepers_dir ~keeper_id
                   (receipts_for (fun range_id ->
                      Committed { range_id; snapshot_revision = next.revision; snapshot_sha256 }))
                 with
                 | Ok () -> ()
                 | Error detail ->
                   Log.Keeper.warn ~keeper_name:keeper_id
                     "%s; prepared receipt remains recoverable" detail));
             let+ () = journal_result in
             List.iter
               (fun invalidation ->
                  Log.Keeper.info
                    "memory os support retracted keeper=%s revision=%d memory_id=%s missing_premise_ids=%s"
                    keeper_id
                    next.revision
                    (memory_id invalidation.fact)
                    (String.concat "," invalidation.missing_premise_ids))
               next.change.invalidated;
             next
           | Error message ->
             Error
               (store_error
                  (Printf.sprintf
                     "current Memory OS atomic write failed path=%s: %s"
                     snapshot_path
                     message))
         in
         match Eio_guard.execution_context () with
         | Eio_guard.Non_eio -> commit ()
         | Eio_guard.Eio_fiber -> Eio.Cancel.protect commit))
    in
    (* Dispatch only after BOTH locks have unwound. The marker is set at the
       snapshot commit, so a later journal failure/cancellation cannot suppress
       an already committed change or make a failed write look committed. *)
    match write () with
    | result -> notify (); result
    | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      notify ();
      Printexc.raise_with_backtrace exn backtrace)
;;

let update_locked
      ?on_committed
      ?clock
      ?dropped_statements
      ?before_replace
      ?durable_range_id
      ?official_range_id
      ~keepers_dir
      ~keeper_id
      ~now
      build
  =
  update_locked_with_error
    ?on_committed
    ?clock
    ?dropped_statements
    ?before_replace
    ?durable_range_id
    ?official_range_id
    ~store_error:Fun.id
    ~keepers_dir
    ~keeper_id
    ~now
    build
;;

let committed_range ~keepers_dir ~keeper_id select =
  try
    Fs_compat.mkdir_p keepers_dir;
    let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
    Keeper_memory_os_aggregate_lock.with_lock ~keepers_dir ~keeper_id (fun () ->
      File_lock_eio.with_lock snapshot_path (fun () ->
        let* snapshot =
          match Fs_compat.load_file_opt snapshot_path with
          | None -> Ok None
          | Some content ->
            let+ current = parse snapshot_path content in
            Some (current, content)
        in
        let* receipts =
          reconcile_durable_range_receipts
            ~keepers_dir
            ~keeper_id
            ~snapshot
        in
        Ok
          (List.find_map
             (function
               | Committed { range_id; _ } -> select range_id
               | Prepared _ -> None)
             receipts)))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Printf.sprintf
         "durable Librarian range receipt check failed keeper=%s: %s"
         keeper_id
         (Printexc.to_string exn))
;;

let committed_durable_range ~keepers_dir ~keeper_id ~receipt_scope =
  committed_range ~keepers_dir ~keeper_id (function
    | Atom_range range when String.equal range.receipt_scope receipt_scope -> Some range
    | Atom_range _ | Official_range _ -> None)
;;

let committed_official_range ~keepers_dir ~keeper_id ~receipt_scope =
  committed_range ~keepers_dir ~keeper_id (function
    | Official_range range when String.equal range.receipt_scope receipt_scope -> Some range
    | Atom_range _ | Official_range _ -> None)
;;

let make_snapshot_from_maintained
      ~previous
      ~now
      ~source
      ~facts
      ~invalidated
      ()
  =
  let previous_facts, revision =
    match previous with
    | None -> [], 1
    | Some snapshot -> snapshot.facts, snapshot.revision + 1
  in
  let+ change = compute_change ~previous:previous_facts ~next:facts ~invalidated in
  { revision
  ; updated_at = now
  ; source
  ; facts
  ; change
  }
;;

let make_snapshot
      ~previous
      ~now
      ~source
      ~facts
      ()
  =
  let facts, invalidated = maintain_supported_facts facts in
  make_snapshot_from_maintained
    ~previous
    ~now
    ~source
    ~facts
    ~invalidated
    ()
;;

(* Apply a librarian's disposition to whatever the snapshot holds when the
   lock is taken.

   The librarian says three things about the facts it was shown: keep this one,
   retire that one for this reason, add these new claims. Those statements are
   what it decided; the whole-set list it also carries is a projection of them
   against the snapshot it read, and projecting early is what forced the write
   to demand that nothing had changed since. A keeper recording one fact of its
   own during the pass moved the revision and the pass was thrown away -- 758
   times on the fleet, 590 of them in one week (masc #32859).

   A fact the disposition never mentions is one the librarian never saw, so it
   is left alone. That is the whole difference.

   A fact the librarian retires is retired even if the keeper re-observed it
   during the pass: the judgment was about the claim, and a re-observation does
   not answer it. The keeper can state it again on its next turn. *)
type disposition =
  { snapshot : t
  ; absorbed_applied : Keeper_memory_os_types.absorbed_statement list
  ; absorbed_not_applied : Keeper_memory_os_types.absorbed_statement list
  }

let apply_disposition
      ?on_committed
      ?clock
      ?dropped_statements
      ?durable_range_id
      ?official_range_id
      ~absorbed
      ~keepers_dir
      ~keeper_id
      ~now
      ~source
      ~new_claims
      ()
  =
  let retired =
    List.fold_left
      (fun ids (statement : Keeper_memory_os_types.dropped_statement) ->
         Set_util.StringSet.add statement.memory_id ids)
      Set_util.StringSet.empty
      (Option.value dropped_statements ~default:[])
  in
  (* An absorption goes into a memory the answer names: a new claim, or a
     current memory it wrote again verbatim. The librarian read the snapshot
     before its provider turn, so a memory it restated may be gone by the time
     the lock is taken (a keeper retraction or supersede during the pass). An
     absorption whose target is neither held by the locked snapshot nor added
     by this answer is not applied: its source stays current, the removed
     memory is not brought back, and no absorbed row points into an id no
     snapshot has (#38186). The store decides this itself; no caller input
     is needed. *)
  let new_claim_ids =
    List.fold_left
      (fun ids fact -> Set_util.StringSet.add (memory_id fact) ids)
      Set_util.StringSet.empty
      new_claims
  in
  let absorbed_into (previous : t option) =
    let current_ids =
      match previous with
      | None -> Set_util.StringSet.empty
      | Some snapshot ->
        List.fold_left
          (fun ids fact -> Set_util.StringSet.add (memory_id fact) ids)
          Set_util.StringSet.empty
          snapshot.facts
    in
    List.fold_left
      (fun into_of (statement : Keeper_memory_os_types.absorbed_statement) ->
         if Set_util.StringSet.mem statement.into current_ids
            || Set_util.StringSet.mem statement.into new_claim_ids
         then Set_util.StringMap.add statement.absorbed statement.into into_of
         else into_of)
      Set_util.StringMap.empty
      absorbed
  in
  (* An absorption is applied when its row is written: its source left the
     snapshot into its target. Set by the one [before_replace] under the lock,
     which runs on every commit; read only after the commit succeeded. *)
  let partitioned = ref ([], absorbed) in
  let disposition_of snapshot =
    let absorbed_applied, absorbed_not_applied = !partitioned in
    { snapshot; absorbed_applied; absorbed_not_applied }
  in
  (* RFC-0456 §4.2: an absorbed fact leaves the snapshot only with its row kept.
     The rows are the absorbed facts the locked snapshot held and the next one
     does not, so a fact the keeper retracted during the pass has no row, and
     they are written just before the replace; a failed write fails this
     commit. *)
  let write_absorbed_rows ~(previous : t option) ~(next : t) =
    let absorbed_into = absorbed_into previous in
    let next_ids =
      List.fold_left
        (fun ids fact -> Set_util.StringSet.add (memory_id fact) ids)
        Set_util.StringSet.empty
        next.facts
    in
    let rows =
      List.filter_map
        (fun fact ->
           let identity = memory_id fact in
           match Set_util.StringMap.find_opt identity absorbed_into with
           | Some into when not (Set_util.StringSet.mem identity next_ids) ->
             Some
               { Keeper_memory_absorbed.recorded_at = now
               ; trace_id = (source : source).trace_id
               ; memory_id = identity
               ; into
               ; fact
               }
           | Some _ | None -> None)
        (match previous with
         | None -> []
         | Some snapshot -> snapshot.facts)
    in
    partitioned
    := List.partition
         (fun (statement : Keeper_memory_os_types.absorbed_statement) ->
            List.exists
              (fun (row : Keeper_memory_absorbed.record) ->
                 String.equal row.memory_id statement.absorbed
                 && String.equal row.into statement.into)
              rows)
         absorbed;
    Keeper_memory_absorbed.append_all ~keepers_dir ~keeper_id rows
    |> Result.map_error Keeper_memory_absorbed.append_error_to_string
  in
  update_locked
    ?on_committed:
      (Option.map (fun on_committed snapshot -> on_committed (disposition_of snapshot))
         on_committed)
    ?clock
    ?dropped_statements
    ?durable_range_id
    ?official_range_id
    ~before_replace:write_absorbed_rows
    ~keepers_dir
    ~keeper_id
    ~now
    (fun ~snapshot_content:_ previous ->
       let current =
         match previous with
         | None -> []
         | Some snapshot -> snapshot.facts
       in
       let absorbed_into = absorbed_into previous in
       let kept =
         List.filter
           (fun fact ->
              let identity = memory_id fact in
              not
                (Set_util.StringSet.mem identity retired
                 || Set_util.StringMap.mem identity absorbed_into))
           current
       in
       let kept_ids =
         List.fold_left
           (fun ids fact -> Set_util.StringSet.add (memory_id fact) ids)
           Set_util.StringSet.empty
           kept
       in
       (* The store rejects a repeated identity outright, so a claim the keeper
          already wrote during the pass is not appended a second time. *)
       let added, _ =
         List.fold_left
           (fun (acc, seen) fact ->
              let identity = memory_id fact in
              if Set_util.StringSet.mem identity seen
              then acc, seen
              else fact :: acc, Set_util.StringSet.add identity seen)
           ([], kept_ids)
           new_claims
       in
       make_snapshot ~previous ~now ~source ~facts:(kept @ List.rev added) ())
  |> Result.map disposition_of
;;

let replace
      ?clock
      ?dropped_statements
      ~keepers_dir
      ~keeper_id
      ~expected_revision
      ~now
      ~source
      ~facts
      ()
  =
  update_locked
    ?clock
    ?dropped_statements
    ~keepers_dir
    ~keeper_id
    ~now
    (fun ~snapshot_content:_ previous ->
    let observed_revision =
      Option.map (fun snapshot -> snapshot.revision) previous
    in
    if observed_revision <> expected_revision
    then
      Error
        (Printf.sprintf
           "current Memory OS revision conflict expected=%s observed=%s"
           (Option.fold ~none:"absent" ~some:string_of_int expected_revision)
           (Option.fold ~none:"absent" ~some:string_of_int observed_revision))
    else
      make_snapshot
        ~previous
        ~now
        ~source
        ~facts
        ())
;;

(* One incoming fact added to a fact list: new claim bytes are appended,
   bytes already present are a re-observation of that row. Shared by
   {!upsert_fact} and {!supersede_fact}, so both give a row the same
   [first_seen] and [last_seen]. *)
let insert_or_reobserve current_facts (incoming : Keeper_memory_os_types.fact) =
  let incoming_identity = memory_id incoming in
  let found = ref false in
  let facts =
    List.map
      (fun existing ->
         if String.equal (memory_id existing) incoming_identity
         then (
           found := true;
           (* Byte-identical re-observation of an existing row. The exact
              claim bytes were already on file, so this is not a new fact:
              preserve the authoritative insertion time and the original
              origin (an injected copy re-observed must not repaint an
              authored row) and refresh the observation time. Nothing is
              counted: seeing the same bytes again says nothing about the
              fact's worth (RFC-0418). *)
           { incoming with
             first_seen = existing.first_seen
           ; last_seen = Float.max existing.last_seen incoming.last_seen
           ; origin = existing.origin
           ; basis = merge_basis existing.basis incoming.basis
           })
         else existing)
      current_facts
  in
  if !found then facts else facts @ [ incoming ]
;;

let upsert_fact
      ?clock
      ~keepers_dir
      ~keeper_id
      ~now
      ~source
      incoming
  =
  update_locked_with_error
    ?clock
    ~store_error:(fun detail -> Upsert_persistence_failed detail)
    ~keepers_dir
    ~keeper_id
    ~now
    (fun ~snapshot_content:_ previous ->
    let current_facts =
      match previous with
      | None -> []
      | Some snapshot -> snapshot.facts
    in
    let current_ids =
      List.fold_left
        (fun ids fact -> Set_util.StringSet.add (memory_id fact) ids)
        Set_util.StringSet.empty
        current_facts
    in
    let* () =
      match incoming.basis with
      | Observed _ -> Ok ()
      | Derived derivations when derivations_supported current_ids derivations ->
        Ok ()
      | Derived derivations ->
        Error
          (Unsupported_derivation
             { fact = incoming
             ; missing_premise_ids = missing_premises_for current_ids derivations
             })
    in
    let facts = insert_or_reobserve current_facts incoming in
    let facts, invalidated = maintain_supported_facts facts in
    let incoming_identity = memory_id incoming in
    match
      List.find_opt
        (fun invalidation ->
           String.equal (memory_id invalidation.fact) incoming_identity)
        invalidated
    with
    | Some invalidation -> Error (Unsupported_derivation invalidation)
    | None ->
      make_snapshot_from_maintained
        ~previous
        ~now
        ~source
        ~facts
        ~invalidated
        ()
      |> Result.map_error (fun detail -> Upsert_persistence_failed detail))
;;

let retract_current_facts ~target_ids current_facts =
  match
    Set_util.StringSet.to_seq target_ids
    |> Seq.find_map (fun target_memory_id ->
         if
           List.exists
             (fun fact ->
                String.equal
                  (Keeper_memory_os_types.memory_id fact)
                  target_memory_id)
             current_facts
         then None
         else Some target_memory_id)
  with
  | Some missing -> Error missing
  | None ->
    let candidates =
      List.filter
        (fun fact ->
           not
             (Set_util.StringSet.mem
                (Keeper_memory_os_types.memory_id fact)
                target_ids))
        current_facts
    in
    Ok (maintain_supported_facts candidates)
;;

let retract_fact
      ?clock
      ~keepers_dir
      ~keeper_id
      ~now
      ~source
      ~memory_id:target_memory_id
      ~reason
      ()
  =
  if not (Keeper_memory_os_types.is_memory_id target_memory_id)
  then Error Retract_memory_id_invalid
  else if String.equal (String.trim reason) ""
  then Error Retract_reason_empty
  else
    update_locked_with_error
      ?clock
      ~dropped_statements:
        [ { Keeper_memory_os_types.memory_id = target_memory_id; reason } ]
      ~store_error:(fun detail -> Retract_persistence_failed detail)
      ~keepers_dir
      ~keeper_id
      ~now
      (fun ~snapshot_content:_ previous ->
      let current_facts =
        match previous with
        | None -> []
        | Some snapshot -> snapshot.facts
      in
      let* facts, invalidated =
        retract_current_facts
          ~target_ids:(Set_util.StringSet.singleton target_memory_id)
          current_facts
        |> Result.map_error (fun missing -> Retract_fact_not_found missing)
      in
        make_snapshot_from_maintained
          ~previous
          ~now
          ~source
          ~facts
          ~invalidated
          ()
        |> Result.map_error (fun detail -> Retract_persistence_failed detail))
;;

(* A supersession is a retraction and a write that must not be seen apart: a
   reader between the two would find either both claims or neither. So the
   target leaves and the successor arrives in one locked update, and the
   successor goes through the same [insert_or_reobserve] an ordinary write
   does. *)
let supersede_fact
      ?clock
      ~keepers_dir
      ~keeper_id
      ~now
      ~source
      ~superseded_memory_id
      (incoming : Keeper_memory_os_types.fact)
  =
  let incoming_identity = memory_id incoming in
  if not (Keeper_memory_os_types.is_memory_id superseded_memory_id)
  then Error Supersede_memory_id_invalid
  else if String.equal incoming_identity superseded_memory_id
  then Error Supersede_self
  else
    update_locked_with_error
      ?clock
      ~dropped_statements:
        [ { Keeper_memory_os_types.memory_id = superseded_memory_id
          ; reason = "superseded_by " ^ incoming_identity
          }
        ]
      ~store_error:(fun detail -> Supersede_persistence_failed detail)
      ~keepers_dir
      ~keeper_id
      ~now
      (fun ~snapshot_content:_ previous ->
      let current_facts =
        match previous with
        | None -> []
        | Some snapshot -> snapshot.facts
      in
      let* () =
        match
          List.find_opt
            (fun fact -> String.equal (memory_id fact) superseded_memory_id)
            current_facts
        with
        | None -> Error (Supersede_target_not_current superseded_memory_id)
        | Some { origin = { kind = Keeper_memory_os_types.Authored; _ }; _ } -> Ok ()
        | Some { origin = { kind = Keeper_memory_os_types.Injected; _ }; _ } ->
          Error (Supersede_target_not_authored superseded_memory_id)
      in
      let remaining =
        List.filter
          (fun fact -> not (String.equal (memory_id fact) superseded_memory_id))
          current_facts
      in
      let facts, invalidated =
        maintain_supported_facts (insert_or_reobserve remaining incoming)
      in
      match
        List.find_opt
          (fun invalidation ->
             String.equal (memory_id invalidation.fact) incoming_identity)
          invalidated
      with
      | Some invalidation
        when List.exists
               (String.equal superseded_memory_id)
               invalidation.missing_premise_ids ->
        Error (Supersede_successor_rests_on_target invalidation)
      | Some invalidation -> Error (Supersede_unsupported_derivation invalidation)
      | None ->
        make_snapshot_from_maintained
          ~previous
          ~now
          ~source
          ~facts
          ~invalidated
          ()
        |> Result.map_error (fun detail -> Supersede_persistence_failed detail))
;;

let retract_facts
      ?clock
      ~keepers_dir
      ~keeper_id
      ~expected_revision
      ~expected_snapshot_sha256
      ~now
      ~(source : source)
      retractions
  =
  let rec validate index seen = function
    | [] -> Ok seen
    | ({ memory_id; reason } : retraction) :: rest ->
      if not (Keeper_memory_os_types.is_memory_id memory_id)
      then Error (Retract_batch_memory_id_invalid { index })
      else if String.equal (String.trim reason) ""
      then Error (Retract_batch_reason_empty { index })
      else if Set_util.StringSet.mem memory_id seen
      then Error (Retract_batch_duplicate_memory_id memory_id)
      else
        validate
          (index + 1)
          (Set_util.StringSet.add memory_id seen)
          rest
  in
  if not (String_util.is_lowercase_sha256_hex expected_snapshot_sha256)
  then Error Retract_batch_snapshot_sha256_invalid
  else match retractions with
  | [] -> Error Retract_batch_empty
  | _ :: _ ->
    let* target_ids = validate 0 Set_util.StringSet.empty retractions in
    let dropped_statements =
      List.map
        (fun ({ memory_id; reason } : retraction) ->
           { Keeper_memory_os_types.memory_id; reason })
        retractions
    in
    update_locked_with_error
      ?clock
      ~dropped_statements
      ~retraction_plan:
        ( source.trace_id
        , fun ~plan_id ~snapshot_revision ~snapshot_sha256 ~detail ->
            Retract_batch_plan_evidence_pending
              { plan_id; snapshot_revision; snapshot_sha256; detail } )
      ~store_error:(fun detail -> Retract_batch_persistence_failed detail)
      ~keepers_dir
      ~keeper_id
      ~now
      (fun ~snapshot_content previous ->
      let observed_revision =
        Option.map (fun snapshot -> snapshot.revision) previous
      in
      let observed_snapshot_sha256 = Option.map sha256 snapshot_content in
      if
        observed_revision <> Some expected_revision
        || observed_snapshot_sha256 <> Some expected_snapshot_sha256
      then
        Error
          (Retract_batch_snapshot_conflict
             { expected_revision
             ; observed_revision
             ; expected_snapshot_sha256
             ; observed_snapshot_sha256
             })
      else
        let current_facts =
          match previous with
          | None -> []
          | Some snapshot -> snapshot.facts
        in
        let* facts, invalidated =
          retract_current_facts ~target_ids current_facts
          |> Result.map_error (fun missing ->
               Retract_batch_fact_not_found missing)
        in
        make_snapshot_from_maintained
          ~previous
          ~now
          ~source
          ~facts
          ~invalidated
          ()
        |> Result.map_error (fun detail ->
             Retract_batch_persistence_failed detail))
;;

(* Read-side projection of every closed journal shape. *)
let decoded_journal_entry_to_json = function
  | Journal_committed { recorded_at; revision; source; change; dropped } ->
    `Assoc
      ([ "outcome", `String committed_outcome
       ; "recorded_at", `Float recorded_at
       ; "revision", `Int revision
       ; "source", source_to_json source
       ; "change", change_to_json change
       ]
       @
       match dropped with
       | None -> []
       | Some statements ->
         [ "dropped", `List (List.map dropped_statement_to_json statements) ])
  | Journal_failed { recorded_at; trace_id; kind; detail; snapshot_present } ->
    `Assoc
      [ "outcome", `String failed_outcome
      ; "recorded_at", `Float recorded_at
      ; "trace_id", `String trace_id
      ; "kind", `String (librarian_failure_kind_to_string kind)
      ; "detail", `String detail
      ; "snapshot_present", `Bool snapshot_present
      ]
  | Journal_quarantined { recorded_at; rejection; rejected_path } ->
    journal_quarantine_to_json ~now:recorded_at ~rejection ~rejected_path
;;

(* A line this build could not decode keeps its position and says why. Dropping
   it would make a journal with a torn line read as a shorter one, and the
   operator counting passes is the one who would be misled. *)
let journal_line_to_json = function
  | Ok entry ->
    (match decoded_journal_entry_to_json entry with
     | `Assoc fields -> `Assoc (("ok", `Bool true) :: fields)
     | json -> json)
  | Error reason -> `Assoc [ "ok", `Bool false; "error", `String reason ]
;;

let journal_projection_identity ~keeper_id line_offset =
  Printf.sprintf "memory:journal:%d:%s:%d" (String.length keeper_id) keeper_id
    line_offset
;;

let read_journal_tail_projection ~keepers_dir ~keeper_id ~limit =
  read_journal_tail_indexed ~keepers_dir ~keeper_id ~limit
  |> List.map (fun (line_offset, result) ->
       match journal_line_to_json result with
       | `Assoc fields ->
         `Assoc
           (( "structural_id"
            , `String (journal_projection_identity ~keeper_id line_offset) )
            :: fields)
       | json -> json)
;;

(* Boot-time twin of the writer's quarantine above: the same decoder, the
   same locks, the same move-aside and journal line, but run once over every
   keeper before any keeper loop starts. A snapshot this build cannot decode
   is therefore never discovered mid-turn by whichever read or write happens
   to come first. *)
let move_aside_for_keepers_dir ?clock ~keepers_dir ~keeper_id ~now ~rejection () =
  let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  Keeper_memory_os_aggregate_lock.with_lock ?clock ~keepers_dir ~keeper_id (fun () ->
    File_lock_eio.with_lock ?clock snapshot_path (fun () ->
      let rejected_path = unused_rejected_path ~snapshot_path ~now in
      match Fs_compat.rename snapshot_path rejected_path with
      | () ->
        append_snapshot_quarantine ~keepers_dir ~keeper_id ~now ~rejection ~rejected_path;
        Ok rejected_path
      | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
      | exception exn ->
        Error
          (Printf.sprintf
             "current Memory OS snapshot could not be moved aside path=%s: %s (rejected: %s)"
             snapshot_path
             (Printexc.to_string exn)
             rejection)))
;;
