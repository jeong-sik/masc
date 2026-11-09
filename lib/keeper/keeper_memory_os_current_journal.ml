open Keeper_memory_os_types
module Snapshot_codec = Keeper_memory_os_snapshot_codec
module Journal_codec = Keeper_memory_os_journal_codec
module Successor_recall = Keeper_memory_os_successor_recall
open Keeper_memory_os_current_types
open Keeper_memory_os_support_core
open Keeper_memory_os_current_layout
open Keeper_memory_os_current_receipt_store

let source_kind_to_string = Snapshot_codec.source_kind_to_string
let to_json = Snapshot_codec.to_json
let snapshot_sha256 snapshot = sha256 (Snapshot_codec.snapshot_bytes snapshot)

let parse path content =
  try
    Result.map_error
      (fun rejection ->
         Printf.sprintf
           "%s: current Memory OS snapshot rejected: %s"
           path
           (Snapshot_codec.snapshot_rejection_to_string rejection))
      (Snapshot_codec.of_json (Yojson.Safe.from_string content))
  with
  | Yojson.Json_error message ->
    Error (Printf.sprintf "%s: invalid JSON: %s" path message)
;;

let publication_read_guard ~keepers_dir ~keeper_id =
  match Fs_compat.load_file_opt (publication_receipt_path ~keepers_dir ~keeper_id) with
  | None -> Ok ()
  | Some _ -> Error "current Memory publication recovery is pending; a writer must finalize it"
;;

type read_classified =
  | No_snapshot
  | Readable of t
  | Undecodable of { rejection : string }
  | Io_unreadable of { detail : string }

let read_classified ~keepers_dir ~keeper_id =
  let snapshot_path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  try
    match publication_read_guard ~keepers_dir ~keeper_id with
    | Error detail -> Io_unreadable {detail}
    | Ok () ->
    let observed = match Fs_compat.load_file_opt snapshot_path with
    | None -> No_snapshot
    | Some content ->
      (match parse snapshot_path content with
       | Ok snapshot -> Readable snapshot
       | Error rejection -> Undecodable { rejection }) in
    (match publication_read_guard ~keepers_dir ~keeper_id with
     | Ok () -> observed | Error detail -> Io_unreadable {detail})
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error message ->
    Io_unreadable
      { detail =
          Printf.sprintf
            "current Memory OS read failed path=%s: %s"
            snapshot_path
            message
      }
;;

let librarian_failure_kind_to_string = Journal_codec.librarian_failure_kind_to_string

module Recall_revision_set = Set.Make (Int)

type recall_journal_projection =
  { revisions : Recall_revision_set.t
  ; retired : int Identity_map.t
  ; highest : int
  ; rewrites_rev : Successor_recall.transition list
  ; invalid : string option
  }

type recall_journal_cache =
  { oldest : int
  ; identity : Unix.stats
  ; projection : recall_journal_projection
  }

let recall_journal_cache = Atomic.make Identity_map.empty
let empty_recall_projection =
  {revisions=Recall_revision_set.empty;retired=Identity_map.empty;highest=0;rewrites_rev=[];invalid=None}

let rec publish_recall_cache path value =
  let before = Atomic.get recall_journal_cache in
  let after = match value with
    | None -> Identity_map.remove path before
    | Some entry -> Identity_map.add path entry before in
  if not (Atomic.compare_and_set recall_journal_cache before after) then
    publish_recall_cache path value

(* Forward projection matches the previous reverse reader's stopping boundary.
   Only snapshot rewrites cover revisions; unchanged observations never fill a
   missing transition. No observation rows are retained in memory. *)
let plain_reobservation (before : fact) (after : fact) =
  before.claim=after.claim && before.category=after.category && before.basis=after.basis
  && before.origin=after.origin && before.first_seen=after.first_seen && after.last_seen>=before.last_seen

