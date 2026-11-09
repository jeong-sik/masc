(** Keeper-owned current Memory OS snapshot. *)

open Keeper_memory_os_types
open Result.Syntax

module Snapshot_codec = Keeper_memory_os_snapshot_codec
module Journal_codec = Keeper_memory_os_journal_codec
module Successor_recall = Keeper_memory_os_successor_recall
module Receipt_selection = Keeper_memory_os_receipt_selection

include Keeper_memory_os_current_types
open Keeper_memory_os_support_core
include Keeper_memory_os_current_layout
include Keeper_memory_os_current_range_codec
include Keeper_memory_os_current_receipt_store
include Keeper_memory_os_current_journal
include Keeper_memory_os_current_retraction_plan

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
  try
    let result =
      Systhread_host.run ~label:"memory-current-observe-file" (fun () ->
        preflight_file_unix ~allow_missing_ancestors path)
    in
    (match Eio_guard.execution_context () with
     | Eio_guard.Eio_fiber -> Eio.Fiber.check ()
     | Eio_guard.Non_eio -> ());
    result
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Systhread_host.Host_failed exn ->
    Error (path ^ ": observation worker failed: " ^ Printexc.to_string exn)

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

let with_program_reset ~keepers_dir ~keeper_id remove =
  Fs_compat.mkdir_p keepers_dir;
  let* () = recover_publication ~keepers_dir ~keeper_id in
  Keeper_memory_os_aggregate_lock.with_lock ~keepers_dir ~keeper_id (fun () ->
    File_lock_eio.with_lock (path_for_keepers_dir ~keepers_dir ~keeper_id) (fun () ->
      let* pending=read_publication ~keepers_dir ~keeper_id in
      let* ()=match pending with
        | None -> Ok ()
        | Some _ -> Error "Memory publication became pending before reset; retry recovery" in
      let* _ = rotate_epoch ~keepers_dir ~keeper_id in
      remove ()))

let read_with_content ~keepers_dir ~keeper_id =
  let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  try
    let* () = recover_publication ~keepers_dir ~keeper_id in
    let* () = publication_read_guard ~keepers_dir ~keeper_id in
    let observed = match Fs_compat.load_file_opt snapshot_path with
    | None -> Ok None
    | Some content ->
      let+ snapshot = parse snapshot_path content in
      Some (snapshot, content) in
    let* () = publication_read_guard ~keepers_dir ~keeper_id in
    observed
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error message ->
    Error
      (Printf.sprintf
         "current Memory OS read failed path=%s: %s"
         snapshot_path
         message)
;;

let read_locked_for_keepers_dir ~keepers_dir ~keeper_id =
  let* () = publication_read_guard ~keepers_dir ~keeper_id in
  let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  match Fs_compat.load_file_opt path with
  | None -> Ok None
  | Some text -> Result.map Option.some (parse path text)
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
      | json -> offset, Journal_codec.journal_entry_of_json json
      | exception Yojson.Json_error message ->
        offset, Error (Printf.sprintf "journal line is not valid JSON: %s" message)))
;;

let read_journal_tail ~keepers_dir ~keeper_id ~limit =
  read_journal_tail_indexed ~keepers_dir ~keeper_id ~limit |> List.map snd
;;

type removal_lookup =
  | Removed of removal
  | No_removal_recorded
  | Journal_unreadable of string

type program_anchor =
  { anchor_keeper : string
  ; anchor_snapshot : t option
  ; anchor_identity : Keeper_memory_os_program_types.store_anchor
  }

let program_anchor_snapshot anchor = anchor.anchor_snapshot

let program_journal_bytes ~keepers_dir ~keeper_id =
  let+ journal = Fs_compat.read_private_jsonl_durable_locked_result
    (journal_path_for_keepers_dir ~keepers_dir ~keeper_id) ~after:None
    |> Result.map_error Fs_compat.private_jsonl_transaction_error_to_string in
  journal.Fs_compat.bytes

let decode_program_journal bytes =
  let rec decode acc = function
    | [] -> Ok (List.rev acc)
    | "" :: rest -> decode acc rest
    | line :: rest ->
      (match Yojson.Safe.from_string line with
       | json ->
         let* entry = Journal_codec.journal_entry_of_json json in
         decode ((json,entry)::acc) rest
       | exception Yojson.Json_error detail -> Error ("program journal: " ^ detail))
  in
  if bytes <> "" && bytes.[String.length bytes - 1] <> '\n'
  then Error "program journal prefix is incomplete"
  else decode [] (String.split_on_char '\n' bytes)

let store_anchor ~epoch ~snapshot ~bytes =
  ({epoch; snapshot; journal_length=String.length bytes; journal_sha256=sha256 bytes}
    : Keeper_memory_os_program_types.store_anchor)

let capture_program_anchor ~keepers_dir ~keeper_id =
  Fs_compat.mkdir_p keepers_dir;
  let* () = recover_publication ~keepers_dir ~keeper_id in
  Keeper_memory_os_aggregate_lock.with_lock ~keepers_dir ~keeper_id (fun () ->
    File_lock_eio.with_lock (path_for_keepers_dir ~keepers_dir ~keeper_id) (fun () ->
      let* () = publication_read_guard ~keepers_dir ~keeper_id in
      let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
      let* snapshot = match Fs_compat.load_file_opt path with
        | None -> Ok None
        | Some bytes -> let+ current = parse path bytes in Some (current,sha256 bytes) in
      let* epoch = ensure_epoch ~keepers_dir ~keeper_id in
      let* bytes = program_journal_bytes ~keepers_dir ~keeper_id in
      let* _ = decode_program_journal bytes in
      Ok {anchor_keeper=keeper_id; anchor_snapshot=Option.map fst snapshot;
        anchor_identity=store_anchor ~epoch
          ~snapshot:(Option.map (fun (current,digest) -> current.revision,digest) snapshot) ~bytes}))

