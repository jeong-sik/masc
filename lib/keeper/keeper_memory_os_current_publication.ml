open Keeper_memory_os_types
open Result.Syntax
module Journal_codec = Keeper_memory_os_journal_codec
open Keeper_memory_os_current_types
open Keeper_memory_os_current_layout
open Keeper_memory_os_current_range_codec
open Keeper_memory_os_current_receipt_store
open Keeper_memory_os_current_journal
open Keeper_memory_os_current_retraction_plan

type publication_phase = Publication_prepared | Notification_pending

type publication_receipt =
  { phase : publication_phase
  ; prior : (int * string) option
  ; target_revision : int
  ; target_sha256 : string
  ; journal : Yojson.Safe.t
  }

let publication_to_json receipt =
  `Assoc
    [ "phase", `String (match receipt.phase with
        | Publication_prepared -> "prepared" | Notification_pending -> "notification_pending")
    ; "prior", (match receipt.prior with
        | None -> `Null
        | Some (revision, digest) -> `Assoc ["revision", `Int revision; "sha256", `String digest])
    ; "target_revision", `Int receipt.target_revision
    ; "target_sha256", `String receipt.target_sha256
    ; "journal", receipt.journal ]

let publication_of_json = function
  | `Assoc fields ->
    let* () =
      exact_field_names_detail ~subject:"publication receipt"
        ["phase"; "prior"; "target_revision"; "target_sha256"; "journal"] fields
    in
    let* phase = match List.assoc "phase" fields with
      | `String "prepared" -> Ok Publication_prepared
      | `String "notification_pending" -> Ok Notification_pending
      | _ -> Error "invalid publication phase" in
    let* prior = match List.assoc "prior" fields with
      | `Null -> Ok None
      | `Assoc fields ->
        let* () =
          exact_field_names_detail ~subject:"publication prior" ["revision"; "sha256"] fields
        in
        (match List.assoc "revision" fields, List.assoc "sha256" fields with
         | `Int revision, `String digest when revision > 0
             && String_util.is_lowercase_sha256_hex digest -> Ok (Some (revision, digest))
         | _ -> Error "invalid publication prior identity")
      | _ -> Error "invalid publication prior" in
    (match List.assoc "target_revision" fields, List.assoc "target_sha256" fields,
           List.assoc "journal" fields with
     | `Int target_revision, `String target_sha256, (`Assoc journal_fields as journal)
       when target_revision = (match prior with None -> 1 | Some (revision, _) -> revision + 1)
            && String_util.is_lowercase_sha256_hex target_sha256 ->
       let* entry = Journal_codec.journal_entry_of_json journal in
       let* links = Journal_codec.journal_revision_links journal_fields in
       (match entry, Journal_codec.journal_commit_effect journal_fields, links with
        | Journal_committed entry, Ok (Some Rewritten), Some links
          when entry.revision = target_revision ->
          let canonical = Journal_codec.journal_entry_to_json ~commit_effect:Rewritten ~revision_links:links
              ~dropped_statements:entry.dropped ?program:entry.program
              {revision=entry.revision; updated_at=entry.recorded_at; source=entry.source;
               change=entry.change; facts=[]} in
          if Yojson.Safe.sort canonical = Yojson.Safe.sort journal then
            Ok {phase; prior; target_revision; target_sha256; journal}
          else Error "publication journal is not an exact canonical entry"
        | (Journal_committed _ | Journal_failed _ | Journal_quarantined _),
          (Ok (Some (Rewritten | Unchanged) | None) | Error _),
          (Some _ | None) ->
          Error "publication journal is not the target rewrite")
     | _ -> Error "invalid publication target")
  | _ -> Error "publication receipt is not a JSON object"

let parse_publication text =
  match Yojson.Safe.from_string text with
  | json -> publication_of_json json
  | exception Yojson.Json_error detail -> Error ("publication receipt: " ^ detail)

type preflight_observation =
  | Preflight_absent
  | Preflight_snapshot
  | Preflight_publication_pending

(* Open without blocking on special files and inspect the opened descriptor,
   not a path that may be replaced between a stat and an open. *)