let retired_identities (change : change) =
  List.filter_map (fun before ->
    let identity=memory_id before in
    match List.find_opt (fun after -> memory_id after=identity) change.added with
    | Some after when plain_reobservation before after -> None
    | Some _ | None -> Some identity) change.removed

let project_recall_entry ~oldest projection = function
  | Dated_jsonl.Malformed_json {detail;_} -> {projection with invalid=Some detail}
  | Dated_jsonl.Parsed json ->
    match Journal_codec.journal_entry_of_json json, json with
    | Error detail, _ -> {projection with invalid=Some detail}
    | Ok (Journal_failed _ | Journal_quarantined _), _ -> projection
    | Ok (Journal_committed _), (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) ->
      {projection with invalid=Some "committed journal line is not a JSON object"}
    | Ok (Journal_committed {revision;recorded_at;source;change;program;_}), `Assoc fields ->
      if revision <= oldest then empty_recall_projection
      else
        match Journal_codec.journal_commit_effect fields, Journal_codec.journal_revision_links fields with
        | Error detail, _ | _, Error detail -> {projection with invalid=Some detail}
        | Ok commit_effect, Ok revision_links ->
          let rewrote = commit_effect = Some Rewritten in
          let revisions =
            if rewrote then Recall_revision_set.add revision projection.revisions
            else projection.revisions in
          let retired_ids = retired_identities change in
          let rewrites_rev =
            if not rewrote then projection.rewrites_rev
            else
              let row : Successor_recall.transition =
                { evidence =
                    { snapshot_revision = revision
                    ; recorded_at
                    ; source
                    ; commit_effect
                    ; revision_links
                    ; removed_memory_ids = List.map memory_id change.removed
                    ; added_memory_ids = List.map memory_id change.added
                    }
                ; removed = change.removed
                ; program
                ; recreated_memory_ids =
                    List.filter
                      (fun identity ->
                        List.exists (fun fact -> memory_id fact = identity) change.added)
                      retired_ids
                }
              in
              row :: projection.rewrites_rev in
          let retired = List.fold_left (fun retired identity -> Identity_map.update identity
              (function None -> Some revision | Some prior -> Some (max prior revision)) retired)
            projection.retired retired_ids in
          let retired = Option.fold ~none:retired ~some:(fun proof ->
            List.fold_left (fun retired identity -> Identity_map.update identity
              (function None -> Some revision | Some prior -> Some (max prior revision)) retired)
              retired (Keeper_memory_os_program_publication.touched_ids proof)) program in
          {projection with revisions;retired;rewrites_rev;highest=max projection.highest revision}

let observe_recall_append path (observation : Fs_compat.private_jsonl_append_observation) json =
  match Identity_map.find_opt path (Atomic.get recall_journal_cache) with
  | None -> ()
  | Some cached ->
    let before=observation.before and after=observation.after in
    if same_file_identity cached.identity before
       && before.Unix.st_dev=after.Unix.st_dev && before.Unix.st_ino=after.Unix.st_ino
       && after.Unix.st_size-before.Unix.st_size=String.length observation.suffix
       && String.equal observation.suffix (Yojson.Safe.to_string json ^ "\n")
    then publish_recall_cache path (Some {cached with identity=after;
      projection=project_recall_entry ~oldest:cached.oldest cached.projection
        (Dated_jsonl.Parsed json)})
    else publish_recall_cache path None

(* Every journal writer and receipt recovery uses the canonical path mutex
   and stable sibling lock. A data-file lock can be released by an unrelated
   reader closing the journal; the sibling lock remains held through append. *)
let commit_observer = ref (fun ~keepers_dir:_ ~keeper_id:_ -> ())
let install_commit_observer observer =
  let previous = !commit_observer in
  commit_observer := observer;
  fun () -> commit_observer := previous

let append_journal_line_strict ~keepers_dir ~keeper_id json =
  let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  let suffix = Yojson.Safe.to_string json ^ "\n" in
  match Fs_compat.append_private_jsonl_durable_observed_result path suffix with
  | Ok (_, observation) ->
    (match observation with
     | None -> publish_recall_cache path None
     | Some observation -> observe_recall_append path observation json);
    Keeper_memory_journal_broadcast.appended ~keeper_name:keeper_id;
    !commit_observer ~keepers_dir ~keeper_id;
    Ok ()
  | Error error ->
    Error
      (Printf.sprintf
         "memory journal durable append failed path=%s: %s"
         path
         (Fs_compat.private_jsonl_transaction_error_to_string error))
;;

(* Lines without actual reason-bearing removals are observations: their
   snapshot already reached disk, so append failure warns. Destructive
   removals below use [append_journal_line_strict] and a prepared receipt so
   their originals and reasons survive failed journal finalization.
   Cancellation is never absorbed.

   These lines are the ones a memory health row reader is told about here.
   A publication's line and a removal receipt's line are written while the
   publication receipt is still on disk; a row read in that window recovers
   the publication again. The commit notification that follows them, after
   the locks unwind, announces those (RFC-0487). A removal line written by the
   recovery of a publication that never reached its target follows no commit;
   that recovery announces itself once its locks unwind
   ([recover_publication_with_sync]). *)
let append_journal_line ~keepers_dir ~keeper_id json =
  let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
  try
    match append_journal_line_strict ~keepers_dir ~keeper_id json with
    | Ok () -> Keeper_memory_health_input.written ~keepers_dir ~keeper_id
    | Error detail -> Log.Keeper.warn "%s" detail
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | exn ->
    Log.Keeper.warn
      "memory journal append failed path=%s: %s"
      path
      (Printexc.to_string exn)
;;

let append_journal_entry ~keepers_dir ~keeper_id ~commit_effect ~revision_links ~dropped_statements snapshot =
  append_journal_line
    ~keepers_dir
    ~keeper_id
    (Journal_codec.journal_entry_to_json ~commit_effect ~revision_links ~dropped_statements snapshot)
;;

(* A committed line's [dropped] lists what this commit removed: a memory the
   locked snapshot held and the next one does not. An answer can drop a memory
   the commit keeps -- its only successor was not stored -- or one the keeper
   already removed during the pass. Written as given, the append-only journal
   would say a current memory was dropped. *)
let dropped_by_commit ~(previous : t option) ~(next : t) statements =
  let ids facts =
    List.fold_left
      (fun ids fact -> Set_util.StringSet.add (memory_id fact) ids)
      Set_util.StringSet.empty
      facts
  in
  let held_before =
    match previous with
    | None -> Set_util.StringSet.empty
    | Some snapshot -> ids snapshot.facts
  in
  let held_after = ids next.facts in
  List.filter
    (fun (statement : Keeper_memory_os_types.dropped_statement) ->
       Set_util.StringSet.mem statement.memory_id held_before
       && not (Set_util.StringSet.mem statement.memory_id held_after))
    statements
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
    (Journal_codec.journal_failure_to_json ~now ~trace_id ~kind ~detail ~snapshot_present)
;;

(* A snapshot this build cannot decode is durable state no producer can leave:
   every writer reads before it writes, so one undecodable file wedges the
   keeper's memory permanently. The bytes move aside rather than being deleted
   and this line says why, so a build that can read them again still has both.
   Recorded on its own outcome because it is neither a pass that committed nor
   a pass that failed. *)
(* [now] is the caller's own observation time and repeats: two writes in the
   same second share it, and a caller may pass a fixed value. [rename] replaces
   its destination, so a repeated name would delete the snapshot an earlier
   quarantine kept — the one thing this path promises not to do. The search
   runs under the snapshot lock the writer already holds, so the name it
   settles on is still free when the rename happens. *)
let append_snapshot_quarantine ~keepers_dir ~keeper_id ~now ~rejection ~rejected_path =
  append_journal_line
    ~keepers_dir
    ~keeper_id
    (Journal_codec.journal_quarantine_to_json ~now ~rejection ~rejected_path)
;;