let verify_program_anchor ~keepers_dir ~keeper_id anchor ~snapshot_content previous program =
  let module P = Keeper_memory_os_program_types in
  let* epoch = read_epoch ~keepers_dir ~keeper_id in
  let* () = if anchor.anchor_keeper=keeper_id && epoch=Some anchor.anchor_identity.epoch then Ok ()
    else Error "Memory program incarnation changed since inference" in
  let* () =
    if program.P.initial_current = Option.map (fun (snapshot : t) -> snapshot.facts) anchor.anchor_snapshot
    then Ok () else Error "Memory program did not judge its captured full snapshot" in
  let* bytes = program_journal_bytes ~keepers_dir ~keeper_id in
  let original = anchor.anchor_identity in
  let* () =
    if String.length bytes >= original.journal_length
       && sha256 (String.sub bytes 0 original.journal_length) = original.journal_sha256 then Ok ()
    else Error "Memory program journal prefix changed or disappeared" in
  let* suffix = decode_program_journal
    (String.sub bytes original.journal_length (String.length bytes-original.journal_length)) in
  let initial_ids = Set_util.StringSet.of_list
    (List.map memory_id (Option.fold ~none:[] ~some:Fun.id program.initial_current)) in
  let first_revision = Option.fold ~none:0 ~some:fst original.snapshot in
  let table facts = List.fold_left (fun values fact ->
    Identity_map.add (memory_id fact) (fact_payload fact) values) Identity_map.empty facts in
  let initial_facts = Option.fold ~none:[] ~some:(fun (current : t) -> current.facts) anchor.anchor_snapshot in
  let rec verify revision values last_rewrite = function
    | [] ->
      let current_revision=Option.fold ~none:0 ~some:(fun (current : t) -> current.revision) previous in
      if revision<>current_revision then Error "Memory program journal lacks the locked snapshot transition"
      else if not (Identity_map.equal String.equal values
        (table (Option.fold ~none:[] ~some:(fun (current : t) -> current.facts) previous)))
      then Error "Memory program journal facts differ from the locked snapshot"
      else
        (match last_rewrite,previous,snapshot_content with
         | None,_,_ ->
           let actual=match previous,snapshot_content with
             | None,None -> None | Some current,Some bytes -> Some (current.revision,sha256 bytes)
             | None,Some _ | Some _,None -> None in
           if actual=original.snapshot then Ok () else Error "captured Memory bytes changed without a rewrite"
         | Some (recorded_at,source,change),Some current,Some _
           when recorded_at=current.updated_at && source=current.source && change=current.change -> Ok ()
         | Some _,(None|Some _),(None|Some _) -> Error "Memory journal endpoint metadata differs from its snapshot")
    | (_,Journal_failed _) :: rest -> verify revision values last_rewrite rest
    | (_,Journal_quarantined _) :: _ -> Error "Memory was quarantined after the program captured its input"
    | (json,Journal_committed entry) :: rest ->
      let* observed_effect = match json with
        | `Assoc fields -> Journal_codec.journal_commit_effect fields
        | _ -> Error "program journal commit is not an object" in
      let* next_revision,next_values,last_rewrite = match observed_effect with
        | Some Rewritten when entry.revision=revision+1 ->
          let* remaining = List.fold_left (fun result fact ->
            let* values=result in
            let identity=memory_id fact in
            if Identity_map.find_opt identity values=Some (fact_payload fact)
            then Ok (Identity_map.remove identity values)
            else Error "Memory journal removal does not match its prior payload") (Ok values) entry.change.removed in
          let* after = List.fold_left (fun result fact ->
            let* values=result in let identity=memory_id fact in
            if Identity_map.mem identity values then Error "Memory journal addition overwrites an unremoved fact"
            else Ok (Identity_map.add identity (fact_payload fact) values)) (Ok remaining) entry.change.added in
          if entry.change.retained<>Identity_map.cardinal remaining
          then Error "Memory journal retained count conflicts with the captured state"
          else Ok (entry.revision,after,Some (entry.recorded_at,entry.source,entry.change))
        | Some Unchanged when entry.revision=revision
            && entry.change.added=[] && entry.change.removed=[] -> Ok (revision,values,last_rewrite)
        | Some (Rewritten | Unchanged) | None -> Error "Memory program history has a gap or reused revision" in
      let touched=Option.fold ~none:[] ~some:Keeper_memory_os_program_publication.touched_ids entry.program in
      if List.exists (fun identity -> Set_util.StringSet.mem identity initial_ids)
        (retired_identities entry.change@touched)
      then Error "Memory program input identity was retired, rewritten or recreated after inference"
      else verify next_revision next_values last_rewrite rest
  in
  let* () = verify first_revision (table initial_facts) None suffix in
  let snapshot = match previous,snapshot_content with
    | None,None -> None
    | Some current,Some bytes -> Some (current.revision,sha256 bytes)
    | None,Some _ | Some _,None -> None in
  Ok (store_anchor ~epoch:original.epoch ~snapshot ~bytes)

type journal_mention =
  | Mentioned_as_current
  | Mentioned_as_removed of removal
  | Mention_unreadable of string

(* Newest line first: the latest committed line that names the identity
   decides. A line that adds it (a re-observation lists it on both sides)
   leaves it current after that line, so no removal is reported. An unreadable
   newer line stops the search: it may replace the authority an older removal
   would otherwise grant. An identity no line names is scanned to the start
   of the file, decoding every line, so the scan runs as one pool job, as the
   tail reader above does. *)
let drop_reason_for ~(dropped : dropped_statement list option)
    ~(program : Keeper_memory_os_program_types.publication option) fact =
  let identity=memory_id fact in
  let reason statements=List.find_map (fun (drop : dropped_statement) ->
    if drop.memory_id=identity then Some drop.reason else None) statements in
  match program with
  | None -> Option.bind dropped reason
  | Some publication ->
    let rec original_occurrence = function
      | [] -> None
      | (stage : Keeper_memory_os_program_types.stage) :: rest ->
        if List.exists (fun held -> memory_id held=identity) stage.before
           && not (List.exists (fun held -> memory_id held=identity) stage.after)
        then reason stage.decision.dropped
        else original_occurrence rest
    in
    (* Only the first retirement of the original durable occurrence explains
       the outer removed fact. A later virtual reincarnation's reason cannot
       repaint it. Virtual-only facts never enter change.removed. *)
    if List.exists (fun held -> fact_payload held=fact_payload fact) publication.execution.initial_facts
    then original_occurrence publication.execution.stages else None

let find_removal ~keepers_dir ~keeper_id target =
  let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  let is_target fact = String.equal (Keeper_memory_os_types.memory_id fact) target in
  let mention = function
    | Dated_jsonl.Malformed_json { path; detail; line_number = _ } ->
      Some (Mention_unreadable (Printf.sprintf "memory journal %s: %s" path detail))
    | Dated_jsonl.Parsed json ->
      (match Journal_codec.journal_entry_of_json json with
       | Ok (Journal_committed { recorded_at; revision; source; change; dropped; program }) ->
         if List.exists is_target change.added
         then Some Mentioned_as_current
         else (
           match List.find_opt is_target change.removed with
           | Some (removed : Keeper_memory_os_types.fact) ->
             Some
               (Mentioned_as_removed
                  { removed_in_revision = revision
                  ; removed_at = recorded_at
                  ; removed_by = source
                  ; removed_origin = removed.origin.kind
                  ; drop_reason = drop_reason_for ~dropped ~program removed
                  })
           | None -> None)
       | Ok (Journal_failed _ | Journal_quarantined _) -> None
       | Error detail ->
         Some (Mention_unreadable (Printf.sprintf "memory journal %s: %s" path detail)))
  in
  if not (Sys.file_exists path)
  then No_removal_recorded
  else (
    match
      Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
        Dated_jsonl.find_latest_entry_in_file_result path mention)
    with
    | Ok (Some (Mentioned_as_removed removal)) -> Removed removal
    | Ok (Some Mentioned_as_current | None) -> No_removal_recorded
    | Ok (Some (Mention_unreadable detail)) -> Journal_unreadable detail
    | Error error -> Journal_unreadable (Dated_jsonl.read_error_to_string error))
;;

type archived_fact =
  { original : Keeper_memory_os_types.fact
  ; removal : removal
  }

let read_dropped ~keepers_dir ~keeper_id ~current_facts =
  let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    let* receipt = read_retraction_plan_receipt ~keepers_dir ~keeper_id in
    let* () =
      match receipt with
      | None -> Ok ()
      | Some receipt ->
        Error
          (Printf.sprintf
             "memory archive journal finalization pending keeper=%s target_revision=%d; a writer must reconcile the preserved removal before the archive can be read"
             keeper_id
             receipt.target_revision)
    in
    let seen = ref (Set_util.StringSet.of_list (List.map memory_id current_facts)) in
    let archived = ref [] in
    let visit = function
      | Dated_jsonl.Malformed_json { detail; _ } -> Some detail
      | Dated_jsonl.Parsed json ->
        match Journal_codec.journal_entry_of_json json with
        | Error detail -> Some detail
        | Ok (Journal_failed _ | Journal_quarantined _) -> None
        | Ok (Journal_committed { recorded_at; revision; source; change; dropped; program }) ->
          (* Additions in the same commit win, matching find_removal. Latest
             mentions suppress older removals even when their reason is absent. *)
          List.iter (fun fact -> seen := Set_util.StringSet.add (memory_id fact) !seen)
            change.added;
          List.iter
            (fun fact ->
               let identity = memory_id fact in
               if not (Set_util.StringSet.mem identity !seen) then (
                 seen := Set_util.StringSet.add identity !seen;
                 let reason = drop_reason_for ~dropped ~program fact in
                 match reason with
                 | None -> ()
                 | Some reason ->
                   archived :=
                     { original = fact
                     ; removal =
                         { removed_in_revision = revision
                         ; removed_at = recorded_at
                         ; removed_by = source
                         ; removed_origin = fact.origin.kind
                         ; drop_reason = Some reason
                         }
                     } :: !archived))
            change.removed;
          None
    in
    match Unix.lstat path with
    | _ ->
      (match Dated_jsonl.find_latest_entry_in_file_result path visit with
       | Ok None -> Ok (List.rev !archived)
       | Ok (Some detail) -> Error detail
       | Error error -> Error (Dated_jsonl.read_error_to_string error))
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
    | exception Unix.Unix_error (code, fn, arg) ->
      Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)))
;;

type retirement_context =
  | Retirement_source_changed
  | Retirement_source_unavailable of string
  | Retirement_archive of (archived_fact list, string) result

let read_retirement_context ~keepers_dir ~keeper_id ~expected_revision ~current_facts =
  try
    let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
    Keeper_memory_os_aggregate_lock.with_lock ~keepers_dir ~keeper_id (fun () ->
      File_lock_eio.with_lock path (fun () ->
        match read_classified ~keepers_dir ~keeper_id with
        | Readable snapshot when Some snapshot.revision = expected_revision
            && snapshot.facts = current_facts ->
            Retirement_archive (read_dropped ~keepers_dir ~keeper_id ~current_facts)
        | No_snapshot when expected_revision = None && current_facts = [] ->
            Retirement_archive (read_dropped ~keepers_dir ~keeper_id ~current_facts)
        | Undecodable {rejection} when expected_revision = None && current_facts = [] ->
            Retirement_archive (Error rejection)
        | Readable _ | No_snapshot | Undecodable _ -> Retirement_source_changed
        | Io_unreadable {detail} -> Retirement_source_unavailable detail))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Retirement_source_unavailable (Printexc.to_string exn)
;;

(* The targets some committed line newer than [revision] removed without
   adding back in the same line. Read newest first and stopped at the first
   line at or below [revision], so it costs the commits since the decision,
   not the journal's length. [None] reads every line: the decision saw no
   snapshot. [held] is the revision of the snapshot the caller holds locked.
   Once Memory moved after the decision, an empty set is a proof only if the
   journal holds a rewriting line for every revision in between: a commit
   without drop reasons appends its line best-effort, so a lost line can hide
   a removal that a later line adds back. Revisions restart after a
   quarantine, so a quarantine in that window ends the proof too. Caller holds
   the aggregate and snapshot locks, as for [read_dropped]. *)
let targets_retired_since ~keepers_dir ~keeper_id ~revision ~held targets =
  let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  (* Snapshot revisions start at 1, so 0 stands for no snapshot. *)
  let decided = Option.value revision ~default:0 in
  let held = Option.value held ~default:0 in
  let moved = held > decided in
  let retired = ref Set_util.StringSet.empty in
  let rewritten = ref Recall_revision_set.empty in
  let newer line_revision = match revision with
    | None -> true
    | Some decided -> line_revision > decided in
  let visit = function
    | Dated_jsonl.Malformed_json { detail; _ } -> Some (Error detail)
    | Dated_jsonl.Parsed json ->
      match Journal_codec.journal_entry_of_json json with
      | Error detail -> Some (Error detail)
      | Ok (Journal_failed _) -> None
      | Ok (Journal_quarantined _) ->
        if moved
        then Some (Error "a quarantine restarted Memory revisions after the admission decision")
        else None
      | Ok (Journal_committed { revision = line_revision; change; program; _ }) ->
        if not (newer line_revision) then Some (Ok ())
        else if moved && line_revision > held then
          Some (Error (Printf.sprintf
            "journal revision %d is ahead of the locked snapshot revision %d"
            line_revision held))
        else (
          if line_revision > decided && Journal_codec.journal_line_rewrote json then
            rewritten := Recall_revision_set.add line_revision !rewritten;
          List.iter (fun identity ->
            if Set_util.StringSet.mem identity targets then retired := Set_util.StringSet.add identity !retired)
            (retired_identities change);
          Option.iter (fun proof -> List.iter (fun identity ->
            if Set_util.StringSet.mem identity targets then retired := Set_util.StringSet.add identity !retired)
            (Keeper_memory_os_program_publication.touched_ids proof)) program;
          None) in
  (* Lines above [held] were refused and the scan stopped at the decision, so
     the count proves each revision in between. *)
  let proven () =
    if (not moved) || Recall_revision_set.cardinal !rewritten = held - decided
    then Ok !retired
    else
      Error (Printf.sprintf
        "journal lacks a Memory revision between the admission decision %d and the locked snapshot %d"
        decided held) in
  if held < decided then
    Error (Printf.sprintf
      "the locked snapshot revision %d is behind the admission decision %d" held decided)
  else
    match Unix.lstat path with
    | _ ->
      (match Dated_jsonl.find_latest_entry_in_file_result path visit with
       | Ok (None | Some (Ok ())) -> proven ()
       | Ok (Some (Error detail)) -> Error detail
       | Error error -> Error (Dated_jsonl.read_error_to_string error))
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> proven ()
    | exception Unix.Unix_error (code, fn, arg) ->
      Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))
;;

(* An exact retraction batch: its plan id and the error that reports pending
   journal evidence for the snapshot it wrote. *)
type 'error retraction_plan =
  string
  * (plan_id:string -> snapshot_revision:int -> snapshot_sha256:string -> detail:string -> 'error)

(* What a commit does when its facts equal the stored ones. A Librarian pass
   keeps the stored snapshot. An explicit write still writes a revision: its
   caller reads the returned [change] as what that write did, and the keeper
   stamps [last_seen] with the write time, so an equal set does not arise
   from it in practice. A retraction plan is an explicit write, so a kept
   pass never carries one. *)
type 'error equal_facts =
  | Keep_stored
  | Write_revision of 'error retraction_plan option

(* Caller holds the aggregate and snapshot locks. Both boot and ordinary
   writers must move the removal receipt with an undecodable snapshot. *)
let quarantine_snapshot_and_receipt ~keepers_dir ~keeper_id ~snapshot_path ~now ~rejection =
  let* publication = read_publication ~keepers_dir ~keeper_id in
  let* () = match publication with
    | None -> Ok ()
    | Some _ -> Error "publication evidence is pending; snapshot quarantine refused" in
  let* _ = rotate_epoch ~keepers_dir ~keeper_id in
  let move path =
    let rejected_path = unused_rejected_path ~snapshot_path:path ~now in
    match Fs_compat.rename_noreplace path rejected_path with
    | () -> Ok rejected_path
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn ->
      Error
        (Printf.sprintf
           "current Memory OS file could not be moved aside path=%s rejected_path=%s: %s (rejected: %s)"
           path
           rejected_path
           (Printexc.to_string exn)
           rejection)
  in
  (* A receipt and its target snapshot carry one pending removal. Move
     the receipt first: interruption then leaves the rejected snapshot
     to refuse boot again, instead of an active receipt whose snapshot
     has disappeared. Preserve raw bytes; a rejected snapshot cannot
     prove either receipt hash, so it cannot authorize reconciliation. *)
  let receipt_path = retraction_plan_receipt_path ~keepers_dir ~keeper_id in
  let* moved_receipt =
    match Fs_compat.exact_path_kind ~follow:false receipt_path with
    | Fs_compat.Exact_missing -> Ok None
    | Fs_compat.Exact_kind _ ->
      let+ rejected_receipt_path = move receipt_path in
      Log.Keeper.warn
        ~keeper_name:keeper_id
        "memory removal receipt quarantined path=%s rejected_path=%s"
        receipt_path
        rejected_receipt_path;
      Some rejected_receipt_path
    | Fs_compat.Exact_unknown ->
      Error
        (Printf.sprintf
           "current Memory OS removal receipt could not be inspected path=%s; snapshot was not moved"
           receipt_path)
  in
  match move snapshot_path with
  | Ok rejected_path ->
    append_snapshot_quarantine ~keepers_dir ~keeper_id ~now ~rejection ~rejected_path;
    Ok rejected_path
  | Error detail ->
    Error
      (match moved_receipt with
       | None -> detail
       | Some rejected_receipt_path ->
         Printf.sprintf
           "%s; removal receipt is preserved at %s and the rejected snapshot stays in place"
           detail
           rejected_receipt_path)
;;

let update_locked_with_output
      ?(write_snapshot = Fs_compat.save_file_atomic_strict_staged)
      ?(sync_snapshot = Fs_compat.sync_file_and_parent_strict)
      ?(finalize_journal = record_publication_journal)
      ?on_committed
      ?program_of_output
      ?observe_output
      ?clock
      ?dropped_statements
      ?before_replace
      ?(declared_revisions = [])
      ?durable_range_id
      ?official_range_id
      ?(explicit_candidate_ids = [])
      ?admission_recall
      ~equal_facts
      ~store_error
      ~keepers_dir
      ~keeper_id
      ~now
      build
  =
  let retraction_plan =
    match equal_facts with
    | Keep_stored -> None
    | Write_revision plan -> plan
  in
  let admission_recall_bindings = match admission_recall with
    | None -> []
    | Some recall -> recall.bindings in
  let* () =
    match durable_range_id with
    | None -> Ok ()
    | Some range ->
      durable_range_id_of_json (durable_range_id_to_json range)
      |> Result.map (fun _ -> ())
      |> Result.map_error (fun error -> store_error (wire_error_to_string error))
  in
  let* () =
    match official_range_id with
    | None -> Ok ()
    | Some range ->
      official_range_id_of_json (official_range_id_to_json range)
      |> Result.map (fun _ -> ())
      |> Result.map_error (fun error -> store_error (wire_error_to_string error))
  in
  let* () = List.fold_left (fun result candidate ->
    let* () = result in
    explicit_candidate_id_of_json (explicit_candidate_id_to_json candidate)
    |> Result.map ignore
    |> Result.map_error (fun error -> store_error (wire_error_to_string error)))
    (Ok ()) explicit_candidate_ids in
  let* () = List.fold_left (fun result binding ->
    let* () = result in
    admission_recall_binding_of_json (admission_recall_binding_to_json binding)
    |> Result.map ignore
    |> Result.map_error (fun error -> store_error (wire_error_to_string error)))
    (Ok ()) admission_recall_bindings in
  let* () = validate_unique_explicit_candidates
    (List.map (fun binding -> binding.candidate_id) admission_recall_bindings)
    |> Result.map_error store_error in
  let* () = Journal_codec.revision_links_of_json (Journal_codec.revision_links_to_json declared_revisions)
    |> Result.map ignore |> Result.map_error store_error in
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
    let* _ = Keeper_librarian_unread_ledger.read ~keepers_dir ~keeper_id
      |> Result.map_error store_error in
    Fs_compat.mkdir_p keepers_dir;
    let* () = recover_publication ~keepers_dir ~keeper_id |> Result.map_error store_error in
    let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
    let committed = ref None in
    let notify () =
      Option.iter (fun receipt ->
        match dispatch_publication ~sync_parent:Unix.fsync ~keepers_dir ~keeper_id receipt with
        | Ok () -> ()
        | Error detail -> Log.Keeper.warn ~keeper_name:keeper_id "%s" detail) !committed
    in
    let write () = Keeper_memory_os_aggregate_lock.with_lock
      ?clock
      ~keepers_dir
      ~keeper_id
      (fun () ->
       (* File_lock_eio.with_lock appends ".lock" itself; a pre-suffixed path
          locked "<snapshot>.lock.lock" and left a stray file per keeper. *)
       File_lock_eio.with_lock ?clock snapshot_path (fun () ->
         let* _ = Keeper_librarian_unread_ledger.read ~keepers_dir ~keeper_id
           |> Result.map_error store_error in
         let* pending = read_publication ~keepers_dir ~keeper_id |> Result.map_error store_error in
         let* () = match pending with
           | None -> Ok ()
           | Some _ -> Error (store_error "another publication is pending; retry recovery before writing") in
         let* _ = ensure_epoch ~keepers_dir ~keeper_id |> Result.map_error store_error in
         let* previous, snapshot_content =
           match Fs_compat.load_file_opt snapshot_path with
           | None -> Ok (None, None)
           | Some content ->
             (match
                Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
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
                let* rejected_path =
                  quarantine_snapshot_and_receipt
                    ~keepers_dir ~keeper_id ~snapshot_path ~now ~rejection
                  |> Result.map_error store_error
                in
                Log.Keeper.warn
                  ~keeper_name:keeper_id
                  "memory os snapshot quarantined rejected_path=%s rejection=%s"
                  rejected_path
                  rejection;
                Ok (None, None))
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
         let* archived = Keeper_librarian_unread_ledger.read ~keepers_dir ~keeper_id
           |> Result.map_error store_error in
         let additions =
           Option.fold ~none:[] ~some:(fun (range : durable_range_id) -> range.unread_messages) durable_range_id
           @ Option.fold ~none:[] ~some:(fun (range : official_range_id) -> range.unread_messages) official_range_id in
         let* _ = Keeper_librarian_unread.merge archived additions
           |> Result.map_error store_error in
         let* () =
           let consumed = List.filter_map (function
             | Committed {range_id; _} -> consumed_candidate range_id
             | Prepared _ -> None) durable_range_receipts in
           validate_unique_explicit_candidates (consumed @ explicit_candidate_ids)
           |> Result.map_error store_error
         in
         let* next, output = build ~snapshot_content previous in
         let* program = match program_of_output with
           | None -> Ok None
           | Some convert ->
             let* publication = Keeper_memory_os_program_publication.of_json
               (Keeper_memory_os_program_publication.to_json (convert output))
               |> Result.map_error store_error in
             if publication.execution.final_facts=next.facts
                && publication.execution.initial_facts=Option.fold ~none:[] ~some:(fun (prior : t) -> prior.facts) previous
                && publication.locked_prior.snapshot=Option.map (fun (prior,bytes) -> prior.revision,sha256 bytes) snapshot
             then Ok (Some publication)
             else Error (store_error "ordered publication proof does not match the locked snapshot transition") in
         let observe snapshot commit_effect =
           Option.iter (fun notify -> notify snapshot commit_effect) on_committed;
           Option.iter (fun notify -> notify snapshot commit_effect output) observe_output in
         let applied_revision_links = List.filter (fun link ->
           Journal_codec.links_applied_to_snapshot next [link]
           && Option.fold ~none:false ~some:(fun (prior : t) ->
             List.exists (fun fact -> memory_id fact = link.superseded) prior.facts) previous)
           declared_revisions in
         let* () = List.fold_left (fun result binding ->
           let* () = result in
           if not (List.mem binding.candidate_id explicit_candidate_ids) then
             Error (store_error "recall binding does not name a consumed candidate")
           else if not (List.exists (fun fact ->
             String.equal (memory_id fact) binding.target_memory_id) next.facts) then
             Error (store_error "recall binding target is absent from final Memory")
           else Ok ()) (Ok ()) admission_recall_bindings in
         (* [memory_id] hashes the claim text, so presence alone accepts a
            target the keeper retracted and re-added while the decision ran,
            and the binding would be born on the new incarnation after the
            retirement its readers look for. A target retired after the
            revision the decision read refuses the commit, and so does a
            journal that cannot show every revision written since; the input
            stays pending for a decision on current Memory. *)
         let* () = match admission_recall with
           | None | Some { bindings = []; _ } -> Ok ()
           | Some { decided_at_revision; bindings } ->
             let targets = Set_util.StringSet.of_list
               (List.map (fun binding -> binding.target_memory_id) bindings) in
             (match targets_retired_since ~keepers_dir ~keeper_id
                      ~revision:decided_at_revision
                      ~held:(Option.map (fun (current : t) -> current.revision) previous)
                      targets with
              | Error detail -> Error (store_error ("recall binding retirement check: " ^ detail))
              | Ok retired when Set_util.StringSet.is_empty retired -> Ok ()
              | Ok _ ->
                Error (store_error
                  "recall binding target was retired after the admission decision read Memory")) in
         let* source_lines =
           match
             Keeper_memory_source_current.read_for_keepers_dir
               ~keepers_dir
               ~keeper_id
           with
           | Error message -> Error (store_error message)
           | Ok snapshot -> Ok (Keeper_memory_source_current.budget_lines snapshot)
         in
         let previous_bytes =
           Keeper_memory_os_render.facts_payload_bytes
             ~ordinary_facts:
               (Option.fold ~none:[] ~some:(fun (snapshot : t) -> snapshot.facts) previous)
             ~source_lines
         in
         let* () =
           Keeper_memory_os_render.check_facts_budget
             ~previous_bytes
             ~ordinary_facts:next.facts
             ~source_lines
           |> Result.map_error store_error
         in
         let ranges =
           Option.to_list (Option.map (fun range -> Atom_range range) durable_range_id)
           @ Option.to_list (Option.map (fun range -> Official_range range) official_range_id)
           @ List.map (fun candidate ->
               match List.find_opt (fun binding -> binding.candidate_id = candidate) admission_recall_bindings with
               | None -> Explicit_candidate candidate
               | Some binding -> Explicit_candidate_with_recall binding) explicit_candidate_ids
         in
         let receipts_for make =
           List.fold_left (fun receipts range_id ->
             upsert_durable_range_receipt receipts (make range_id)) durable_range_receipts ranges
         in
         (* Locks and preparation remain cancellable. Once the pass starts to
            settle, retain its result and publish its evidence before
            cancellation can interrupt the journal/receipt writes for it. *)
         let protected settle =
           match Eio_guard.execution_context () with
           | Eio_guard.Non_eio -> settle ()
           | Eio_guard.Eio_fiber -> Eio.Cancel.protect settle
         in
         let log_invalidations ~revision =
           List.iter
             (fun invalidation ->
                Log.Keeper.info
                  "memory os support retracted keeper=%s revision=%d memory_id=%s missing_premise_ids=%s"
                  keeper_id
                  revision
                  (memory_id invalidation.fact)
                  (String.concat "," invalidation.missing_premise_ids))
             next.change.invalidated
         in
         (* A Librarian pass whose facts serialize to the stored ones, in the
            same order, changes nothing a reader of this store can see. Writing
            it anyway minted a revision, printed and replaced the whole file and
            woke every commit subscriber: on 2026-09-29, 1,600 of the 2,379
            Librarian commits (67%) added and removed nothing. Such a pass keeps
            the stored snapshot with its revision, bytes and [updated_at]. The
            comparison runs on the pool for the reason the print below does. *)
         let kept =
           match equal_facts, snapshot with
           | Write_revision _, (Some _ | None) | Keep_stored, None -> None
           | Keep_stored, Some (current, current_content) when program=None ->
             (* A kept fact is the stored value itself, so it compares without
                serializing; only a different value or count needs the bytes. *)
             let same_facts =
               Int.equal (List.compare_lengths current.facts next.facts) 0
               && Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
                 List.equal
                   (fun left right ->
                      left == right
                      || String.equal (fact_payload left) (fact_payload right))
                   current.facts
                   next.facts)
             in
             if same_facts then Some (current, current_content) else None
           | Keep_stored, Some _ -> None
         in
         match kept with
         | Some (current, current_content) ->
           (* [before_replace] still runs: it records what the pass did with its
              absorptions and claims, and with the same facts it has no row to
              write. *)
           let* () =
             match before_replace with
             | None -> Ok ()
             | Some write -> write ~previous ~next
           in
           let snapshot_sha256 = sha256 current_content in
           protected (fun () ->
             let+ () =
               match ranges with
               | [] -> Ok ()
               | _ :: _ ->
                 write_durable_range_receipts ~keepers_dir ~keeper_id
                   (receipts_for (fun range_id ->
                      Committed
                        { range_id; snapshot_revision = current.revision; snapshot_sha256 }))
                 |> Result.map_error store_error
             in
             observe current Unchanged;
             (* The journal keeps one line per pass: the Librarian health view
                reads its newest Librarian line as the last success. This line
                names the revision that stays current. *)
             append_journal_entry
               ~commit_effect:Unchanged
               ~revision_links:[]
               ~keepers_dir
               ~keeper_id
               ~dropped_statements:
                 (Option.map (dropped_by_commit ~previous ~next) dropped_statements)
               { next with revision = current.revision };
             log_invalidations ~revision:current.revision;
             current, Unchanged, output)
         | None ->
         (* The file is 150-330 KB per keeper and every commit reads it, parses
            it, prints it and replaces it. On the scheduler domain that was one
            11-24 ms run per commit (rtev, 2026-09-16), about 80 commits an
            hour across the fleet; for the 330 KB file the parse is 2.6 ms and
            the print 5.4 ms. Both are pure over immutable values, so they run
            in pool jobs. The locks are held across the wait, which delays
            another writer of this same keeper's memory and nothing else. *)
         let content =
           Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
             Snapshot_codec.snapshot_bytes next)
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
         let committed_dropped =
           Option.map (dropped_by_commit ~previous ~next) dropped_statements
         in
         let* () =
           match retraction_plan with
           | None -> Ok ()
           | Some (plan_id, _) ->
             (match next.source with
              | { kind = Explicit_retract; trace_id }
                when String.equal trace_id plan_id -> Ok ()
              | { kind = Librarian | Explicit_write | Explicit_retract; _ } ->
                Error
                  (store_error
                     "retraction plan source must be an exact explicit-retract plan"))
         in
         let* retraction_receipt =
           match snapshot, committed_dropped with
           | Some (prior, prior_content), reasons
             when applied_revision_links <> [] || Option.fold ~none:false ~some:((<>) []) reasons ->
             let reasons = Option.value ~default:[] reasons in
             let receipt =
               { plan_id = Option.map fst retraction_plan
               ; prior_revision = prior.revision
               ; prior_snapshot_sha256 = sha256 prior_content
               ; target_revision = next.revision
               ; target_snapshot_sha256 = snapshot_sha256
               ; dropped_statements = reasons
               ; revision_links = applied_revision_links
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
           | None, _ | Some _, _ ->
             (match retraction_plan with
              | None -> Ok None
              | Some _ ->
                Error
                  (store_error
                     "retraction plan requires one existing snapshot and non-empty exact reasons"))
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
         (* The removal receipt owns the canonical reason list, including an
            empty list for a revision-link-only removal. Both recovery records
            must name the same exact journal entry. *)
         let publication_dropped = match retraction_receipt with
           | Some receipt -> Some receipt.dropped_statements
           | None -> committed_dropped in
         let publication =
           { phase=Publication_prepared
           ; prior=Option.map (fun (prior, bytes) -> prior.revision, sha256 bytes) snapshot
           ; target_revision=next.revision
           ; target_sha256=snapshot_sha256
           ; journal=Journal_codec.journal_entry_to_json ~commit_effect:Rewritten
               ~revision_links:applied_revision_links ~dropped_statements:publication_dropped ?program next } in
         let* () = write_publication ~keepers_dir ~keeper_id publication
           |> Result.map_error store_error in
         let complete () =
             (* The snapshot is durable now. Publish the original producer's
                commit marker before any cancellable secondary I/O. *)
             observe next Rewritten;
             let journal_result =
               match finalize_journal ~keepers_dir ~keeper_id publication with
               | Ok pending ->
                 committed := Some pending;
                 (match retraction_receipt with
                  | None -> Ok ()
                  | Some _ -> remove_retraction_plan_receipt ~keepers_dir ~keeper_id)
               | Error detail -> Error detail in
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
             let* () = match journal_result, retraction_plan with
               | Ok (), _ -> Ok ()
               | Error detail, None ->
                 Log.Keeper.warn ~keeper_name:keeper_id
                   "memory revision=%d committed; publication recovery pending: %s" next.revision detail;
                 Ok ()
               | Error detail, Some (plan_id, evidence_error) ->
                 Error (evidence_error ~plan_id ~snapshot_revision:next.revision
                   ~snapshot_sha256 ~detail) in
             log_invalidations ~revision:next.revision;
             Ok (next, Rewritten, output)
         in
         let commit () =
           match write_snapshot snapshot_path content with
           | Ok () -> complete ()
           | Error failure ->
             (match failure.exception_ with
              | Eio.Cancel.Cancelled _ ->
                Printexc.raise_with_backtrace failure.exception_ failure.backtrace
              | _ ->
             match failure.stage with
             | Fs_compat.After_rename when
                 sync_snapshot snapshot_path = Ok () -> complete ()
             | Fs_compat.Before_rename | Fs_compat.After_rename ->
             let outcome =
               match failure.stage with
               | Fs_compat.Before_rename -> "snapshot replacement did not occur"
               | Fs_compat.After_rename ->
                 "snapshot replacement occurred but durability is unconfirmed; prepared receipts remain for recovery"
             in
             Error
               (store_error
                  (Printf.sprintf
                     "current Memory OS atomic write failed path=%s: %s: %s"
                     snapshot_path
                     outcome
                     (Fs_compat.atomic_replace_failure_to_string failure))))
         in
         protected commit))
    in
    (* Dispatch only after BOTH locks unwind. The durable pending phase is
       written after exact journal finalization. If interrupted, a subsequent
       public read or writer resumes it without replaying the producer callback. *)
    match write () with
    | result -> notify (); result
    | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      notify ();
      Printexc.raise_with_backtrace exn backtrace)
;;

(* Explicit writes always write a revision, so their effect is [Rewritten].
   Supersession carries its own decision through the commit. *)
let update_locked_with_error
      ?clock
      ?dropped_statements
      ?retraction_plan
      ~store_error
      ~keepers_dir
      ~keeper_id
      ~now
      build
  =
  update_locked_with_output
    ?clock ?dropped_statements
    ~equal_facts:(Write_revision retraction_plan) ~store_error ~keepers_dir ~keeper_id ~now
    (fun ~snapshot_content previous ->
       let+ next = build ~snapshot_content previous in
       next, ())
  |> Result.map (fun (snapshot, (_ : commit_effect), ()) -> snapshot)
;;

type receipt_read = Reconcile_receipts | Preserve_authority of string

(* Admission cannot reinterpret a consumed input as new when its snapshot proof
   disappears. This read projects prepared commits in memory only, preserving
   every stored byte. *)
let preserved_committed_receipts ~keepers_dir ~keeper_id ~snapshot ~queue_generation =
  (* The cached read decodes the sidecar only when its file identity changed.
     Nothing here writes the sidecar or marks a fixed point. Entries the
     read skipped are ignored here; the reconcile path quarantines and
     rewrites them away. *)
  let* read = read_durable_range_receipts_cached ~keepers_dir ~keeper_id in
  let receipts = match read with
    | Cached_receipts entry -> entry.receipts
    | Uncached_receipts (receipts, _) -> receipts in
  let receipts = List.filter (fun receipt ->
    match consumed_candidate (receipt_range_id receipt) with
    | Some candidate -> String.equal candidate.queue_generation queue_generation
    | None -> false) receipts in
  (* Hashed at most once, and only when a receipt names the current revision. *)
  let snapshot =
    Option.map (fun (current, content) -> current, lazy (sha256 content)) snapshot in
  let* () = sync_matching_prepared_snapshot ~keepers_dir ~keeper_id ~snapshot receipts in
  let rec verify kept = function
    | [] -> Ok (List.rev kept)
    | Prepared {range_id; snapshot_revision; snapshot_sha256} :: rest ->
      (match snapshot with
       | Some (current, digest) when current.revision = snapshot_revision
           && String.equal (Lazy.force digest) snapshot_sha256 ->
         verify (Committed {range_id; snapshot_revision; snapshot_sha256} :: kept) rest
       | None | Some _ -> verify kept rest)
    | (Committed {snapshot_revision; snapshot_sha256; _} as receipt) :: rest ->
      (match snapshot with
       | Some (current, digest) when current.revision > snapshot_revision
           || (current.revision = snapshot_revision
               && String.equal (Lazy.force digest) snapshot_sha256) ->
         verify (receipt :: kept) rest
       | None | Some _ -> Error "explicit admission authority unavailable: committed receipt has no verifiable current snapshot; stores preserved") in
  verify [] receipts
;;

let with_receipt_status ?(strict_snapshot=false) ?(receipt_read=Reconcile_receipts) ~keepers_dir ~keeper_id select =
  let* _ = Keeper_librarian_unread_ledger.read ~keepers_dir ~keeper_id in
  try
    Fs_compat.mkdir_p keepers_dir;
    let* () = recover_publication ~keepers_dir ~keeper_id in
    let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
    Keeper_memory_os_aggregate_lock.with_lock ~keepers_dir ~keeper_id (fun () ->
      File_lock_eio.with_lock snapshot_path (fun () ->
        let* publication = read_publication ~keepers_dir ~keeper_id in
        let* () = match publication with
          | None -> Ok ()
          | Some _ -> Error "publication recovery pending; consumption authority is unavailable" in
        let* snapshot =
          match Fs_compat.load_file_opt snapshot_path with
          | None -> Ok None
          | Some content ->
            (match parse snapshot_path content with
             | Ok current -> Ok (Some (current, content))
             | Error rejection when strict_snapshot -> Error rejection
             | Error rejection ->
               (* A receipt is evidence for skipping already-committed work, so
                  an unverifiable receipt must read as no receipt, never as an
                  honored one: this caller proceeds and re-commits, and the
                  write path's quarantine branch repairs the undecodable bytes
                  (#32461). Failing the whole check here stopped every pass in
                  front of a broken snapshot, which is the wedge itself. An I/O
                  failure above still raises out of the try. *)
               Log.Keeper.warn
                 ~keeper_name:keeper_id
                 "range receipt check cannot decode the current snapshot; treating its receipts as unverifiable: %s"
                 rejection;
               Ok None)
        in
        let receipts =
          try
            match receipt_read with
            | Reconcile_receipts -> reconcile_durable_range_receipts ~keepers_dir ~keeper_id ~snapshot
            | Preserve_authority queue_generation ->
                preserved_committed_receipts ~keepers_dir ~keeper_id ~snapshot ~queue_generation
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Printf.sprintf
              "durable receipt reconciliation failed: %s" (Printexc.to_string exn))
        in
        select (Option.map fst snapshot) receipts))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Printf.sprintf
         "durable Librarian range receipt check failed keeper=%s: %s"
         keeper_id
         (Printexc.to_string exn))
;;

let with_committed_receipts ?(strict_snapshot=false) ?(receipt_read=Reconcile_receipts) ~keepers_dir ~keeper_id select =
  with_receipt_status ~strict_snapshot ~receipt_read ~keepers_dir ~keeper_id (fun snapshot receipts ->
    let* receipts = receipts in
    select snapshot receipts)
;;

let read_with_revision_evidence_for_keepers_dir ~keepers_dir ~keeper_id ~after_revision =
  if after_revision < 0 then Error "revision evidence starting revision must be nonnegative"
  else with_committed_receipts ~strict_snapshot:true ~keepers_dir ~keeper_id
    (fun snapshot _receipts ->
      let* pending = read_retraction_plan_receipt ~keepers_dir ~keeper_id in
      match pending with
      | Some _ -> Error "revision evidence journal finalization is pending"
      | None ->
        let rows = ref [] in
        let visit = function
          | Dated_jsonl.Malformed_json {detail; _} -> Some (Error detail)
          | Dated_jsonl.Parsed json ->
            match Journal_codec.journal_entry_of_json json with
            | Error detail -> Some (Error detail)
            | Ok (Journal_failed _ | Journal_quarantined _) -> None
            | Ok (Journal_committed {revision; recorded_at; source; change; _}) ->
              if revision <= after_revision then Some (Ok ())
              else match snapshot, json with
                | Some current, `Assoc fields when revision <= current.revision ->
                  (match Journal_codec.journal_commit_effect fields, Journal_codec.journal_revision_links fields with
                   | Ok commit_effect, Ok revision_links ->
                     rows := {snapshot_revision=revision; recorded_at; source; commit_effect;
                       revision_links; removed_memory_ids=List.map memory_id change.removed;
                       added_memory_ids=List.map memory_id change.added} :: !rows;
                     None
                   | Error detail, _ | _, Error detail -> Some (Error detail))
                | _ -> Some (Error "revision evidence exceeds the current snapshot") in
        let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
        let* result = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
          Dated_jsonl.find_latest_entry_in_file_result path visit)
          |> Result.map_error Dated_jsonl.read_error_to_string in
        let+ () = match result with None -> Ok () | Some result -> result in
        snapshot, !rows)