let preflight_file_unix ?(allow_missing_ancestors=false) path =
  let rec inspect_parent parent =
    match Unix.lstat parent with
    | stat ->
      (match stat.Unix.st_kind with
       | Unix.S_DIR -> Ok None
       | Unix.S_LNK ->
         (match Unix.stat parent with
          | target when target.Unix.st_kind = Unix.S_DIR -> Ok None
          | _ -> Error (parent ^ ": not a directory")
          | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
          | exception ((Unix.Unix_error _ | Sys_error _) as exn) ->
            Error (parent ^ ": " ^ Printexc.to_string exn))
       | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
         Error (parent ^ ": not a directory"))
    | exception Unix.Unix_error (Unix.ENOENT, _, _) when allow_missing_ancestors ->
      let next = Filename.dirname parent in
      if String.equal next parent then Error (parent ^ ": missing directory")
      else inspect_parent next
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception ((Unix.Unix_error _ | Sys_error _) as exn) ->
      Error (parent ^ ": " ^ Printexc.to_string exn) in
  try
    let fd = Unix.openfile path [Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC] 0 in
    let channel = Unix.in_channel_of_descr fd in
    Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
      if (Unix.fstat fd).Unix.st_kind <> Unix.S_REG then
        Error (path ^ ": not a regular file")
      else Ok (Some (In_channel.input_all channel)))
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
    (match Unix.lstat path with
     | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
       inspect_parent (Filename.dirname path)
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception ((Unix.Unix_error _ | Sys_error _) as exn) ->
       Error (path ^ ": " ^ Printexc.to_string exn)
     | _ -> Error (path ^ ": file target is absent"))
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Unix.Unix_error _ | Sys_error _) as exn -> Error (path ^ ": " ^ Printexc.to_string exn)

let preflight_file ?(allow_missing_ancestors=false) path =
  let result =
    Systhread_host.run ~label:"memory-current-observe-file" (fun () ->
      preflight_file_unix ~allow_missing_ancestors path)
  in
  (match Eio_guard.execution_context () with
   | Eio_guard.Eio_fiber -> Eio.Fiber.check ()
   | Eio_guard.Non_eio -> ());
  result

let quarantine_regular_path path =
  try match (Unix.lstat path).Unix.st_kind with
    | Unix.S_REG -> Ok ()
    | Unix.S_LNK -> Error (path ^ ": snapshot symlink requires manual reconciliation")
    | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
      Error (path ^ ": snapshot is not a regular file")
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Unix.Unix_error _ | Sys_error _) as exn -> Error (path ^ ": " ^ Printexc.to_string exn)

let read_publication ~keepers_dir ~keeper_id =
  let path = publication_receipt_path ~keepers_dir ~keeper_id in
  let* text = preflight_file ~allow_missing_ancestors:true path
    |> Result.map_error (fun detail -> "publication receipt unreadable: " ^ detail) in
  match text with
  | None -> Ok None
  | Some text -> Result.map Option.some (parse_publication text)

let inspect_for_preflight ~keepers_dir ~keeper_id =
  let retraction_path = retraction_plan_receipt_path ~keepers_dir ~keeper_id in
  let* retraction = preflight_file retraction_path in
  let* () =
    match retraction with
    | None -> Ok ()
    | Some text ->
      let+ _ = parse_retraction_plan_receipt ~path:retraction_path text in
      ()
  in
  let publication_path = publication_receipt_path ~keepers_dir ~keeper_id in
  let publication () =
    let* contents = preflight_file publication_path in
    match contents with
    | None -> Ok false
    | Some text ->
      let+ _ = parse_publication text
        |> Result.map_error (fun detail -> publication_path ^ ": " ^ detail) in
      true in
  let* pending = publication () in
  if pending then Ok Preflight_publication_pending
  else
    let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
    let* snapshot = preflight_file path in
    let* pending = publication () in
    if pending then Ok Preflight_publication_pending
    else match snapshot with
      | None -> Ok Preflight_absent
      | Some text -> let+ _ = parse path text in Preflight_snapshot

type boot_observation =
  | Boot_absent
  | Boot_readable
  | Boot_undecodable of { rejection : string; snapshot_sha256 : string }
  | Boot_unreadable of { detail : string }

