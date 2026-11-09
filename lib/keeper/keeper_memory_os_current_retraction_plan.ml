open Keeper_memory_os_types
open Result.Syntax
module Journal_codec = Keeper_memory_os_journal_codec
open Keeper_memory_os_current_types
open Keeper_memory_os_current_layout
open Keeper_memory_os_current_receipt_store
open Keeper_memory_os_current_journal

type retraction_plan_receipt =
  { plan_id : string option
      (* [Some id] belongs to the exact batch API. [None] preserves an
         ordinary removal without claiming an operator-approved plan. *)
  ; prior_revision : int
  ; prior_snapshot_sha256 : string
  ; target_revision : int
  ; target_snapshot_sha256 : string
  ; dropped_statements : Keeper_memory_os_types.dropped_statement list
  ; revision_links : revision list
  }

let retraction_plan_receipt_to_json receipt =
  `Assoc
    [ "state", `String "prepared"
    ; "plan_id", (match receipt.plan_id with None -> `Null | Some id -> `String id)
    ; "prior_revision", `Int receipt.prior_revision
    ; "prior_snapshot_sha256", `String receipt.prior_snapshot_sha256
    ; "target_revision", `Int receipt.target_revision
    ; "target_snapshot_sha256", `String receipt.target_snapshot_sha256
    ; "revision_links", Journal_codec.revision_links_to_json receipt.revision_links
    ; ( "dropped"
      , `List
          (List.map
             dropped_statement_to_json
             receipt.dropped_statements) )
    ]
;;

let retraction_plan_receipt_of_json = function
  | `Assoc fields ->
    let* () =
      exact_field_names_detail ~subject:"retraction plan receipt"
        [ "plan_id"
        ; "state"
        ; "prior_revision"
        ; "prior_snapshot_sha256"
        ; "target_revision"
        ; "target_snapshot_sha256"
        ; "revision_links"
        ; "dropped"
        ]
        fields
    in
    (match
       ( List.assoc_opt "plan_id" fields
       , List.assoc_opt "state" fields
       , List.assoc_opt "prior_revision" fields
       , List.assoc_opt "prior_snapshot_sha256" fields
       , List.assoc_opt "target_revision" fields
       , List.assoc_opt "target_snapshot_sha256" fields
       , List.assoc_opt "revision_links" fields
       , List.assoc_opt "dropped" fields )
     with
     | ( Some plan_id_json
       , Some (`String "prepared")
       , Some (`Int prior_revision)
       , Some (`String prior_snapshot_sha256)
       , Some (`Int target_revision)
       , Some (`String target_snapshot_sha256)
       , Some revision_links_json
       , Some (`List dropped_json) )
       when prior_revision > 0
            && target_revision = prior_revision + 1
            && String_util.is_lowercase_sha256_hex prior_snapshot_sha256
            && String_util.is_lowercase_sha256_hex target_snapshot_sha256 ->
       let* revision_links = Journal_codec.revision_links_of_json revision_links_json in
       let* plan_id =
         match plan_id_json with
         | `Null -> Ok None
         | `String plan_id
           when String.trim plan_id <> ""
                && String.equal plan_id (String.trim plan_id) -> Ok (Some plan_id)
         | _ -> Error "retraction plan identity is invalid"
       in
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
        | Ok dropped_statements when dropped_statements <> [] || revision_links <> [] ->
          Ok
            { plan_id
            ; prior_revision
            ; prior_snapshot_sha256
            ; target_revision
            ; target_snapshot_sha256
            ; dropped_statements
            ; revision_links
            }
        | Ok _ -> Error "prepared removal has neither reasons nor revision links"
        | Error _ as error -> error)
     | _ -> Error "retraction plan receipt fields are invalid")
  | _ -> Error "retraction plan receipt is not a JSON object"
;;

let parse_retraction_plan_receipt ~path content =
  match Yojson.Safe.from_string content with
  | json ->
    retraction_plan_receipt_of_json json
    |> Result.map_error (fun detail ->
         Printf.sprintf "retraction plan receipt rejected path=%s: %s" path detail)
  | exception Yojson.Json_error detail ->
    Error
      (Printf.sprintf
         "retraction plan receipt is not JSON path=%s: %s"
         path
         detail)
;;