;;

let committed_range ~keepers_dir ~keeper_id select =
  with_committed_receipts ~keepers_dir ~keeper_id (fun _snapshot receipts ->
    Ok (List.find_map (function
      | Committed {range_id; _} -> select range_id
      | Prepared _ -> None) receipts))
;;

let committed_explicit_candidates ~keepers_dir ~keeper_id ~queue_generation =
  with_committed_receipts ~receipt_read:(Preserve_authority queue_generation) ~keepers_dir ~keeper_id (fun _snapshot receipts ->
    Ok (List.filter_map (function
      | Committed {range_id; _} ->
        (match consumed_candidate range_id with
         | Some candidate when String.equal candidate.queue_generation queue_generation -> Some candidate
         | Some _ | None -> None)
      | Prepared _ -> None) receipts
    |> List.sort (fun (left : explicit_candidate_id) right -> Int.compare left.sequence right.sequence)))
;;

(* Bindings are only recalled in the incarnation they were committed against.
   The snapshot hash proves the binding's birth; complete later journal revisions
   prove no intervening retirement, even if the exact claim was re-added. *)
let read_recall_journal_projection ~path ~oldest =
      let inspect () =
        try Ok (Unix.lstat path) with
        | Unix.Unix_error (error, _, _) -> Error (Unix.error_message error) in
      let* before = inspect () in
      let cached = Identity_map.find_opt path (Atomic.get recall_journal_cache) in
      match cached with
        | Some cached when cached.oldest=oldest && same_file_identity cached.identity before ->
          Ok cached.projection
        | Some _ | None ->
          (* Growth is not proof of an append. Only the normal local writer's
             locked observation may advance the cached identity; any external
             change requires the complete authoritative history again. *)
          publish_recall_cache path None;
          let* scanned = Dated_jsonl.fold_file_appended_entries_result path ~cursor:None
            ~init:empty_recall_projection ~f:(project_recall_entry ~oldest)
            |> Result.map_error Dated_jsonl.read_error_to_string in
          let* projection = match scanned with
            | Dated_jsonl.Appended (projection, _) -> Ok projection
            | Dated_jsonl.Cursor_invalidated -> Error "admission recall cold journal cursor invalidated" in
          let* after = inspect () in
          if not (same_file_identity before after) then
            Error "admission recall journal changed during full verification"
          else (
            publish_recall_cache path (Some {oldest;identity=after;projection});
            Ok projection)