let inspect_for_boot ~keepers_dir ~keeper_id =
  let publication_path = publication_receipt_path ~keepers_dir ~keeper_id in
  let publication () =
    let* contents = preflight_file publication_path in
    match contents with
    | None -> Ok ()
    | Some _ -> Error (publication_path ^ ": publication recovery is pending") in
  let observed =
    let* () = publication () in
    let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
    let* content = preflight_file path in
    let* () = publication () in
    match content with
    | None -> Ok Boot_absent
    | Some content ->
      (match parse path content with
       | Ok _ -> Ok Boot_readable
       | Error rejection ->
         let+ () = quarantine_regular_path path in
         Boot_undecodable {rejection; snapshot_sha256=sha256 content}) in
  match observed with
  | Ok observation -> observation
  | Error detail -> Boot_unreadable {detail}

let write_publication ~keepers_dir ~keeper_id receipt =
  let json = publication_to_json receipt in
  let* _ = publication_of_json json in
  Fs_compat.save_file_atomic_strict (publication_receipt_path ~keepers_dir ~keeper_id)
    (Yojson.Safe.to_string json)

let remove_publication ~sync_parent ~keepers_dir ~keeper_id =
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    try
      (try Unix.unlink (publication_receipt_path ~keepers_dir ~keeper_id)
       with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
      let fd = Unix.openfile keepers_dir [Unix.O_RDONLY] 0 in
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> sync_parent fd);
      Ok ()
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error ("publication receipt removal failed: " ^ Printexc.to_string exn))

(* Check companion evidence before any recovery mutates a store. Older committed
   consumption identities remain valid, but another prepared transaction cannot
   be silently promoted as this publication. *)
