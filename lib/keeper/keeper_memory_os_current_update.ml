open Keeper_memory_os_types
open Result.Syntax
module Snapshot_codec = Keeper_memory_os_snapshot_codec
module Journal_codec = Keeper_memory_os_journal_codec
open Keeper_memory_os_current_types
open Keeper_memory_os_support_core
open Keeper_memory_os_current_layout
open Keeper_memory_os_current_range_codec
open Keeper_memory_os_current_receipt_store
open Keeper_memory_os_current_journal
open Keeper_memory_os_current_retraction_plan
open Keeper_memory_os_current_publication
open Keeper_memory_os_current_read_anchor

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

(* What a commit owes the readers of the Keeper's memory health row once both
   locks unwind. *)
type owed_announcement =
  | Nothing_owed
      (* No replacement became durable. A kept snapshot's journal line tells
         the readers itself, and a failed replacement leaves its receipt to
         the next writer's recovery. *)
  | Commit_notification of publication_receipt
      (* The journal is finalized; dispatching the receipt tells the readers. *)
  | Health_input
      (* The snapshot is durable and its journal did not finalize: the line
         or the pending receipt failed. The receipt stays on disk, and the
         recovery a reader runs finishes the journal and dispatches the commit
         notification. Until a reader is told, nothing runs it. *)

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
      ~change_count
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
    let journal_path = journal_path_for_keepers_dir ~keepers_dir ~keeper_id in
    let epoch_file_path = epoch_path ~keepers_dir ~keeper_id in
    let unread_file_path = unread_ledger_path ~keepers_dir ~keeper_id in
    let range_receipt_path = durable_range_receipt_path ~keepers_dir ~keeper_id in
    let retraction_receipt_path = retraction_plan_receipt_path ~keepers_dir ~keeper_id in
    let stat_stamp path =
      stat_identity_result path |> Result.map_error store_error
    in
    let owed = ref Nothing_owed in
    (* The snapshot and output of a commit that rewrote the snapshot, counted
       once both locks are released. A kept snapshot is never counted. *)
    let rewritten = ref None in
    let molt_outcome = ref None in
    let notify () =
      match !owed with
      | Nothing_owed -> ()
      | Commit_notification receipt ->
        (match dispatch_publication ~sync_parent:Unix.fsync ~keepers_dir ~keeper_id receipt with
         | Ok () -> ()
         | Error detail -> Log.Keeper.warn ~keeper_name:keeper_id "%s" detail)
      | Health_input -> Keeper_memory_health_input.written ~keepers_dir ~keeper_id
    in
    let max_cas_attempts = 16 in
    let rec write_attempt attempt =
      (* Phase 0 (OUTSIDE ALL LOCKS): read and parse the current snapshot and
         run any admission-recall retirement scan off-domain so nested Memory OS
         locks are never held across Domain_pool_ref jobs. *)
      let pre_snapshot =
        Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
          match Fs_compat.load_file_opt snapshot_path with
          | None -> `Missing
          | Some content ->
            (match parse snapshot_path content with
             | Ok snapshot -> `Decoded (snapshot, content)
             | Error rejection -> `Decode_failed (content, rejection)))
      in
      let pre_revision =
        match pre_snapshot with
        | `Decoded (snapshot, _) -> Some snapshot.revision
        | `Missing | `Decode_failed _ -> None
      in
      let* pre_recall =
        match admission_recall with
        | None | Some { bindings = []; _ } -> Ok (`Checked None)
        | Some { decided_at_revision; bindings } ->
          let targets =
            Set_util.StringSet.of_list
              (List.map (fun binding -> binding.target_memory_id) bindings)
          in
          let* stamp_before = stat_stamp journal_path in
          let result =
            targets_retired_since
              ~keepers_dir
              ~keeper_id
              ~revision:decided_at_revision
              ~held:pre_revision
              targets
          in
          let* stamp_after = stat_stamp journal_path in
          if stamp_before = stamp_after
          then Ok (`Checked (Some (stamp_before, result)))
          else Ok `Retry_stale
      in
      match pre_recall with
      | `Retry_stale ->
        if attempt < max_cas_attempts
        then (
          yield_for_concurrent_writer ();
          write_attempt (attempt + 1))
        else
          Error
            (store_error
               "current Memory OS journal changed repeatedly during commit preparation")
      | `Checked pre_recall_checked ->
        (* Phase 1 (SHORT LOCK — ZERO Domain_pool_ref jobs inside): validate
           pre-parsed bytes against the locked file, run [build], check
           invariants, and evaluate non-blocking molt threshold. *)
        let phase1 =
          Keeper_memory_os_aggregate_lock.with_lock
            ?clock
            ~keepers_dir
            ~keeper_id
            (fun () ->
               (* File_lock_eio.with_lock appends ".lock" itself; a pre-suffixed path
                  locked "<snapshot>.lock.lock" and left a stray file per keeper. *)
               File_lock_eio.with_lock ?clock snapshot_path (fun () ->
                 let* _ =
                   Keeper_librarian_unread_ledger.read ~keepers_dir ~keeper_id
                   |> Result.map_error store_error
                 in
                 let* pending =
                   read_publication ~keepers_dir ~keeper_id
                   |> Result.map_error store_error
                 in
                 match pending with
                 | Some { phase = Notification_pending; _ } when attempt < max_cas_attempts ->
                   (* A sibling writer just released Phase 3 locks and is finishing
                      [dispatch_publication]; yield and retry CAS cleanly. *)
                   Ok `Retry_stale
                 | Some { phase = Publication_prepared | Notification_pending; _ } ->
                   Error
                     (store_error
                        "another publication is pending; retry recovery before writing")
                 | None ->
                   let* _ =
                     ensure_epoch ~keepers_dir ~keeper_id |> Result.map_error store_error
                   in
                 let locked_bytes = Fs_compat.load_file_opt snapshot_path in
                 let snapshot_match =
                   match pre_snapshot, locked_bytes with
                   | `Missing, None -> Ok (`Matched (None, None))
                   | `Decoded (snapshot, content), Some current_bytes
                     when String.equal content current_bytes ->
                     Ok (`Matched (Some snapshot, Some content))
                   | `Decode_failed (content, rejection), Some current_bytes
                     when String.equal content current_bytes ->
                     (* Never silently drop or auto-quarantine a snapshot whose bytes
                        failed decoding during a normal write: surface the decode
                        failure explicitly and preserve the existing snapshot bytes on
                        disk until explicit operator/boot reconciliation moves them
                        aside. *)
                     Log.Keeper.warn
                       ~keeper_name:keeper_id
                       "memory os snapshot decode failed path=%s rejection=%s"
                       snapshot_path
                       rejection;
                     Error
                       (store_error
                          (Printf.sprintf
                             "current Memory OS snapshot decode failed path=%s: %s"
                             snapshot_path
                             rejection))
                   | (`Missing | `Decoded _ | `Decode_failed _), (None | Some _) ->
                     Ok `Retry_stale
                 in
                 let* snapshot_match = snapshot_match in
                 match snapshot_match with
                 | `Retry_stale -> Ok `Retry_stale
                 | `Matched (previous, snapshot_content) ->
                   let* recall_stamp_ok =
                     match pre_recall_checked with
                     | None -> Ok true
                     | Some (stamp_before, _) ->
                       let+ stamp_now = stat_stamp journal_path in
                       stamp_now = stamp_before
                   in
                   if not recall_stamp_ok
                   then Ok `Retry_stale
                   else (
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
                     let* archived =
                       Keeper_librarian_unread_ledger.read ~keepers_dir ~keeper_id
                       |> Result.map_error store_error
                     in
                     let additions =
                       Option.fold
                         ~none:[]
                         ~some:(fun (range : durable_range_id) -> range.unread_messages)
                         durable_range_id
                       @ Option.fold
                           ~none:[]
                           ~some:(fun (range : official_range_id) -> range.unread_messages)
                           official_range_id
                     in
                     let* _ =
                       Keeper_librarian_unread.merge archived additions
                       |> Result.map_error store_error
                     in
                     let* () =
                       let consumed =
                         List.filter_map
                           (function
                             | Committed { range_id; _ } -> consumed_candidate range_id
                             | Prepared _ -> None)
                           durable_range_receipts
                       in
                       validate_unique_explicit_candidates (consumed @ explicit_candidate_ids)
                       |> Result.map_error store_error
                     in
                     let* next, output = build ~snapshot_content previous in
                     let* program =
                       match program_of_output with
                       | None -> Ok None
                       | Some convert ->
                         let* publication =
                           Keeper_memory_os_program_publication.of_json
                             (Keeper_memory_os_program_publication.to_json (convert output))
                           |> Result.map_error store_error
                         in
                         if
                           publication.execution.final_facts = next.facts
                           && publication.execution.initial_facts
                              = Option.fold
                                  ~none:[]
                                  ~some:(fun (prior : t) -> prior.facts)
                                  previous
                           && publication.locked_prior.snapshot
                              = Option.map
                                  (fun (prior, bytes) -> prior.revision, sha256 bytes)
                                  snapshot
                         then Ok (Some publication)
                         else
                           Error
                             (store_error
                                "ordered publication proof does not match the locked snapshot transition")
                     in
                     let applied_revision_links =
                       List.filter
                         (fun link ->
                            Journal_codec.links_applied_to_snapshot next [ link ]
                            && Option.fold
                                 ~none:false
                                 ~some:(fun (prior : t) ->
                                   List.exists
                                     (fun fact -> memory_id fact = link.superseded)
                                     prior.facts)
                                 previous)
                         declared_revisions
                     in
                     let* () =
                       List.fold_left
                         (fun result binding ->
                            let* () = result in
                            if not (List.mem binding.candidate_id explicit_candidate_ids)
                            then
                              Error
                                (store_error
                                   "recall binding does not name a consumed candidate")
                            else if
                              not
                                (List.exists
                                   (fun fact ->
                                      String.equal (memory_id fact) binding.target_memory_id)
                                   next.facts)
                            then
                              Error
                                (store_error
                                   "recall binding target is absent from final Memory")
                            else Ok ())
                         (Ok ())
                         admission_recall_bindings
                     in
                     (* [memory_id] hashes the claim text, so presence alone accepts a
                        target the keeper retracted and re-added while the decision ran,
                        and the binding would be born on the new incarnation after the
                        retirement its readers look for. A target retired after the
                        revision the decision read refuses the commit, and so does a
                        journal that cannot show every revision written since; the input
                        stays pending for a decision on current Memory. *)
                     let* () =
                       match pre_recall_checked with
                       | None -> Ok ()
                       | Some (_, Error detail) ->
                         Error (store_error ("recall binding retirement check: " ^ detail))
                       | Some (_, Ok retired) when Set_util.StringSet.is_empty retired -> Ok ()
                       | Some (_, Ok _) ->
                         Error
                           (store_error
                              "recall binding target was retired after the admission decision read Memory")
                     in
                     let* source_lines =
                       Keeper_memory_source_current.read_budget_lines ~keepers_dir ~keeper_id
                       |> Result.map_error store_error
                     in
                     let previous_bytes =
                       Keeper_memory_os_render.facts_payload_bytes
                         ~ordinary_facts:
                           (Option.fold
                              ~none:[]
                              ~some:(fun (snapshot : t) -> snapshot.facts)
                              previous)
                         ~source_lines
                     in
                     (* Non-blocking structural molt evaluation when a healthy
                        Librarian consolidator is active; fails closed at the
                        4x emergency backstop ONLY if the molt receiver is
                        uninstalled or Stopped. *)
                     let* budget_outcome =
                       match
                         Keeper_memory_os_render.evaluate_facts_budget
                           ~keeper_id
                           ~previous_bytes
                           ~ordinary_facts:next.facts
                           ~source_lines
                       with
                       | (Keeper_memory_os_render.Within_threshold _
                         | Keeper_memory_os_render.Molt_recommended _) as outcome ->
                         Ok outcome
                       | Keeper_memory_os_render.Backstop_exceeded
                           { budget; hard_limit_bytes; reason } ->
                         Error
                           (store_error
                              (Keeper_memory_os_render.backstop_rejection_message
                                 ~budget
                                 ~hard_limit_bytes
                                 ~reason))
                     in
                     let ranges =
                       Option.to_list (Option.map (fun range -> Atom_range range) durable_range_id)
                       @ Option.to_list
                           (Option.map (fun range -> Official_range range) official_range_id)
                       @ List.map
                           (fun candidate ->
                              match
                                List.find_opt
                                  (fun binding -> binding.candidate_id = candidate)
                                  admission_recall_bindings
                              with
                              | None -> Explicit_candidate candidate
                              | Some binding -> Explicit_candidate_with_recall binding)
                           explicit_candidate_ids
                     in
                     let* phase1_epoch_stamp = stat_stamp epoch_file_path in
                     let* phase1_unread_stamp = stat_stamp unread_file_path in
                     let* phase1_journal_stamp = stat_stamp journal_path in
                     let* phase1_range_stamp = stat_stamp range_receipt_path in
                     let* phase1_retraction_stamp = stat_stamp retraction_receipt_path in
                     Ok
                       (`Prepared
                          ( previous
                          , snapshot_content
                          , snapshot
                          , next
                          , output
                          , program
                          , applied_revision_links
                          , ranges
                          , durable_range_receipts
                          , budget_outcome
                          , phase1_epoch_stamp
                          , phase1_unread_stamp
                          , phase1_journal_stamp
                          , phase1_range_stamp
                          , phase1_retraction_stamp )))))
        in
        let* phase1 = phase1 in
        match phase1 with
        | `Retry_stale ->
          if attempt < max_cas_attempts
          then (
            yield_for_concurrent_writer ();
            write_attempt (attempt + 1))
          else
            Error
              (store_error
                 "current Memory OS snapshot changed repeatedly during commit preparation")
        | `Prepared
            ( previous
            , snapshot_content
            , snapshot
            , next
            , output
            , program
            , applied_revision_links
            , ranges
            , durable_range_receipts
            , budget_outcome
            , phase1_epoch_stamp
            , phase1_unread_stamp
            , phase1_journal_stamp
            , phase1_range_stamp
            , phase1_retraction_stamp ) ->
          (* Phase 2 (OUTSIDE ALL LOCKS): run fact-equality comparison and full
             JSON serialization on the CPU pool with ZERO Memory OS locks held. *)
          let prepared_payload =
            Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
              let kept =
                match equal_facts, snapshot with
                | Write_revision _, (Some _ | None) | Keep_stored, None -> None
                | Keep_stored, Some (current, current_content) when program = None ->
                  let same_facts =
                    Int.equal (List.compare_lengths current.facts next.facts) 0
                    && List.equal
                         (fun left right ->
                            left == right
                            || String.equal (fact_payload left) (fact_payload right))
                         current.facts
                         next.facts
                  in
                  if same_facts then Some (current, current_content) else None
                | Keep_stored, Some _ -> None
              in
              match kept with
              | Some (current, current_content) ->
                `Kept (current, current_content, sha256 current_content)
              | None ->
                let content = Snapshot_codec.snapshot_bytes next in
                `Write (content, sha256 content))
          in
          let observe snapshot commit_effect =
            Option.iter (fun notify -> notify snapshot commit_effect) on_committed;
            Option.iter (fun notify -> notify snapshot commit_effect output) observe_output
          in
          let receipts_for make =
            List.fold_left
              (fun receipts range_id ->
                 upsert_durable_range_receipt receipts (make range_id))
              durable_range_receipts
              ranges
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
          (* Phase 3 (SHORT COMMIT LOCK — ZERO Domain_pool_ref jobs inside):
             re-verify no concurrent commit touched snapshot/journal/receipts
             between Phase 1 and Phase 3, then perform atomic commit. *)
          let phase3 =
            Keeper_memory_os_aggregate_lock.with_lock
              ?clock
              ~keepers_dir
              ~keeper_id
              (fun () ->
                 File_lock_eio.with_lock ?clock snapshot_path (fun () ->
                   let* pending =
                     read_publication ~keepers_dir ~keeper_id
                     |> Result.map_error store_error
                   in
                   let* phase3_epoch_stamp = stat_stamp epoch_file_path in
                   let* phase3_unread_stamp = stat_stamp unread_file_path in
                   let* phase3_journal_stamp = stat_stamp journal_path in
                   let* phase3_range_stamp = stat_stamp range_receipt_path in
                   let* phase3_retraction_stamp = stat_stamp retraction_receipt_path in
                   let unchanged_since_phase1 =
                     Option.is_none pending
                     && Option.equal
                          String.equal
                          (Fs_compat.load_file_opt snapshot_path)
                          snapshot_content
                     && phase3_epoch_stamp = phase1_epoch_stamp
                     && phase3_unread_stamp = phase1_unread_stamp
                     && phase3_journal_stamp = phase1_journal_stamp
                     && phase3_range_stamp = phase1_range_stamp
                     && phase3_retraction_stamp = phase1_retraction_stamp
                   in
                   if not unchanged_since_phase1
                   then Ok `Retry_stale
                   else (
                     match prepared_payload with
                     | `Kept (current, _current_content, snapshot_sha256) ->
                       let* () =
                         match before_replace with
                         | None -> Ok ()
                         | Some write -> write ~previous ~next
                       in
                       protected (fun () ->
                         let+ () =
                           match ranges with
                           | [] -> Ok ()
                           | _ :: _ ->
                             write_durable_range_receipts
                               ~keepers_dir
                               ~keeper_id
                               (receipts_for (fun range_id ->
                                  Committed
                                    { range_id
                                    ; snapshot_revision = current.revision
                                    ; snapshot_sha256
                                    }))
                             |> Result.map_error store_error
                         in
                         observe current Unchanged;
                         append_journal_entry
                           ~commit_effect:Unchanged
                           ~revision_links:[]
                           ~keepers_dir
                           ~keeper_id
                           ~dropped_statements:
                             (Option.map (dropped_by_commit ~previous ~next) dropped_statements)
                           { next with revision = current.revision };
                         log_invalidations ~revision:current.revision;
                         `Committed (current, Unchanged, output))
                     | `Write (content, snapshot_sha256) ->
                       let* () =
                         match before_replace with
                         | None -> Ok ()
                         | Some write -> write ~previous ~next
                       in
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
                           when applied_revision_links <> []
                                || Option.fold ~none:false ~some:(( <> ) []) reasons ->
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
                           write_durable_range_receipts
                             ~keepers_dir
                             ~keeper_id
                             (receipts_for (fun range_id ->
                                Prepared
                                  { range_id
                                  ; snapshot_revision = next.revision
                                  ; snapshot_sha256
                                  }))
                           |> Result.map_error store_error
                       in
                       let publication_dropped =
                         match retraction_receipt with
                         | Some receipt -> Some receipt.dropped_statements
                         | None -> committed_dropped
                       in
                       let publication =
                         { phase = Publication_prepared
                         ; prior =
                             Option.map
                               (fun (prior, bytes) -> prior.revision, sha256 bytes)
                               snapshot
                         ; target_revision = next.revision
                         ; target_sha256 = snapshot_sha256
                         ; journal =
                             Journal_codec.journal_entry_to_json
                               ~commit_effect:Rewritten
                               ~revision_links:applied_revision_links
                               ~dropped_statements:publication_dropped
                               ?program
                               next
                         }
                       in
                       let* () =
                         write_publication ~keepers_dir ~keeper_id publication
                         |> Result.map_error store_error
                       in
                       let complete () =
                         owed := Health_input;
                         observe next Rewritten;
                         Keeper_memory_os_current_change_metrics.set_gauges
                           ~keeper_id
                           change_count
                           next;
                         rewritten := Some (next, output);
                         molt_outcome := Some budget_outcome;
                         let journal_result =
                           match finalize_journal ~keepers_dir ~keeper_id publication with
                           | Ok pending ->
                             owed := Commit_notification pending;
                             (match retraction_receipt with
                              | None -> Ok ()
                              | Some _ ->
                                remove_retraction_plan_receipt ~keepers_dir ~keeper_id)
                           | Error detail -> Error detail
                         in
                         (match ranges with
                          | [] -> ()
                          | _ :: _ ->
                            (match
                               write_durable_range_receipts
                                 ~keepers_dir
                                 ~keeper_id
                                 (receipts_for (fun range_id ->
                                    Committed
                                      { range_id
                                      ; snapshot_revision = next.revision
                                      ; snapshot_sha256
                                      }))
                             with
                             | Ok () -> ()
                             | Error detail ->
                               Log.Keeper.warn
                                 ~keeper_name:keeper_id
                                 "%s; prepared receipt remains recoverable"
                                 detail));
                         let* () =
                           match journal_result, retraction_plan with
                           | Ok (), _ -> Ok ()
                           | Error detail, None ->
                             Log.Keeper.warn
                               ~keeper_name:keeper_id
                               "memory revision=%d committed; publication recovery pending: %s"
                               next.revision
                               detail;
                             Ok ()
                           | Error detail, Some (plan_id, evidence_error) ->
                             Error
                               (evidence_error
                                  ~plan_id
                                  ~snapshot_revision:next.revision
                                  ~snapshot_sha256
                                  ~detail)
                         in
                         log_invalidations ~revision:next.revision;
                         Ok (`Committed (next, Rewritten, output))
                       in
                       let commit () =
                         match write_snapshot snapshot_path content with
                         | Ok () -> complete ()
                         | Error failure ->
                           (match failure.exception_ with
                            | Eio.Cancel.Cancelled _ ->
                              Printexc.raise_with_backtrace
                                failure.exception_
                                failure.backtrace
                            | _ ->
                              let failed outcome =
                                Error
                                  (store_error
                                     (Printf.sprintf
                                        "current Memory OS atomic write failed path=%s: %s: %s"
                                        snapshot_path
                                        outcome
                                        (Fs_compat.atomic_replace_failure_to_string failure)))
                              in
                              (match failure.stage with
                               | Fs_compat.After_rename
                                 when sync_snapshot snapshot_path = Ok () -> complete ()
                               | Fs_compat.After_rename ->
                                 Keeper_memory_os_current_change_metrics.set_gauges
                                   ~keeper_id
                                   change_count
                                   next;
                                 rewritten := Some (next, output);
                                 molt_outcome := Some budget_outcome;
                                 failed
                                   "snapshot replacement occurred but durability is unconfirmed; prepared receipts remain for recovery"
                               | Fs_compat.Before_rename ->
                                 failed "snapshot replacement did not occur"))
                       in
                       protected commit)))
          in
          let* phase3 = phase3 in
          (match phase3 with
           | `Committed res -> Ok res
           | `Retry_stale ->
             if attempt < max_cas_attempts
             then (
               yield_for_concurrent_writer ();
               write_attempt (attempt + 1))
             else
               Error
                 (store_error
                    "current Memory OS snapshot changed repeatedly during commit"))
    in
    let write () = write_attempt 0 in
    (* Count, announce, and dispatch non-blocking structural molt signal only
       after BOTH locks unwind. *)
    let count () =
      Option.iter
        (fun (snapshot, output) ->
           Keeper_memory_os_current_change_metrics.count_changes
             ~keeper_id change_count snapshot output)
        !rewritten
    in
    let notify_molt () =
      Option.iter
        (Keeper_memory_os_render.notify_molt_if_recommended ~keeper_id)
        !molt_outcome
    in
    match write () with
    | result -> count (); notify (); notify_molt (); result
    | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      count ();
      notify ();
      notify_molt ();
      Printexc.raise_with_backtrace exn backtrace)
;;

(* Explicit writes always write a revision, so their effect is [Rewritten].
   Supersession carries its own decision through the commit. *)
let update_locked_with_error
      ?clock
      ?dropped_statements
      ?retraction_plan
      ~change_count
      ~store_error
      ~keepers_dir
      ~keeper_id
      ~now
      build
  =
  update_locked_with_output
    ?clock ?dropped_statements ~change_count
    ~equal_facts:(Write_revision retraction_plan) ~store_error ~keepers_dir ~keeper_id ~now
    (fun ~snapshot_content previous ->
       let+ next = build ~snapshot_content previous in
       next, ())
  |> Result.map (fun (snapshot, (_ : commit_effect), ()) -> snapshot)
;;