;;

let live_admission_bindings ~keepers_dir ~keeper_id (snapshot : t) bindings =
  let current_ids = Set_util.StringSet.of_list (List.map memory_id snapshot.facts) in
  let applicable = List.filter (fun (_, binding) ->
    Set_util.StringSet.mem binding.target_memory_id current_ids) bindings in
  let oldest = List.fold_left (fun oldest (revision, _) -> min oldest revision)
    snapshot.revision applicable in
  if oldest = snapshot.revision then Ok (List.map snd applicable)
  else
    Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
      let* projection = read_recall_journal_projection ~path ~oldest in
      let* () = match projection.invalid with None -> Ok () | Some detail -> Error detail in
      if projection.highest > snapshot.revision then
        Error "admission recall journal is ahead of the current snapshot"
      else if Recall_revision_set.cardinal projection.revisions <> snapshot.revision - oldest then
        Error "admission recall lacks complete intervening Memory revision history"
      else Ok (List.filter_map (fun (born_revision, binding) ->
        match Identity_map.find_opt binding.target_memory_id projection.retired with
        | Some removed_revision when removed_revision > born_revision -> None
        | Some _ | None -> Some binding) applicable))
;;

let read_with_admission_recall_status_for_keepers_dir ~keepers_dir ~keeper_id =
  with_receipt_status ~strict_snapshot:true ~keepers_dir ~keeper_id
    (fun snapshot receipts ->
      match snapshot, receipts with
      | snapshot, Error detail -> Ok (snapshot, Error detail)
      | None, Ok _ -> Ok (None, Ok [])
      | Some current, Ok receipts ->
        let bindings = List.filter_map (function
          | Committed {range_id=Explicit_candidate_with_recall binding; snapshot_revision; _} ->
            Some (snapshot_revision, binding)
          | Committed { range_id = (Atom_range _ | Official_range _ | Explicit_candidate _); _ }
          | Prepared _ -> None) receipts in
        Ok (Some current, live_admission_bindings ~keepers_dir ~keeper_id current bindings))
