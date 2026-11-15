open Keeper_memory_os_types
open Result.Syntax
module Journal_codec = Keeper_memory_os_journal_codec
open Keeper_memory_os_current_types
open Keeper_memory_os_support_core
open Keeper_memory_os_current_layout
open Keeper_memory_os_current_receipt_store
open Keeper_memory_os_current_journal
open Keeper_memory_os_current_retraction_plan
open Keeper_memory_os_current_publication

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
  then Ok []
  else (
    let path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
    Dated_jsonl.map_tail_rows_result path ~max_lines:limit ~f:(fun { Dated_jsonl.offset; line } ->
      match Yojson.Safe.from_string line with
      | json -> offset, Journal_codec.journal_entry_of_json json
      | exception Yojson.Json_error message ->
        offset, Error (Printf.sprintf "journal line is not valid JSON: %s" message))
    |> Result.map_error Dated_jsonl.read_error_to_string)
;;

let read_journal_tail ~keepers_dir ~keeper_id ~limit =
  read_journal_tail_indexed ~keepers_dir ~keeper_id ~limit
  |> Result.map (List.map snd)
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
