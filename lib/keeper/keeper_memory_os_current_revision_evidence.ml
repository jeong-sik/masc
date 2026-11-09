open Keeper_memory_os_types
open Result.Syntax
module Snapshot_codec = Keeper_memory_os_snapshot_codec
module Journal_codec = Keeper_memory_os_journal_codec
module Successor_recall = Keeper_memory_os_successor_recall
open Keeper_memory_os_current_types
open Keeper_memory_os_support_core
open Keeper_memory_os_current_layout
open Keeper_memory_os_current_range_codec
open Keeper_memory_os_current_receipt_store
open Keeper_memory_os_current_journal
open Keeper_memory_os_current_retraction_plan
open Keeper_memory_os_current_publication

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
