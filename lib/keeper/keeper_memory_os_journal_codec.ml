(** Pure Memory journal wire format and dashboard row projection. *)

open Keeper_memory_os_types
open Keeper_memory_os_current_types
open Result.Syntax

module Snapshot_codec = Keeper_memory_os_snapshot_codec

let exact_object_fields names fields =
  Result.is_ok (exact_field_names_result names fields)
;;

let librarian_failure_kind_to_string = function
  | Prompt_render_failure -> "prompt_render_failure"
  | Execution_clock_unavailable -> "execution_clock_unavailable"
  | Exact_setup_failure -> "exact_setup_failure"
  | Exact_execution_failure -> "exact_execution_failure"
  | Domain_output_invalid -> "domain_output_invalid"
  | Absorb_judgment_failure -> "absorb_judgment_failure"
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
  | "absorb_judgment_failure" -> Some Absorb_judgment_failure
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
   librarian's own account of the drops this commit carried out, possibly
   empty ([dropped_by_commit]). Statements live on the journal line and its
   pending removal receipt; the snapshot's [change.removed] preserves the
   originals until finalization. *)
let revision_links_to_json links = `List (List.map (fun (link : revision) ->
  `Assoc ["superseded", `String link.superseded; "superseded_by", `String link.superseded_by]) links)
;;

let revision_links_of_json = function
  | `List rows ->
    let rec decode seen = function
      | [] -> Ok []
      | `Assoc fields :: rest ->
        let* () = exact_field_names_result ["superseded"; "superseded_by"] fields
          |> Result.map_error wire_error_to_string in
        let* superseded = wire_string_field "superseded" fields |> Result.map_error wire_error_to_string in
        let* superseded_by = wire_string_field "superseded_by" fields |> Result.map_error wire_error_to_string in
        if not (is_memory_id superseded && is_memory_id superseded_by)
          || superseded = superseded_by || List.mem (superseded, superseded_by) seen
        then Error "invalid or duplicate revision link identity"
        else let+ rest = decode ((superseded, superseded_by) :: seen) rest in
          {superseded; superseded_by} :: rest
      | _ :: _ -> Error "revision link is not an object" in
    decode [] rows
  | _ -> Error "revision links are not an array"
;;

let journal_revision_links fields =
  match List.assoc_opt "revision_links" fields with
  | None -> Ok None
  | Some json -> Result.map Option.some (revision_links_of_json json)
;;

let links_applied_to_snapshot (snapshot : t) links =
  List.for_all (fun (link : revision) ->
    List.exists (fun fact -> memory_id fact = link.superseded) snapshot.change.removed
    && not (List.exists (fun fact -> memory_id fact = link.superseded) snapshot.facts)
    && List.exists (fun fact -> memory_id fact = link.superseded_by) snapshot.facts) links
;;

let journal_entry_to_json ?program ~commit_effect ~revision_links ~dropped_statements snapshot =
  `Assoc
    ([ "outcome", `String committed_outcome
     ; "commit_effect", `String (match commit_effect with Rewritten -> "rewritten" | Unchanged -> "unchanged")
     ; "recorded_at", `Float snapshot.updated_at
     ; "revision", `Int snapshot.revision
     ; "source", Snapshot_codec.source_to_json snapshot.source
     ; "change", Snapshot_codec.change_to_json snapshot.change
     ]
     @ (match program with None -> [] | Some execution ->
         ["ordered_program",Keeper_memory_os_program_publication.to_json execution])
     @ (match commit_effect with
        | Rewritten -> ["revision_links", revision_links_to_json revision_links]
        | Unchanged -> [])
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

let journal_commit_effect fields =
  match List.assoc_opt "commit_effect" fields with
  | None -> Ok None
  | Some (`String "rewritten") -> Ok (Some Rewritten)
  | Some (`String "unchanged") -> Ok (Some Unchanged)
  | Some _ -> Error "committed line has an invalid commit_effect"
;;

let committed_entry_of_fields fields =
  let* transition = journal_commit_effect fields in
  let* links = journal_revision_links fields in
  let* () = match links, transition with
    | Some (_ :: _), Some Rewritten -> Ok ()
    | Some (_ :: _), (Some Unchanged | None) -> Error "revision links lack a snapshot transition"
    | (Some [] | None), _ -> Ok () in
  let expected = ["outcome"; "recorded_at"; "revision"; "source"; "change"]
    @ (if List.mem_assoc "dropped" fields then ["dropped"] else [])
    @ (if List.mem_assoc "commit_effect" fields then ["commit_effect"] else [])
    @ (if List.mem_assoc "revision_links" fields then ["revision_links"] else [])
    @ (if List.mem_assoc "ordered_program" fields then ["ordered_program"] else []) in
  let fields_are_exact = exact_object_fields expected fields in
  let* program = match List.assoc_opt "ordered_program" fields with
    | None -> Ok None
    | Some json ->
      let* execution = Keeper_memory_os_program_publication.of_json json in
      (match transition, links with
       | Some Rewritten, Some [] -> Ok (Some execution)
       | (Some Rewritten | Some Unchanged | None), (Some _ | None) ->
         Error "ordered program requires one explicit rewrite without flattened legacy links") in
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
    (match Snapshot_codec.source_of_json source, Snapshot_codec.change_of_json change with
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
       let* () = match program with
         | None -> Ok ()
         | Some publication ->
           let librarian = match source.kind with
             | Librarian -> true
             | Explicit_write | Explicit_retract -> false in
           let* () =
             if librarian && change.invalidated=[] && not (List.mem_assoc "dropped" fields)
             then Ok ()
             else Error "ordered proof must retain intermediate causes in its program, not legacy outer fields" in
           Keeper_memory_os_program_publication.validate_transition publication
             ~source_trace_id:source.trace_id ~revision ~added:change.added ~removed:change.removed
             ~retained:change.retained in
       (match List.assoc_opt "dropped" fields with
        | None ->
          Ok (Journal_committed { recorded_at; revision; source; change; dropped = None; program })
        | Some dropped ->
          (match dropped_of_json dropped with
           | Ok statements ->
             Ok
               (Journal_committed
                  { recorded_at; revision; source; change; dropped = Some statements; program })
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

let journal_quarantine_to_json ~now ~rejection ~rejected_path =
  `Assoc
    [ "outcome", `String quarantined_outcome
    ; "recorded_at", `Float now
    ; "rejection", `String rejection
    ; "rejected_path", `String rejected_path
    ]
;;

(* Read-side projection of every closed journal shape. *)
let decoded_journal_entry_to_json = function
  | Journal_committed { recorded_at; revision; source; change; dropped; program=_ } ->
    `Assoc
      ([ "outcome", `String committed_outcome
       ; "recorded_at", `Float recorded_at
       ; "revision", `Int revision
       ; "source", Snapshot_codec.source_to_json source
       ; "change", Snapshot_codec.change_to_json change
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

(* Only a line that rewrote the snapshot covers its revision. An unchanged
   observation repeats a revision another line wrote, and a line without a
   commit effect proves neither. *)
let journal_line_rewrote (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match journal_commit_effect fields with
     | Ok (Some Rewritten) -> true
     | Ok (Some Unchanged | None) | Error _ -> false)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> false