let read_retraction_plan_receipt ~keepers_dir ~keeper_id =
  let path = retraction_plan_receipt_path ~keepers_dir ~keeper_id in
  match Fs_compat.load_file_opt path with
  | None -> Ok None
  | Some content ->
    Result.map Option.some (parse_retraction_plan_receipt ~path content)
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
  let json = retraction_plan_receipt_to_json receipt in
  let* _ = retraction_plan_receipt_of_json json in
  Fs_compat.save_file_atomic_strict path
    (Yojson.Safe.to_string json)
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

let append_removal_journal_and_clear_receipt
      ~keepers_dir ~keeper_id ~snapshot receipt
  =
  let* () = if Journal_codec.links_applied_to_snapshot snapshot receipt.revision_links then Ok ()
    else Error "prepared revision links do not match the committed snapshot" in
  let* () =
    append_journal_line_strict
      ~keepers_dir
      ~keeper_id
      (Journal_codec.journal_entry_to_json
         ~commit_effect:Rewritten
         ~revision_links:receipt.revision_links
         ~dropped_statements:(Some receipt.dropped_statements)
         snapshot)
  in
  remove_retraction_plan_receipt ~keepers_dir ~keeper_id
;;

(* Whether a committed line equal to a receipt's entry is that receipt's
   rewrite. A writer before [revision_links] recorded no links, and one before
   [commit_effect] recorded neither key; their receipts decode with no links.
   Reading such a line as absent would append the same revision twice. *)
let journal_line_records_rewrite fields ~revision_links =
  match Journal_codec.journal_commit_effect fields, Journal_codec.journal_revision_links fields with
  | Ok (Some Rewritten | None), Ok (Some links) -> links = revision_links
  | Ok (Some Rewritten | None), Ok None -> revision_links = []
  | Ok (Some Unchanged), _ | Error _, _ | Ok _, Error _ -> false
;;

let journal_contains_entry ~keepers_dir ~keeper_id ~revision_links expected =
  let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  (* Only receipt reconciliation calls this, after proving the exact committed
     snapshot. A process interrupted during its append may leave a partial
     final row: recover that tail before deciding whether to append the
     preserved removal. General archive reads never perform this repair. *)
  match Fs_compat.recover_private_jsonl_durable_locked_result path with
  | Ok snapshot ->
    let content = snapshot.Fs_compat.bytes in
    let rec scan line_number = function
      | [] -> Ok false
      | line :: rest when String.equal (String.trim line) "" ->
        scan (line_number + 1) rest
      | line :: rest ->
        (match Yojson.Safe.from_string line with
         | json ->
           (match Journal_codec.journal_entry_of_json json with
            | Ok observed when observed = expected ->
              (match json with
               | `Assoc fields when journal_line_records_rewrite fields ~revision_links -> Ok true
               | _ -> scan (line_number + 1) rest)
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
        match receipt.plan_id, current.source with
        | None, _ -> Ok ()
        | Some plan_id, { kind = Explicit_retract; trace_id }
          when String.equal trace_id plan_id -> Ok ()
        | Some _, { kind = Librarian | Explicit_write | Explicit_retract; _ } ->
          Error
            (Printf.sprintf
               "retraction plan target snapshot has another source target_revision=%d"
               receipt.target_revision)
      in
      (* The target bytes are about to become journal evidence. Confirm
         their durability first, like the durable-range gate: finalizing
         the journal and clearing the receipt must not precede the sync. *)
      let* () =
        Fs_compat.sync_file_and_parent_strict
          (path_for_keepers_dir ~keepers_dir ~keeper_id)
        |> Result.map_error (fun detail ->
          "retraction target Memory snapshot durability is unconfirmed; stores preserved: " ^ detail)
      in
      let journal_entry =
        Journal_committed
          { recorded_at = current.updated_at
          ; revision = current.revision
          ; source = current.source
          ; change = current.change
          ; dropped = Some receipt.dropped_statements
          ; program = None
          }
      in
      let* present =
        journal_contains_entry
          ~keepers_dir
          ~keeper_id
          ~revision_links:receipt.revision_links
          journal_entry
      in
      if present
      then remove_retraction_plan_receipt ~keepers_dir ~keeper_id
      else
        append_removal_journal_and_clear_receipt
          ~keepers_dir ~keeper_id ~snapshot:current receipt
     | None | Some _ ->
      Error
        (Printf.sprintf
           "retraction plan receipt conflicts with current snapshot prior_revision=%d target_revision=%d"
           receipt.prior_revision
           receipt.target_revision))
;;