;;

let read_with_admission_recall_for_keepers_dir ~keepers_dir ~keeper_id =
  let* snapshot, bindings =
    read_with_admission_recall_status_for_keepers_dir ~keepers_dir ~keeper_id in
  let+ bindings = bindings in
  snapshot, bindings
;;

let revision_evidence_to_json (row : revision_evidence) =
  `Assoc ["snapshot_revision", `Int row.snapshot_revision; "recorded_at", `Float row.recorded_at;
    "source", Snapshot_codec.source_to_json row.source;
    "commit_effect", (match row.commit_effect with None -> `Null
      | Some Rewritten -> `String "rewritten" | Some Unchanged -> `String "unchanged");
    "revision_links", (match row.revision_links with None -> `Null | Some links -> Journal_codec.revision_links_to_json links);
    "removed_memory_ids", `List (List.map (fun id -> `String id) row.removed_memory_ids);
    "added_memory_ids", `List (List.map (fun id -> `String id) row.added_memory_ids)]
;;

let recall_unresolved_reason_to_string = function
  | History_unavailable detail -> "history unavailable: " ^ detail
  | Missing_transition revision -> Printf.sprintf "missing transition at revision %d" revision
  | Invalid_transition revision -> Printf.sprintf "invalid transition at revision %d" revision
  | Unrecorded_lineage revision -> Printf.sprintf "lineage unrecorded at revision %d" revision
  | Retired_without_successor revision -> Printf.sprintf "retired without successor at revision %d" revision
;;

let recall_unresolved_reason_to_json reason =
  let kind, fields = match reason with
    | History_unavailable detail -> "history_unavailable", ["detail", `String detail]
    | Missing_transition revision -> "missing_transition", ["revision", `Int revision]
    | Invalid_transition revision -> "invalid_transition", ["revision", `Int revision]
    | Unrecorded_lineage revision -> "unrecorded_lineage", ["revision", `Int revision]
    | Retired_without_successor revision -> "retired_without_successor", ["revision", `Int revision] in
  `Assoc (("kind", `String kind) :: fields)
;;

let read_recall_transitions ~keepers_dir ~keeper_id ~after_revision ~through_revision =
  let* pending = read_retraction_plan_receipt ~keepers_dir ~keeper_id in
  match pending with
  | Some _ -> Error "successor recall journal finalization is pending"
  | None ->
    Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
      let* projection = read_recall_journal_projection ~path ~oldest:after_revision in
      let* () = match projection.invalid with None -> Ok () | Some detail -> Error detail in
      if projection.highest > through_revision then Error "journal exceeds current revision"
      else
        (* Keep every actual rewrite, including duplicate revisions: the pure
           validator must still distinguish equal replay from conflicting
           transition evidence. Unchanged observations cannot supply edges. *)
        Ok (List.rev projection.rewrites_rev))
;;

let read_successor_recall_for_keepers_dir ~keepers_dir ~keeper_id =
  with_receipt_status ~strict_snapshot:true ~keepers_dir ~keeper_id (fun snapshot receipts ->
    match snapshot, receipts with
    | snapshot, Error detail -> Ok {receipt_verification=Error detail; snapshot;
        direct_bindings=[]; successor_candidates=[]; unresolved=[]}
    | None, Ok _ -> Ok {receipt_verification=Ok (); snapshot=None; direct_bindings=[]; successor_candidates=[]; unresolved=[]}
    | Some current, Ok receipts ->
      let bindings = List.filter_map (function
        | Committed {range_id=Explicit_candidate_with_recall binding; snapshot_revision; _} ->
          Some (snapshot_revision,binding)
        | Committed { range_id = (Atom_range _ | Official_range _ | Explicit_candidate _); _ }
        | Prepared _ -> None) receipts in
      let oldest = List.fold_left (fun earliest (revision, _) -> min earliest revision)
        current.revision bindings in
      let history = if oldest=current.revision then Ok [] else
        read_recall_transitions ~keepers_dir ~keeper_id ~after_revision:oldest ~through_revision:current.revision in
      Ok (Successor_recall.project current bindings history))
;;

let committed_durable_coverage ~keepers_dir ~keeper_id ~receipt_scope =
  committed_range ~keepers_dir ~keeper_id (function
    | Atom_range range when String.equal range.receipt_scope receipt_scope -> Some range
    | Atom_range _ | Official_range _ | Explicit_candidate _ | Explicit_candidate_with_recall _ -> None)
;;

let committed_official_coverage ~keepers_dir ~keeper_id ~receipt_scope =
  committed_range ~keepers_dir ~keeper_id (function
    | Official_range range when String.equal range.receipt_scope receipt_scope -> Some range
    | Atom_range _ | Official_range _ | Explicit_candidate _ | Explicit_candidate_with_recall _ -> None)
;;

let committed_durable_range ~keepers_dir ~keeper_id ~receipt_scope =
  committed_durable_coverage ~keepers_dir ~keeper_id ~receipt_scope
  |> Result.map (function
    | Some (range : durable_range_id) when range.unread_messages = [] -> Some range
    | Some _ | None -> None)
;;

let committed_official_range ~keepers_dir ~keeper_id ~receipt_scope =
  committed_official_coverage ~keepers_dir ~keeper_id ~receipt_scope
  |> Result.map (function
    | Some (range : official_range_id) when range.unread_messages = [] -> Some range
    | Some _ | None -> None)
;;

let read_unread_messages = Keeper_librarian_unread_ledger.read

let committed_unread_messages ~keepers_dir ~keeper_id =
  with_committed_receipts ~keepers_dir ~keeper_id
    (fun _snapshot _receipts -> Keeper_librarian_unread_ledger.read ~keepers_dir ~keeper_id)
;;

(* Apply a librarian's disposition to whatever the snapshot holds when the
   lock is taken.

   The librarian says what changes: retire that one for this reason, add these
   new claims. A fact the disposition never mentions is left alone.

   A fact the librarian retires is retired even if the keeper re-observed it
   during the pass: the judgment was about the claim, and a re-observation does
   not answer it. The keeper can state it again on its next turn. *)
type disposition =
  { snapshot : t
  ; commit : commit_effect
  ; absorbed_applied : Keeper_memory_os_types.absorbed_statement list
  ; absorbed_not_applied : Keeper_memory_os_types.absorbed_statement list
  ; claims_not_applied : Keeper_memory_os_types.fact list
  ; revisions_applied : Keeper_memory_os_types.revision list
  }

type disposition_basis =
  { expected_revision : int option
  ; expected_facts : Keeper_memory_os_types.fact list option
  }

type disposition_error =
  | Basis_superseded of t option
  | Destination_absent of { memory_id : string; current : t option }
  | Disposition_store_failed of string

type program_source =
  | Atom_program_source of
      { range : durable_range_id
      ; checkpoint : Agent_core.Types.message list
      }
  | Official_program_source of
      { range : official_range_id
      ; selected_turns : (int * Ids.Turn_ref.t * Agent_core.Types.message list) list
      }

type program_commit =
  { snapshot : t
  ; proof : Keeper_memory_os_program_types.publication
  }

let messages_sha256 messages =
  sha256 (Yojson.Safe.to_string (`List (List.map Agent_core.Checkpoint.message_to_json messages)))

let prepare_program_source source (program : Keeper_memory_os_program.t) =
  let module P = Keeper_memory_os_program_types in
  let module Unread = Keeper_librarian_unread in
  match source with
  | Atom_program_source {range;checkpoint} ->
    let* _ = durable_range_id_of_json (durable_range_id_to_json range)
      |> Result.map_error wire_error_to_string in
    let* sources = Unread.sources_for_atom_range ~trace_id:range.trace_id
      ~history_start_boundary_line:range.history_start_boundary_line ~start_atom:range.start_atom
      ~end_atom:range.end_atom ~messages:checkpoint in
    if sources <> program.sources || range.unread_messages <> program.unread
       || Runtime_model_input_tail_window.atom_opening_digest checkpoint (range.end_atom-1)
          <> Some range.last_atom_digest
    then Error "ordered program does not cover its exact original atom boundary"
    else Ok (Some range,None,
      P.Atom_boundary {receipt_scope=range.receipt_scope;trace_id=range.trace_id;
        history_start_boundary_line=range.history_start_boundary_line;start_atom=range.start_atom;
        end_atom=range.end_atom;last_atom_digest=range.last_atom_digest;
        end_boundary_line=range.end_boundary_line;boundary_lines_seen=range.boundary_lines_seen;
        checkpoint_sha256=messages_sha256 checkpoint})
  | Official_program_source {range;selected_turns} ->
    let* _ = official_range_id_of_json (official_range_id_to_json range)
      |> Result.map_error wire_error_to_string in
    let selected = List.map (fun (line,turn_ref,_) -> line,turn_ref) selected_turns in
    let sources = List.concat_map (fun (boundary_line,turn_ref,messages) ->
      List.mapi (fun message_in_turn message ->
        Unread.Official_turn {turn_ref;boundary_line;message_in_turn;
          message_sha256=Unread.message_digest message}) messages) selected_turns in
    if selected <> range.turns || sources <> program.sources || range.unread_messages <> program.unread
    then Error "ordered program does not cover its exact original official-turn boundary"
    else Ok (None,Some range,P.Official_boundary {receipt_scope=range.receipt_scope;
      after_boundary_line=range.after_boundary_line;
      turns=List.map (fun (line,turn_ref,messages) -> line,turn_ref,messages_sha256 messages) selected_turns})

let apply_program_with_io ?write_snapshot ?sync_snapshot ?finalize_journal ?on_committed ?clock ~keepers_dir ~keeper_id ~now ~anchor ~source ~validate_source program =
  let module P = Keeper_memory_os_program_types in
  let* () =
    if Keeper_identity.Keeper_id.to_string program.Keeper_memory_os_program.keeper_id=keeper_id
    then Ok () else Error "ordered Memory program Keeper differs from the store identity" in
  let* durable_range_id,official_range_id,boundary = prepare_program_source source program in
  update_locked_with_output ?write_snapshot ?sync_snapshot ?finalize_journal ?clock ?durable_range_id ?official_range_id
    ~program_of_output:Fun.id
    ?observe_output:(Option.map (fun observe snapshot (_ : commit_effect) proof ->
      observe {snapshot;proof}) on_committed)
    ~equal_facts:(Write_revision None) ~store_error:Fun.id ~keepers_dir ~keeper_id ~now
    (fun ~snapshot_content previous ->
      let* () = validate_source () in
      let* locked_prior = verify_program_anchor ~keepers_dir ~keeper_id anchor ~snapshot_content previous program in
      let current = Option.fold ~none:[] ~some:(fun (current : t) -> current.facts) previous in
      let* execution = Keeper_memory_os_program.replay program ~current in
      let source = {kind=Librarian;trace_id=Ids.Turn_ref.trace_id program.turn_ref} in
      let* next = make_snapshot_from_maintained ~previous ~now ~source
        ~facts:execution.final_facts ~invalidated:[] () in
      Ok (next,({execution;captured=anchor.anchor_identity;locked_prior;boundary} : P.publication)))
  |> Result.map (fun (snapshot,(_ : commit_effect),proof) -> {snapshot;proof})

let apply_program ?on_committed ?clock ~keepers_dir ~keeper_id ~now ~anchor ~source ~validate_source program =
  apply_program_with_io ?on_committed ?clock ~keepers_dir ~keeper_id ~now ~anchor ~source ~validate_source program

let apply_disposition_guarded
      ?expected_basis
      ?on_committed
      ?clock
      ?dropped_statements
      ?durable_range_id
      ?official_range_id
      ?(explicit_candidate_ids = [])
      ?admission_recall
      ?(required_memory_ids = [])
      ~absorbed
      ~revisions
      ~keepers_dir
      ~keeper_id
      ~now
      ~source
      ~new_claims
      ()
  =
  let store_error detail = Disposition_store_failed detail in
  let ids_of facts =
    List.fold_left
      (fun ids fact -> Set_util.StringSet.add (memory_id fact) ids)
      Set_util.StringSet.empty
      facts
  in
  let plan_of (previous : t option) =
    let current = match previous with None -> [] | Some snapshot -> snapshot.facts in
    Keeper_memory_os_disposition_core.plan ~current
      ~dropped:(Option.value dropped_statements ~default:[])
      ~absorbed ~revisions ~new_claims
  in
  (* What the commit did: an absorption is applied when its row is written (its
     source left the snapshot into its target), a revision when its old id left
     the snapshot and its successor is in the next one. Set by the one
     [before_replace] under the lock, which runs on every commit; read only
     after the commit succeeded. *)
  let outcome = ref (([], absorbed), [], []) in
  let disposition_of snapshot commit =
    let (absorbed_applied, absorbed_not_applied), claims_not_applied, revisions_applied =
      !outcome
    in
    { snapshot
    ; commit
    ; absorbed_applied
    ; absorbed_not_applied
    ; claims_not_applied
    ; revisions_applied
    }
  in
  (* RFC-0456 §4.2: an absorbed fact leaves the snapshot only with its row kept.
     The rows are the absorbed facts the locked snapshot held and the next one
     does not, so a fact the keeper retracted during the pass has no row, and
     they are written just before the replace; a failed write fails this
     commit. *)
  let write_absorbed_rows ~(previous : t option) ~(next : t) =
    let plan = plan_of previous in
    let previous_facts =
      match previous with
      | None -> []
      | Some snapshot -> snapshot.facts
    in
    let previous_ids = ids_of previous_facts in
    let next_ids = ids_of next.facts in
    let rows =
      List.filter_map
        (fun fact ->
           let identity = memory_id fact in
           match Set_util.StringMap.find_opt identity plan.absorbed_into with
           | Some into when not (Set_util.StringSet.mem identity next_ids) ->
             Some
               { Keeper_memory_absorbed.recorded_at = now
               ; trace_id = (source : source).trace_id
               ; memory_id = identity
               ; into
               ; fact
               }
           | Some _ | None -> None)
        previous_facts
    in
    let revisions_applied =
      List.filter
        (fun (revision : Keeper_memory_os_types.revision) ->
           Set_util.StringSet.mem revision.superseded previous_ids
           && (not (Set_util.StringSet.mem revision.superseded next_ids))
           && Set_util.StringSet.mem revision.superseded_by next_ids)
        revisions
    in
    outcome
    := ( List.partition
           (fun (statement : Keeper_memory_os_types.absorbed_statement) ->
              List.exists
                (fun (row : Keeper_memory_absorbed.record) ->
                   String.equal row.memory_id statement.absorbed
                   && String.equal row.into statement.into)
                rows)
           absorbed
       , plan.claims_refused
       , revisions_applied );
    Keeper_memory_absorbed.append_all ~keepers_dir ~keeper_id rows
    |> Result.map_error (fun error -> store_error (Keeper_memory_absorbed.append_error_to_string error))
  in
  update_locked_with_output
    ?on_committed:
      (Option.map
         (fun on_committed snapshot commit -> on_committed (disposition_of snapshot commit))
         on_committed)
    ?clock
    ?dropped_statements
    ?durable_range_id
    ?official_range_id
    ~explicit_candidate_ids
    ?admission_recall
    ~declared_revisions:revisions
    ~before_replace:write_absorbed_rows
    ~equal_facts:Keep_stored
    ~store_error
    ~keepers_dir
    ~keeper_id
    ~now
    (fun ~snapshot_content:_ previous ->
       let* () = match expected_basis with
         | None -> Ok ()
         | Some (basis : disposition_basis) ->
           let revision = Option.map (fun (snapshot : t) -> snapshot.revision) previous in
           let facts = Option.map (fun (snapshot : t) -> snapshot.facts) previous in
           if revision = basis.expected_revision && facts = basis.expected_facts
           then Ok () else Error (Basis_superseded previous) in
       let plan = plan_of previous in
       let* next = make_snapshot_from_maintained ~previous ~now ~source ~facts:plan.facts
         ~invalidated:plan.invalidated () |> Result.map_error store_error in
       let actual = ids_of next.facts in
       match List.find_opt (fun identity -> not (Set_util.StringSet.mem identity actual)) required_memory_ids with
       | Some memory_id -> Error (Destination_absent { memory_id; current = previous })
       | None -> Ok (next, ()))
  |> Result.map (fun (snapshot, commit, ()) -> disposition_of snapshot commit)
;;

let disposition_error_to_string = function
  | Basis_superseded _ -> "current Memory OS disposition basis changed"
  | Destination_absent { memory_id; current = _ } ->
    "explicit admission destination is not current: " ^ memory_id
  | Disposition_store_failed detail -> detail
;;

let apply_disposition
      ?expected_basis ?on_committed ?clock ?dropped_statements ?durable_range_id
      ?official_range_id ?explicit_candidate_ids ?admission_recall ?required_memory_ids
      ~absorbed ~revisions ~keepers_dir ~keeper_id ~now ~source ~new_claims () =
  apply_disposition_guarded
    ?expected_basis ?on_committed ?clock ?dropped_statements ?durable_range_id
    ?official_range_id ?explicit_candidate_ids ?admission_recall ?required_memory_ids
    ~absorbed ~revisions ~keepers_dir ~keeper_id ~now ~source ~new_claims ()
  |> Result.map_error disposition_error_to_string
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
  update_locked_with_error
    ?clock
    ?dropped_statements
    ~store_error:Fun.id
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
let upsert_fact ?clock ~keepers_dir ~keeper_id ~now ~source incoming =
  update_locked_with_error
    ?clock
    ~store_error:(fun detail -> Upsert_persistence_failed detail)
    ~keepers_dir ~keeper_id ~now
    (fun ~snapshot_content:_ previous -> upsert_snapshot ~previous ~now ~source incoming)
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
    update_locked_with_output
      ?clock
      ~declared_revisions:[{superseded=superseded_memory_id; superseded_by=incoming_identity}]
      ~dropped_statements:
        [ { Keeper_memory_os_types.memory_id = superseded_memory_id
          ; reason = "superseded_by " ^ incoming_identity
          }
        ]
      ~equal_facts:(Write_revision None)
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
      let* disposition =
        match
          List.find_opt
            (fun fact -> String.equal (memory_id fact) superseded_memory_id)
            current_facts
        with
        | None ->
          (match find_removal ~keepers_dir ~keeper_id superseded_memory_id with
           | Removed removal ->
             (match removal.removed_by.kind, removal.removed_origin with
              | Librarian, Authored -> Ok (Target_already_dropped removal)
              | Librarian, Injected ->
                Error (Supersede_target_not_authored superseded_memory_id)
              | (Explicit_write | Explicit_retract), (Authored | Injected) ->
                Error (Supersede_target_removed removal))
           | No_removal_recorded -> Error (Supersede_target_not_current superseded_memory_id)
           | Journal_unreadable detail -> Error (Supersede_journal_unreadable detail))
        | Some { origin = { kind = Keeper_memory_os_types.Authored; _ }; _ } ->
          Ok Superseded_current
        | Some { origin = { kind = Keeper_memory_os_types.Injected; _ }; _ } ->
          Error (Supersede_target_not_authored superseded_memory_id)
      in
      match disposition with
      | Target_already_dropped _ ->
        upsert_snapshot ~previous ~now ~source incoming
        |> Result.map (fun next -> next, disposition)
        |> Result.map_error (function
          | Unsupported_derivation invalidation -> Supersede_unsupported_derivation invalidation
          | Upsert_persistence_failed detail -> Supersede_persistence_failed detail)
      | Superseded_current ->
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
        |> Result.map (fun next -> next, disposition)
        |> Result.map_error (fun detail -> Supersede_persistence_failed detail))
    |> Result.map (fun (snapshot, (_ : commit_effect), disposition) -> snapshot, disposition)
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

let journal_projection_identity ~keeper_id line_offset =
  Printf.sprintf "memory:journal:%d:%s:%d" (String.length keeper_id) keeper_id
    line_offset
;;

let read_journal_tail_projection ~keepers_dir ~keeper_id ~limit =
  read_journal_tail_indexed ~keepers_dir ~keeper_id ~limit
  |> List.map (fun (line_offset, result) ->
       match Journal_codec.journal_line_to_json result with
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
let move_aside_for_keepers_dir ?clock ~keepers_dir ~keeper_id ~now ~rejection
    ~expected_snapshot_sha256 () =
  let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  Keeper_memory_os_aggregate_lock.with_lock ?clock ~keepers_dir ~keeper_id (fun () ->
    File_lock_eio.with_lock ?clock snapshot_path (fun () ->
      let* publication = read_publication ~keepers_dir ~keeper_id in
      let* () = match publication with
        | None -> Ok ()
        | Some _ -> Error "publication evidence is pending; snapshot quarantine refused" in
      let* () = quarantine_regular_path snapshot_path in
      let* content = preflight_file snapshot_path in
      let* content = Option.to_result ~none:"snapshot disappeared before quarantine" content in
      let* () = if String.equal (sha256 content) expected_snapshot_sha256
        then Ok () else Error "snapshot changed before quarantine" in
      let* () = match parse snapshot_path content with
        | Ok _ -> Error "snapshot is readable; quarantine refused"
        | Error actual when String.equal actual rejection -> Ok ()
        | Error _ -> Error "snapshot decoder rejection changed before quarantine" in
      let* () = quarantine_regular_path snapshot_path in
      quarantine_snapshot_and_receipt
        ~keepers_dir ~keeper_id ~snapshot_path ~now ~rejection))
;;

module For_testing = struct
  let decode_snapshot text = parse "captured snapshot" text
  let recover_publication_with_sync = recover_publication_with_sync

  let apply_program_with_publication_io ~write_snapshot ~sync_snapshot ~before_journal ~on_committed
      ~keepers_dir ~keeper_id ~now ~anchor ~source ~validate_source program =
    apply_program_with_io ~write_snapshot ~sync_snapshot ~on_committed
      ~finalize_journal:(fun ~keepers_dir ~keeper_id receipt ->
        before_journal (); record_publication_journal ~keepers_dir ~keeper_id receipt)
      ~keepers_dir ~keeper_id ~now ~anchor ~source ~validate_source program

  let replace_with_publication_io ~write_snapshot ~sync_snapshot ~on_committed ~before_journal
      ~keepers_dir ~keeper_id ~now ~source ~facts =
    update_locked_with_output ~write_snapshot ~sync_snapshot ~on_committed
      ~finalize_journal:(fun ~keepers_dir ~keeper_id receipt ->
        before_journal (); record_publication_journal ~keepers_dir ~keeper_id receipt)
      ~equal_facts:(Write_revision None)
      ~store_error:Fun.id ~keepers_dir ~keeper_id ~now
      (fun ~snapshot_content:_ previous ->
        let+ snapshot = make_snapshot ~previous ~now ~source ~facts () in snapshot, ())
    |> Result.map (fun (snapshot, _, ()) -> snapshot)

  let durable_range_receipt_decodes () = Atomic.get durable_range_receipt_decodes
end