let check_publication_companions ~keepers_dir ~keeper_id receipt =
  let* removal = read_retraction_plan_receipt ~keepers_dir ~keeper_id in
  let* () = match removal with
    | None -> Ok ()
    | Some removal ->
      let* entry = Journal_codec.journal_entry_of_json receipt.journal in
      (match entry with
       | Journal_committed entry when
           receipt.prior = Some (removal.prior_revision, removal.prior_snapshot_sha256)
           && receipt.target_revision = removal.target_revision
           && receipt.target_sha256 = removal.target_snapshot_sha256
           && entry.dropped = Some removal.dropped_statements
           && entry.program = None
           && (match removal.plan_id, entry.source with
               | None, _ -> true
               | Some plan_id, {kind=Explicit_retract; trace_id} -> plan_id = trace_id
               | Some _, { kind = Librarian | Explicit_write; _ } -> false)
           && (match receipt.journal with `Assoc fields ->
                 Journal_codec.journal_revision_links fields = Ok (Some removal.revision_links) | _ -> false) -> Ok ()
       | Journal_failed _ | Journal_quarantined _ | Journal_committed _ -> Error "publication and removal receipts conflict; stores preserved") in
  let* ranges, skipped = read_durable_range_receipts ~keepers_dir ~keeper_id in
  (* Unreadable legacy rows are refused the same way validate_durable_range_
     receipts reports them: recovery must wait until the consume path has
     quarantined them, because an unreadable row can hide a conflicting
     consumption identity. *)
  let* () = match skipped with
    | [] -> Ok ()
    | _ -> Error ("publication and consumption receipts conflict; unreadable range rows path=" ^ durable_range_receipt_path ~keepers_dir ~keeper_id) in
  let* entry = Journal_codec.journal_entry_of_json receipt.journal in
  let* () = match entry with
    | Journal_committed {program=Some publication;_} ->
      let matches range = match publication.boundary, range with
        | Keeper_memory_os_program_types.Atom_boundary boundary,Atom_range range ->
          boundary.receipt_scope=range.receipt_scope && boundary.trace_id=range.trace_id
          && boundary.history_start_boundary_line=range.history_start_boundary_line
          && boundary.start_atom=range.start_atom && boundary.end_atom=range.end_atom
          && boundary.last_atom_digest=range.last_atom_digest
          && boundary.end_boundary_line=range.end_boundary_line
          && boundary.boundary_lines_seen=range.boundary_lines_seen
          && range.unread_messages=publication.execution.program.unread
        | Keeper_memory_os_program_types.Official_boundary boundary,Official_range range ->
          boundary.receipt_scope=range.receipt_scope && boundary.after_boundary_line=range.after_boundary_line
          && List.map (fun (line,turn_ref,_) -> line,turn_ref) boundary.turns=range.turns
          && range.unread_messages=publication.execution.program.unread
        | (Atom_boundary _|Official_boundary _),(Atom_range _|Official_range _|Explicit_candidate _|Explicit_candidate_with_recall _) -> false in
      let target_ranges=List.filter (function
        | Prepared {snapshot_revision;snapshot_sha256;_}|Committed {snapshot_revision;snapshot_sha256;_} ->
          snapshot_revision=receipt.target_revision && snapshot_sha256=receipt.target_sha256) ranges in
      if target_ranges<>[] && List.for_all (fun row -> matches (receipt_range_id row)) target_ranges
      then Ok () else Error "ordered publication and original-boundary receipt conflict; stores preserved"
    | Journal_committed {program=None;_}|Journal_failed _|Journal_quarantined _ -> Ok () in
  List.fold_left (fun result row ->
    let* () = result in
    let valid = match row with
      | Prepared {snapshot_revision; snapshot_sha256; _} ->
        snapshot_revision = receipt.target_revision && snapshot_sha256 = receipt.target_sha256
      | Committed {snapshot_revision; snapshot_sha256; _} ->
        snapshot_revision < receipt.target_revision
        || (snapshot_revision = receipt.target_revision && snapshot_sha256 = receipt.target_sha256) in
    if valid then Ok () else Error "publication and consumption receipts conflict; stores preserved") (Ok ()) ranges

let record_publication_journal ~keepers_dir ~keeper_id receipt =
  let* () = append_journal_line_strict ~keepers_dir ~keeper_id receipt.journal in
  let pending = {receipt with phase=Notification_pending} in
  let+ () = write_publication ~keepers_dir ~keeper_id pending in
  pending

let finalize_publication_journal ~keepers_dir ~keeper_id receipt =
  let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  let* recovered = Fs_compat.recover_private_jsonl_durable_locked_result path
    |> Result.map_error Fs_compat.private_jsonl_transaction_error_to_string in
  let rec scan found = function
    | [] -> Ok found
    | "" :: rest -> scan found rest
    | line :: rest ->
      (match Yojson.Safe.from_string line with
       | json ->
         let* entry = Journal_codec.journal_entry_of_json json in
         (* Revisions restart after a quarantine, so a pre-quarantine entry
            cannot finalize a publication from the current generation. *)
         (match entry with
          | Journal_quarantined _ -> scan false rest
          | Journal_committed _ when Yojson.Safe.sort json = Yojson.Safe.sort receipt.journal ->
            scan true rest
          | Journal_committed _ | Journal_failed _ -> scan found rest)
       | exception Yojson.Json_error detail -> Error ("publication journal: " ^ detail)) in
  let* present = scan false (String.split_on_char '\n' recovered.Fs_compat.bytes) in
  let* () = if present then Ok () else append_journal_line_strict ~keepers_dir ~keeper_id receipt.journal in
  let pending = {receipt with phase=Notification_pending} in
  let+ () = write_publication ~keepers_dir ~keeper_id pending in
  pending

(* Caller owns aggregate and snapshot locks. Inspect the receipt before parsing
   or quarantining a snapshot: an unmatched publication must preserve all bytes. *)
let recover_publication_locked ~sync_parent ~keepers_dir ~keeper_id =
  let* _ = Keeper_librarian_unread_ledger.read ~keepers_dir ~keeper_id in
  let* receipt = read_publication ~keepers_dir ~keeper_id in
  match receipt with
  | None -> Ok None
  | Some receipt ->
    let* () = check_publication_companions ~keepers_dir ~keeper_id receipt in
    let* expected = Journal_codec.journal_entry_of_json receipt.journal in
    let* () = match expected with
      | Journal_committed {program=Some publication;_} ->
        let* epoch = read_epoch ~keepers_dir ~keeper_id in
        if epoch=Some publication.locked_prior.epoch && publication.locked_prior.snapshot=receipt.prior
        then Ok () else Error "ordered publication incarnation/prior binding changed; stores preserved"
      | Journal_committed {program=None;_} | Journal_failed _ | Journal_quarantined _ -> Ok () in
    let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
    let* content = preflight_file path in
    let prior_matches = match receipt.prior, content with
      | None, None -> true
      | Some (_, digest), Some text -> String.equal digest (sha256 text)
      | None, Some _ | Some _, None -> false in
    if receipt.phase = Publication_prepared && prior_matches then
      let* snapshot = match content with
        | None -> Ok None
        | Some text ->
          let* current = parse path text in
          if Option.map fst receipt.prior = Some current.revision then Ok (Some (current, text))
          else Error "publication prior revision conflicts; stores preserved" in
      let* () = reconcile_retraction_plan_receipt ~keepers_dir ~keeper_id ~snapshot in
      (* The target was never published, so the receipts prepared for it
         consumed nothing; the reconcile still moves them aside as it does
         every receipt it drops. *)
      let* _ = reconcile_durable_range_receipts ~keepers_dir ~keeper_id ~snapshot in
      let+ () = remove_publication ~sync_parent ~keepers_dir ~keeper_id in None
    else match content with
      | Some text when String.equal receipt.target_sha256 (sha256 text) ->
        let* current = parse path text in
        let* expected = Journal_codec.journal_entry_of_json receipt.journal in
        let* () = match expected with
          | Journal_committed entry when current.revision = receipt.target_revision
              && current.updated_at = entry.recorded_at && current.source = entry.source
              && current.change = entry.change
              && Option.fold ~none:true ~some:(fun publication ->
                   publication.Keeper_memory_os_program_types.execution.final_facts=current.facts) entry.program -> Ok ()
          | Journal_failed _ | Journal_quarantined _ | Journal_committed _ -> Error "publication target metadata conflicts; stores preserved" in
        let* () = Fs_compat.sync_file_and_parent_strict path in
        let* pending = finalize_publication_journal ~keepers_dir ~keeper_id receipt in
        let snapshot = Some (current, text) in
        let* () = reconcile_retraction_plan_receipt ~keepers_dir ~keeper_id ~snapshot in
        let+ _ = reconcile_durable_range_receipts ~keepers_dir ~keeper_id ~snapshot in
        Some pending
      | None | Some _ -> Error "publication target is absent or conflicting; stores preserved"

let dispatch_publication ~sync_parent ~keepers_dir ~keeper_id receipt =
  Keeper_memory_commit_notifications.notify_committed
    {keepers_dir=Unix.realpath keepers_dir; keeper_id; store=Ordinary; revision=receipt.target_revision};
  Keeper_memory_os_aggregate_lock.with_lock ~keepers_dir ~keeper_id (fun () ->
    File_lock_eio.with_lock (path_for_keepers_dir ~keepers_dir ~keeper_id) (fun () ->
      let* current = read_publication ~keepers_dir ~keeper_id in
      match current with
      | None -> Ok ()
      | Some current when current = receipt -> remove_publication ~sync_parent ~keepers_dir ~keeper_id
      | Some _ -> Error "publication changed during notification dispatch; receipt preserved"))

let recover_publication_with_sync ~sync_parent ~keepers_dir ~keeper_id =
  let* existing = read_publication ~keepers_dir ~keeper_id in
  match existing with
  | None -> Ok ()
  | Some _ ->
  let* pending = Keeper_memory_os_aggregate_lock.with_lock ~keepers_dir ~keeper_id (fun () ->
    File_lock_eio.with_lock (path_for_keepers_dir ~keepers_dir ~keeper_id) (fun () ->
      recover_publication_locked ~sync_parent ~keepers_dir ~keeper_id)) in
  match pending with
  | None ->
    (* The target was never published: the receipt is gone and the
       retraction plan is reconciled, perhaps with a removal line. No commit
       notification follows, so the row's readers are told here (RFC-0487). *)
    Keeper_memory_health_input.written ~keepers_dir ~keeper_id;
    Ok ()
  | Some receipt -> dispatch_publication ~sync_parent ~keepers_dir ~keeper_id receipt

let recover_publication ~keepers_dir ~keeper_id =
  recover_publication_with_sync ~sync_parent:Unix.fsync ~keepers_dir ~keeper_id
