(* See .mli. *)

module Partition_generation = Keeper_board_attention_partition_generation

type delivery_failure_kind = Keeper_board_attention_candidate_wire.delivery_failure_kind =
  | Durable_delivery_unavailable

type delivery_failure = Keeper_board_attention_candidate_wire.delivery_failure =
  { kind : delivery_failure_kind
  ; detail : string
  ; failed_at : float
  }

type system_one_provenance = Keeper_board_attention_candidate_wire.system_one_provenance =
  { destination_uri : string
  ; answering_model_id : string
  ; request_body_sha256 : string
  }

type judgment_source = Keeper_board_attention_candidate_wire.judgment_source =
  | Exact_attempt of
      { call_id : string
      ; plan_fingerprint : string
      ; request_body_sha256 : string
      }
  | Cli_lane_slot
  | Vendor_system_one of system_one_provenance

type judgment = Keeper_board_attention_candidate_wire.judgment =
  { verdict : Keeper_board_attention_judgment.t
  ; slot_id : string
  ; source : judgment_source
  ; judged_at : float
  }

type delivery = Keeper_board_attention_candidate_wire.delivery =
  | Enqueued_to_keeper_lane
  | Not_relevant

(* v7 persists the current typed Board signal only. Historical post/comment
   snapshots are neither identity nor judgment input, so retaining them would
   make stale context look authoritative. RFC-0424. *)
type pending_state = Keeper_board_attention_candidate_wire.pending_state = { last_delivery_failure : delivery_failure option }

type judged_state = Keeper_board_attention_candidate_wire.judged_state =
  { judgment : judgment
  ; last_delivery_failure : delivery_failure option
  }

type consumed_state = Keeper_board_attention_candidate_wire.consumed_state =
  { judgment : judgment
  ; delivery : delivery
  ; consumed_at : float
  }

type resumable_status = Keeper_board_attention_candidate_wire.resumable_status =
  | Resumable_pending of pending_state
  | Resumable_judged of judged_state
  | Resumable_consumed of consumed_state

type quarantine_failure_category = Keeper_board_attention_candidate_wire.quarantine_failure_category =
  | Candidate_membership_conflict
  | Durable_partition_invariant
  | Exact_setup_unavailable
  | Exact_flow_replayed
  | Exact_lane_exhausted
  | Exact_flow_bookkeeping_failed
  | Exact_completion_failed
  | Domain_output_invalid
  | Execution_provenance_mismatch
  | Unexpected_worker_failure
  | Exact_execution_quarantined
  | Exact_execution_interrupted

type attempt_provenance = Keeper_board_attention_candidate_wire.attempt_provenance =
  { slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }

type quarantine = Keeper_board_attention_candidate_wire.quarantine =
  { quarantine_id : string
  ; partition_id : string
  ; partition_generation : Partition_generation.t
  ; failure_category : quarantine_failure_category
  ; attempt_provenance : attempt_provenance option
  ; quarantined_at : float
  ; prior_status : resumable_status
  }

type quarantine_phase = Keeper_board_attention_candidate_wire.quarantine_phase =
  | Quarantined
  | Requeue_requested of
      { requested_at : float
      ; requested_by : string
        (** The authenticated principal that asked for the requeue. *)
      }
  | Requeued of
      { requeued_at : float
      ; requested_by : string
        (** Carried from [Requeue_requested]: finishing the requeue does not
            change who asked for it. *)
      }

type quarantine_state = Keeper_board_attention_candidate_wire.quarantine_state =
  { quarantine : quarantine
  ; phase : quarantine_phase
  }

type status = Keeper_board_attention_candidate_wire.status =
  | Pending of pending_state
  | Judged of judged_state
  | Consumed of consumed_state
  | Quarantine of quarantine_state

type status_view = Keeper_board_attention_candidate_wire.status_view =
  | Direct_resumable of resumable_status
  | Requeued_resumable of
      { resumable : resumable_status
      ; quarantine : quarantine_state
      }
  | Suspended_quarantine of quarantine_state

type candidate = Keeper_board_attention_candidate_wire.candidate =
  { candidate_id : string
  ; keeper_name : string
  ; signal : Board_dispatch.board_signal
  ; keeper_context : Yojson.Safe.t
        (* 후보가 속한 파티션의 정체성이다 ([Context_key]). 소비된 뒤에도
           소속을 확인하므로 상태와 함께 사라지지 않는다. *)
  ; recorded_at : float
  ; status : status
  }

type record_result =
  | Recorded of candidate
  | Duplicate of candidate
  | Record_error of string

type persistence =
  | Candidate_recorded
  | Candidate_already_present

type wake_decision =
  | Judgment_worker_requested of Keeper_board_attention_worker_wake.wake_result
  | Wake_not_required

type record_acceptance =
  { candidate : candidate
  ; persistence : persistence
  ; wake : wake_decision
  }

exception Candidate_unavailable of string

let candidate_dir base_path =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path)
    "board_attention_candidates"
;;

let candidate_path ~base_path ~keeper_name =
  Filename.concat
    (candidate_dir base_path)
    (Workspace_utils_backend_setup.sanitize_namespace_segment keeper_name ^ ".jsonl")
;;

let ledger_path = candidate_path

include
  (Keeper_board_attention_candidate_wire :
    module type of Keeper_board_attention_candidate_wire
      with type delivery_failure_kind := delivery_failure_kind
       and type delivery_failure := delivery_failure
       and type system_one_provenance := system_one_provenance
       and type judgment_source := judgment_source
       and type judgment := judgment
       and type delivery := delivery
       and type pending_state := pending_state
       and type judged_state := judged_state
       and type consumed_state := consumed_state
       and type resumable_status := resumable_status
       and type quarantine_failure_category := quarantine_failure_category
       and type attempt_provenance := attempt_provenance
       and type quarantine := quarantine
       and type quarantine_phase := quarantine_phase
       and type quarantine_state := quarantine_state
       and type status := status
       and type status_view := status_view
       and type candidate := candidate
       and module Partition_generation := Partition_generation)

let report_rejected_rows ~context rejected =
  match rejected with
  | [] -> ()
  | (line_number, detail) :: _ ->
    Log.Keeper.warn
      "candidate ledger %s: skipped %d unreadable row(s); first is line %d: %s"
      context
      (List.length rejected)
      line_number
      detail
;;

(* Ledger store.

   Every access to a ledger path goes through the [Fs_compat] private JSONL
   stable-lock transaction family: readers take the bytes after a known
   cursor, writers append at that cursor, and compaction rewrites at it. The
   temp+rename family must not touch the same path; its rename would strand an
   appender on the old inode (see the contract on
   [Fs_compat.append_private_jsonl_durable_locked_at_cursor_result]).

   One in-process state per ledger path is the latest-row-per-id projection
   readers get; the file is its durable log. Before this, every update
   re-parsed and rewrote the whole ledger; measured 2026-09-05 on a 25 MB
   ledger, that was ~4.5 GB allocated per 4 minutes across the fleet (RFC
   main-domain-scheduler-latency §8, P4a). *)
type ledger_state =
  { by_id : (int * candidate) Candidate_map.t
    (* first index among the decoded rows on disk, and the latest row of that id *)
  ; latest : candidate list (* [by_id] in first-index order; what readers get *)
  ; decoded_rows : int (* rows on disk the decoder accepted; also the next first index *)
  ; rejected_rows : int (* rows on disk the decoder refused *)
  ; cursor : Fs_compat.Private_jsonl_cursor.t (* store identity and end offset *)
  }

type ledger_entry =
  { ledger_mutex : Cross_context_mutex.t
  ; mutable ledger_cache : ledger_state option
    (* [None]: unknown; the next access reads the whole store *)
  }

let ledger_registry : (string, ledger_entry) Hashtbl.t = Hashtbl.create 16

(* The registry mutex guards only the table lookup, which never yields, so a
   Stdlib mutex is enough there and it works from systhreads and other domains.

   The per-path lock is held across the whole store transaction, and from an
   Eio fiber that transaction runs its Unix I/O in a systhread
   ([Fs_compat.run_blocking_private_file_transaction]), so the holder yields
   while locked. A Stdlib mutex there made any other fiber on the same domain
   that touched the same ledger re-lock the domain's own mutex:
   [Sys_error "Mutex.lock: Resource deadlock avoided"], four keepers each
   losing a turn in the first seconds after the 2026-09-05 boot (#33322).
   [Cross_context_mutex] makes an Eio waiter yield instead, and still
   serialises against systhread and other-domain callers through its Stdlib
   half. *)
let ledger_registry_mutex = Stdlib.Mutex.create ()

let ledger_entry path =
  Stdlib.Mutex.protect ledger_registry_mutex (fun () ->
    match Hashtbl.find_opt ledger_registry path with
    | Some entry -> entry
    | None ->
      let entry = { ledger_mutex = Cross_context_mutex.create (); ledger_cache = None } in
      Hashtbl.add ledger_registry path entry;
      entry)
;;

let empty_ledger_state cursor =
  { by_id = Candidate_map.empty
  ; latest = []
  ; decoded_rows = 0
  ; rejected_rows = 0
  ; cursor
  }
;;

let apply_decoded_rows state rows =
  let decoded_rows, by_id =
    index_rows ~decoded_rows:state.decoded_rows ~by_id:state.by_id rows
  in
  { state with by_id; latest = ordered_latest by_id; decoded_rows }
;;

let store_error = Fs_compat.private_jsonl_transaction_error_to_string

let observe_settlement_warning ~path error =
  Log.Keeper.error
    "board attention candidate ledger: descriptor settlement incomplete path=%s detail=%s"
    path
    (store_error error)
;;

let snapshot_result ~path result =
  match Fs_compat.private_jsonl_snapshot_success_receipt result with
  | Error error -> Error (store_error error)
  | Ok { Fs_compat.value; settlement_error } ->
    Option.iter (observe_settlement_warning ~path) settlement_error;
    Ok value
;;

let cursor_result ~path result =
  match Fs_compat.private_jsonl_cursor_success_receipt result with
  | Error error -> Error (store_error error)
  | Ok { Fs_compat.value; settlement_error } ->
    Option.iter (observe_settlement_warning ~path) settlement_error;
    Ok value
;;

let apply_snapshot ~path state (snapshot : Fs_compat.private_jsonl_snapshot) =
  let { rows; rejected } = parse_rows snapshot.Fs_compat.bytes in
  report_rejected_rows ~context:path rejected;
  let state = apply_decoded_rows state rows in
  { state with
    rejected_rows = state.rejected_rows + List.length rejected
  ; cursor = snapshot.Fs_compat.cursor
  }
;;

(* Under [entry.ledger_mutex]. Reads only the bytes after the cached cursor. A
   replaced, truncated, or removed store is a [Cursor_mismatch]; the cache is
   dropped and the state rebuilt from a whole-store read. Any other failure
   drops the cache so the next access reads the store again. *)
let rec refresh_ledger ~path entry =
  let after = Option.map (fun state -> state.cursor) entry.ledger_cache in
  match Fs_compat.read_private_jsonl_durable_locked_result path ~after with
  | Error (Fs_compat.Cursor_mismatch _) when Option.is_some after ->
    entry.ledger_cache <- None;
    refresh_ledger ~path entry
  | result ->
    (match snapshot_result ~path result with
     | Error error ->
       entry.ledger_cache <- None;
       Error error
     | Ok snapshot ->
       let base =
         match entry.ledger_cache with
         | Some state -> state
         | None -> empty_ledger_state snapshot.Fs_compat.cursor
       in
       let state = apply_snapshot ~path base snapshot in
       entry.ledger_cache <- Some state;
       Ok state)
;;

(* Rejections are returned, not only logged: a caller that must fail closed on
   an unreadable row can see it, and a test can name the reason. Callers that
   only want the readable candidates use [load_candidates]. This read takes the
   whole store and leaves the cache alone. *)
let load_candidates_with_rejections ~base_path ~keeper_name =
  let path = candidate_path ~base_path ~keeper_name in
  let* snapshot =
    Fs_compat.read_private_jsonl_durable_locked_result path ~after:None
    |> snapshot_result ~path
  in
  let { rows; rejected } = parse_rows snapshot.Fs_compat.bytes in
  report_rejected_rows ~context:path rejected;
  Ok (latest_candidates rows, rejected)
;;

let load_candidates ~base_path ~keeper_name =
  let path = candidate_path ~base_path ~keeper_name in
  let entry = ledger_entry path in
  Cross_context_mutex.with_lock entry.ledger_mutex (fun () ->
    Result.map (fun state -> state.latest) (refresh_ledger ~path entry))
;;

let append_row candidate = Yojson.Safe.to_string (candidate_to_json candidate) ^ "\n"

let serialize_candidates candidates =
  String.concat "" (List.map append_row candidates)
;;

(* Dead rows on disk stay bounded by the live set: a write that would leave
   more than [compaction_ratio] times as many decoded rows as live candidates
   rewrites the store as the latest set instead of appending, so the file
   holds at most [compaction_ratio * live] rows plus the rows of that write.
   A store containing rejected rows stays append-only. Rewriting only decoded
   candidates would erase unknown pending obligations and the evidence needed
   for an explicit repair. Reading and appending valid candidates still work. *)
let compaction_ratio = 2

let needs_compaction ~decoded_rows ~rejected_rows ~live =
  rejected_rows = 0 && decoded_rows > compaction_ratio * live
;;

let validate_for_persistence candidates =
  List.fold_left
    (fun validation candidate ->
       let* () = validation in
       validate_candidate_for_persistence candidate)
    (Ok ())
    candidates
;;

(* Only the rows this write persists are validated; rows already on disk
   passed validation when they were written, and refusing to compact them
   would wedge the ledger behind a rule tightened since. *)
let update_ledger_many ~base_path ~keeper_name decide =
  let path = candidate_path ~base_path ~keeper_name in
  let entry = ledger_entry path in
  try
    Cross_context_mutex.with_durable_lock entry.ledger_mutex (fun () ->
      let* state = refresh_ledger ~path entry in
      match decide state.latest with
      | Error _ as error -> error
      | Ok (None, result) -> Ok result
      | Ok (Some updated, result) ->
        let* () = validate_for_persistence updated in
        let appended = apply_decoded_rows state updated in
        let compact =
          needs_compaction
            ~decoded_rows:appended.decoded_rows
            ~rejected_rows:appended.rejected_rows
            ~live:(Candidate_map.cardinal appended.by_id)
        in
        let written =
          if compact
          then
            Fs_compat.rewrite_private_jsonl_durable_locked_at_cursor_result
              path
              ~expected:state.cursor
              (serialize_candidates appended.latest)
          else
            Fs_compat.append_private_jsonl_durable_locked_at_cursor_result
              path
              ~expected:state.cursor
              (serialize_candidates updated)
        in
        (match cursor_result ~path written with
         | Error error ->
           entry.ledger_cache <- None;
           Error error
         | Ok cursor ->
           let next =
             if compact
             then apply_decoded_rows (empty_ledger_state cursor) appended.latest
             else { appended with cursor }
           in
           entry.ledger_cache <- Some next;
           Ok result))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Printf.sprintf
         "Board attention ledger update failed keeper=%s path=%s: %s"
         keeper_name
         path
         (Printexc.to_string exn))
;;

let update_ledger ~base_path ~keeper_name decide =
  update_ledger_many ~base_path ~keeper_name (fun candidates ->
    match decide candidates with
    | Error _ as error -> error
    | Ok (None, result) -> Ok (None, result)
    | Ok (Some candidate, result) -> Ok (Some [ candidate ], result))
;;

let purge ~base_path ~keeper_name =
  let path = candidate_path ~base_path ~keeper_name in
  let entry = ledger_entry path in
  Cross_context_mutex.with_durable_lock entry.ledger_mutex (fun () ->
    (* Keep the registry entry: a queued writer must not acquire a different
       mutex after purge. Invalidate even on failure, which may follow unlink. *)
    entry.ledger_cache <- None;
    Fs_compat.purge_private_jsonl_durable_locked_result path
    |> cursor_result ~path
    |> Result.map (fun _cursor -> ()))
;;


(* The replay gate's coordinate for a signal: exactly what the world
   observation scanner compares against the keeper's Board cursor
   (keeper_world_observation.ml signal_after_cursor), which pairs every
   comment's creation time with its parent post id. post_created carries
   its creation time only while the post is unedited — an edit mints
   post_updated with the edit timestamp instead — and comments carry their
   creation time, so the token of a persisted signal never moves (#41422).
   Reactions and votes have no replay coordinate: the replay path never
   mints them, only the live emit does. *)
let signal_cursor_token (signal : Board_dispatch.board_signal) =
  match signal.kind with
  | Board_dispatch.Board_post_created ->
    Option.map (fun ts -> ts, signal.post_id) signal.updated_at
  | Board_dispatch.Board_post_updated { content_updated_at } ->
    Some (content_updated_at, signal.post_id)
  | Board_dispatch.Board_comment_added _ ->
    Option.map (fun ts -> ts, signal.post_id) signal.updated_at
  | Board_dispatch.Board_reaction_changed _
  | Board_dispatch.Board_vote_cast _ -> None
;;

(* A Consumed candidate at or before the keeper's Board cursor can never be
   re-minted by the replay gate, so removing its row cannot resurrect the
   event. A consumed row ahead of the cursor, a row without a replay
   coordinate, and every non-terminal status stay. *)
let removable_consumed ~cursor candidate =
  match candidate.status with
  | Consumed _ -> (
    match signal_cursor_token candidate.signal with
    | Some token ->
      Board_signal.compare_cursor_token
        token
        (fst cursor, Option.value ~default:"" (snd cursor))
      <= 0
    | None -> false)
  | Pending _ | Judged _ | Quarantine _ -> false
;;

(* Under the ledger lock. A prune rewrites the whole store instead of
   appending: dropping rows through the append path would leave the consumed
   rows on disk and re-run this rewrite decision on every wake, growing the
   file without bound. The rewrite carries exactly the kept rows, so rejected
   rows must block it — their "no rewrite until repaired" rule is what makes
   this a no-op (0) instead of a data loss. The rewrite is at-cursor: a
   concurrent keeper process that moves the cursor makes the whole prune fail
   instead of dropping that process's row. *)
let prune_consumed_behind_cursor ~base_path ~keeper_name cursor =
  let path = candidate_path ~base_path ~keeper_name in
  let entry = ledger_entry path in
  try
    Cross_context_mutex.with_durable_lock entry.ledger_mutex (fun () ->
      let* state = refresh_ledger ~path entry in
      if state.rejected_rows > 0
      then Ok 0
      else
        let kept =
          List.filter
            (fun candidate -> not (removable_consumed ~cursor candidate))
            state.latest
        in
        let removed = List.length state.latest - List.length kept in
        if removed = 0
        then Ok 0
        else
          let* () = validate_for_persistence kept in
          let written =
            Fs_compat.rewrite_private_jsonl_durable_locked_at_cursor_result
              path
              ~expected:state.cursor
              (serialize_candidates kept)
          in
          let* cursor = cursor_result ~path written in
          let next =
            apply_decoded_rows (empty_ledger_state cursor) kept
          in
          entry.ledger_cache <- Some next;
          Ok removed)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Printf.sprintf
         "Board attention candidate ledger prune failed keeper=%s path=%s: %s"
         keeper_name
         path
         (Printexc.to_string exn))
;;

let find_candidate candidates candidate_id =
  List.find_opt
    (fun candidate -> String.equal candidate.candidate_id candidate_id)
    candidates
;;

let record ~base_path candidate =
  match validate_candidate_for_persistence candidate with
  | Error detail -> Record_error ("invalid Board attention candidate: " ^ detail)
  | Ok () ->
    (match
       update_ledger
         ~base_path
         ~keeper_name:candidate.keeper_name
         (fun candidates ->
            match find_candidate candidates candidate.candidate_id with
            | None -> Ok (Some candidate, Recorded candidate)
            | Some existing
              when signal_identity_equal existing.signal candidate.signal ->
              Ok (None, Duplicate existing)
            | Some _ ->
              Error
                "candidate identity conflict: the same candidate_id has a different Board signal identity")
     with
     | Ok result -> result
     | Error detail -> Record_error detail)
;;

let update_candidate ~base_path candidate_id keeper_name transition =
  update_ledger ~base_path ~keeper_name (fun candidates ->
    match find_candidate candidates candidate_id with
    | None -> Error (Printf.sprintf "Board attention candidate not found: %s" candidate_id)
    | Some current ->
      (match transition current with
       | None -> Ok (None, current)
       | Some updated -> Ok (Some updated, updated)))
;;

let same_delivery_failure left right =
  left.kind = right.kind && String.equal left.detail right.detail
;;

let same_judgment_source left right =
  match left, right with
  | Cli_lane_slot, Cli_lane_slot -> true
  | Vendor_system_one left, Vendor_system_one right ->
    String.equal left.destination_uri right.destination_uri
    && String.equal left.answering_model_id right.answering_model_id
    && String.equal left.request_body_sha256 right.request_body_sha256
  | ( Exact_attempt left
    , Exact_attempt right ) ->
    String.equal left.call_id right.call_id
    && String.equal left.plan_fingerprint right.plan_fingerprint
    && String.equal left.request_body_sha256 right.request_body_sha256
  | Cli_lane_slot, (Exact_attempt _ | Vendor_system_one _)
  | Exact_attempt _, (Cli_lane_slot | Vendor_system_one _)
  | Vendor_system_one _, (Cli_lane_slot | Exact_attempt _) -> false
;;

let same_judgment left right =
  left.verdict = right.verdict
  && String.equal left.slot_id right.slot_id
  && same_judgment_source left.source right.source
  && Float.equal left.judged_at right.judged_at
;;

let replace_resumable_status status resumable =
  match status with
  | Pending _ | Judged _ | Consumed _ -> status_of_resumable resumable
  | Quarantine ({ quarantine; phase = Requeued _ } as state) ->
    Quarantine
      { state with
        quarantine = { quarantine with prior_status = resumable }
      }
  | Quarantine ({ phase = (Quarantined | Requeue_requested _); _ } as state) ->
    Quarantine state
;;

let resumable_with_delivery_failure resumable failure =
  match resumable with
  | Resumable_pending pending ->
    (match pending.last_delivery_failure with
     | Some existing when same_delivery_failure existing failure -> resumable
     | Some _ | None ->
       Resumable_pending { last_delivery_failure = Some failure })
  | Resumable_judged judged ->
    (match judged.last_delivery_failure with
     | Some existing when same_delivery_failure existing failure -> resumable
     | Some _ | None ->
       Resumable_judged { judged with last_delivery_failure = Some failure })
  | Resumable_consumed _ -> resumable
;;

let candidate_with_delivery_failure current failure =
  match status_view current.status with
  | Suspended_quarantine _ -> current
  | Direct_resumable resumable
  | Requeued_resumable { resumable; _ } ->
    let updated = resumable_with_delivery_failure resumable failure in
    if updated = resumable
    then current
    else { current with status = replace_resumable_status current.status updated }
;;

let record_delivery_failure ~base_path candidate failure =
  update_candidate
    ~base_path
    candidate.candidate_id
    candidate.keeper_name
    (fun current ->
       let updated = candidate_with_delivery_failure current failure in
       if updated = current then None else Some updated)
;;

let record_judgment ~base_path candidate judgment =
  update_ledger ~base_path ~keeper_name:candidate.keeper_name (fun candidates ->
    match find_candidate candidates candidate.candidate_id with
    | None ->
      Error
        (Printf.sprintf
           "Board attention candidate not found: %s"
           candidate.candidate_id)
    | Some current ->
      (match status_view current.status with
       | Direct_resumable (Resumable_pending _)
       | Requeued_resumable { resumable = Resumable_pending _; _ } ->
         let updated =
           { current with
             status =
               status_of_resumable
                 (Resumable_judged
                    { judgment; last_delivery_failure = None })
           }
         in
         Ok (Some updated, updated)
       | Direct_resumable (Resumable_judged judged)
       | Requeued_resumable
           { resumable = Resumable_judged judged; _ }
         when same_judgment judged.judgment judgment ->
         Ok (None, current)
       | Direct_resumable (Resumable_consumed consumed)
       | Requeued_resumable
           { resumable = Resumable_consumed consumed; _ }
         when same_judgment consumed.judgment judgment ->
         Ok (None, current)
       | Direct_resumable (Resumable_judged _ | Resumable_consumed _)
       | Requeued_resumable
           { resumable = (Resumable_judged _ | Resumable_consumed _); _ } ->
         Error
           ("Board attention candidate judgment conflict: "
            ^ candidate.candidate_id)
       | Suspended_quarantine _ ->
         Error
           ("Quarantined Board attention candidate cannot be judged: "
            ^ candidate.candidate_id)))
;;

let mark_consumed ~base_path candidate judgment delivery =
  update_ledger ~base_path ~keeper_name:candidate.keeper_name (fun candidates ->
    match find_candidate candidates candidate.candidate_id with
    | None ->
      Error
        (Printf.sprintf
           "Board attention candidate not found: %s"
           candidate.candidate_id)
    | Some current ->
      (match status_view current.status with
       | Direct_resumable (Resumable_judged judged)
       | Requeued_resumable
           { resumable = Resumable_judged judged; _ }
         when same_judgment judged.judgment judgment ->
         let updated =
           { current with
             status =
               status_of_resumable
                 (Resumable_consumed
                    { judgment; delivery; consumed_at = Time_compat.now () })
           }
         in
         Ok (Some updated, updated)
       | Direct_resumable (Resumable_consumed consumed)
       | Requeued_resumable
           { resumable = Resumable_consumed consumed; _ }
         when same_judgment consumed.judgment judgment
              && consumed.delivery = delivery -> Ok (None, current)
       | Direct_resumable (Resumable_pending _)
       | Requeued_resumable { resumable = Resumable_pending _; _ } ->
         Error
           ("Pending Board attention candidate cannot be consumed: "
            ^ candidate.candidate_id)
       | Direct_resumable (Resumable_judged _ | Resumable_consumed _)
       | Requeued_resumable
           { resumable = (Resumable_judged _ | Resumable_consumed _); _ } ->
         Error
           ("Board attention candidate consumption conflict: "
            ^ candidate.candidate_id)
       | Suspended_quarantine _ ->
         Error
           ("Quarantined Board attention candidate cannot be consumed: "
            ^ candidate.candidate_id)))
;;

let quarantine_id
      ~candidate_id
      ~partition_id
      ~partition_generation
      ~failure_category
      ~attempt_provenance
      ~quarantined_at
  =
  let provenance =
    match attempt_provenance with
    | None -> [ "" ]
    | Some provenance ->
      [ provenance.slot_id
      ; provenance.call_id
      ; provenance.plan_fingerprint
      ; provenance.request_body_sha256
      ]
  in
  String.concat
    "\000"
    ([ candidate_id
     ; partition_id
     ; Yojson.Safe.to_string
         (Partition_generation.to_yojson partition_generation)
     ; quarantine_failure_category_to_string failure_category
     ; Printf.sprintf "%.17g" quarantined_at
     ]
     @ provenance)
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
  |> ( ^ ) "ba-quarantine-"
;;

let normalize_requeued_consumed ~base_path ~keeper_name ~candidate_id =
  update_ledger ~base_path ~keeper_name (fun candidates ->
    match find_candidate candidates candidate_id with
    | None -> Error ("Board attention candidate not found: " ^ candidate_id)
    | Some current ->
      (match current.status with
       | Consumed _ -> Ok (None, current)
       | Quarantine
           { quarantine = { prior_status = Resumable_consumed consumed; _ }
           ; phase = Requeued _
           } ->
         let updated = { current with status = Consumed consumed } in
         Ok (Some updated, updated)
       | Pending _ | Judged _ | Quarantine _ ->
         Error
           ("Board attention candidate is not requeued-consumed: "
            ^ candidate_id)))
;;

let same_quarantine_identity left right =
  String.equal left.quarantine_id right.quarantine_id
  && String.equal left.partition_id right.partition_id
  && Partition_generation.equal
       left.partition_generation
       right.partition_generation
;;

let quarantine
      ~base_path
      ~(candidate : candidate)
      ~partition_id
      ~partition_generation
      ~failure_category
      ~attempt_provenance
      ~quarantined_at
  =
  let quarantine_id =
    quarantine_id
      ~candidate_id:candidate.candidate_id
      ~partition_id
      ~partition_generation
      ~failure_category
      ~attempt_provenance
      ~quarantined_at
  in
  update_ledger ~base_path ~keeper_name:candidate.keeper_name (fun candidates ->
    match find_candidate candidates candidate.candidate_id with
    | None ->
      Error ("Board attention candidate not found: " ^ candidate.candidate_id)
    | Some current ->
      let prior_status =
        match status_view current.status with
        | Direct_resumable status
        | Requeued_resumable { resumable = status; _ } -> status
        | Suspended_quarantine state -> state.quarantine.prior_status
      in
      let requested =
        { quarantine_id
        ; partition_id
        ; partition_generation
        ; failure_category
        ; attempt_provenance
        ; quarantined_at
        ; prior_status
        }
      in
      (match current.status with
       | Quarantine state
         when same_quarantine_identity state.quarantine requested ->
         Ok (None, current)
       (* The same partition is Blocked again at a strictly later generation. Only
          that newest block can be requeued, so it replaces the unfinished
          quarantine, and the prior domain status carries over. *)
       | Quarantine
           { quarantine = held; phase = (Quarantined | Requeue_requested _) }
         when String.equal held.partition_id partition_id
              && Partition_generation.is_later
                   ~previous:held.partition_generation partition_generation ->
         let updated =
           { current with
             status = Quarantine { quarantine = requested; phase = Quarantined }
           }
         in
         Ok (Some updated, updated)
       | Quarantine { phase = (Quarantined | Requeue_requested _); _ } ->
         Error
           ("candidate quarantine conflicts with partition or generation: "
            ^ current.candidate_id)
       | Pending _ | Judged _ | Consumed _ | Quarantine { phase = Requeued _; _ } ->
         let updated =
           { current with
             status = Quarantine { quarantine = requested; phase = Quarantined }
           }
         in
         Ok (Some updated, updated)))
;;

let request_quarantine_requeue
      ~base_path
      ~(candidate : candidate)
      ~partition_id
      ~expected_quarantine_id
      ~requested_at
      ~requested_by
  =
  update_ledger ~base_path ~keeper_name:candidate.keeper_name (fun candidates ->
    match find_candidate candidates candidate.candidate_id with
    | None ->
      Error ("Board attention candidate not found: " ^ candidate.candidate_id)
    | Some current ->
      (match current.status with
       | Quarantine ({ quarantine; phase = Quarantined } as state)
         when String.equal quarantine.partition_id partition_id
              && String.equal quarantine.quarantine_id expected_quarantine_id ->
         let updated =
           { current with
             status =
               Quarantine
                 { state with
                   phase = Requeue_requested { requested_at; requested_by }
                 }
           }
         in
         Ok (Some updated, updated)
       | Quarantine
           { quarantine
           ; phase = (Requeue_requested _ | Requeued _)
           }
         when String.equal quarantine.partition_id partition_id
              && String.equal quarantine.quarantine_id expected_quarantine_id ->
         Ok (None, current)
       | Pending _ | Judged _ | Consumed _ | Quarantine _ ->
         Error
           ("candidate quarantine generation does not match operator request: "
            ^ current.candidate_id)))
;;

let finish_quarantine_requeue
      ~base_path
      ~(candidate : candidate)
      ~partition_id
      ~expected_quarantine_id
      ~requeued_at
  =
  update_ledger ~base_path ~keeper_name:candidate.keeper_name (fun candidates ->
    match find_candidate candidates candidate.candidate_id with
    | None ->
      Error ("Board attention candidate not found: " ^ candidate.candidate_id)
    | Some current ->
      (match current.status with
       | Quarantine
           ({ quarantine; phase = Requeue_requested { requested_by; _ } } as state)
         when String.equal quarantine.partition_id partition_id
              && String.equal quarantine.quarantine_id expected_quarantine_id ->
         let updated =
           { current with
             status =
               Quarantine
                 { state with phase = Requeued { requeued_at; requested_by } }
           }
         in
         Ok (Some updated, updated)
       | Quarantine { quarantine; phase = Requeued _ }
         when String.equal quarantine.partition_id partition_id
              && String.equal quarantine.quarantine_id expected_quarantine_id ->
         Ok (None, current)
       | Pending _ | Judged _ | Consumed _ | Quarantine _ ->
         Error
           ("candidate is not in the requested requeue generation: "
            ^ current.candidate_id)))
;;

let delivery_failure ~kind detail =
  { kind; detail; failed_at = Time_compat.now () }
;;

let board_attention_stimulus candidate =
  { Keeper_event_queue.post_id = candidate.signal.post_id
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = candidate.recorded_at
  ; payload =
      Keeper_event_queue.Board_attention
        { candidate_id = candidate.candidate_id
        ; signal = Board_signal.board_stimulus_of_board_signal candidate.signal
        }
  }
;;

let observe_wakeup ~site candidate = function
  | Keeper_registry.Signaled ->
    Log.Keeper.info
      "Board attention owner lane signaled keeper=%s candidate=%s site=%s"
      candidate.keeper_name
      candidate.candidate_id
      site
  | Keeper_registry.Deferred_unregistered ->
    Log.Keeper.info
      "Board attention candidate durable; owner lane unregistered keeper=%s \
       candidate=%s site=%s"
      candidate.keeper_name
      candidate.candidate_id
      site
  | Keeper_registry.Deferred_not_running phase ->
    Log.Keeper.info
      "Board attention candidate durable; owner lane not running keeper=%s \
       candidate=%s phase=%s site=%s"
      candidate.keeper_name
      candidate.candidate_id
      (Keeper_state_machine.phase_to_string phase)
      site
  | Keeper_registry.Deferred_lifecycle denial ->
    Log.Keeper.info
      "Board attention candidate durable; owner lane lifecycle-deferred \
       keeper=%s candidate=%s reason=%s site=%s"
      candidate.keeper_name
      candidate.candidate_id
      (Keeper_lifecycle_admission.autonomous_denial_to_wire denial)
      site
;;

let request_owner_wake ~site ~base_path candidate =
  let outcome =
    Keeper_registry.wakeup_running
      ~intent:Keeper_registry.Reactive_signal
      ~base_path
      candidate.keeper_name
  in
  observe_wakeup ~site candidate outcome;
  outcome
;;

let consume_judged ~base_path candidate (judged : judged_state) =
  match judged.judgment.verdict.decision with
  | Keeper_board_attention_judgment.Not_relevant ->
    mark_consumed ~base_path candidate judged.judgment Not_relevant
  | Keeper_board_attention_judgment.Relevant ->
    let stimulus = board_attention_stimulus candidate in
    (match
       Keeper_registry_event_queue.enqueue_if_missing_durable_result
         ~base_path
         ~event_id:candidate.candidate_id
         candidate.keeper_name
         stimulus
     with
     | Keeper_registry_event_queue.Enqueued
     | Keeper_registry_event_queue.Already_present ->
       let* consumed =
         mark_consumed
           ~base_path
           candidate
           judged.judgment
           Enqueued_to_keeper_lane
       in
       let (_ : Keeper_registry.wakeup_outcome) =
         request_owner_wake ~site:"durable_delivery" ~base_path consumed
       in
       Ok consumed
     | Keeper_registry_event_queue.Identity_conflict detail
     | Keeper_registry_event_queue.Storage_error detail ->
       record_delivery_failure
         ~base_path
         candidate
         (delivery_failure ~kind:Durable_delivery_unavailable detail))
;;

let record_and_wake ~base_path candidate =
  let request_worker persisted =
    let* wake =
      Keeper_board_attention_worker_wake.request
        ~base_path
        ~keeper_name:persisted.keeper_name
    in
    Ok (Judgment_worker_requested wake)
  in
  match record ~base_path candidate with
  | Record_error detail -> Error detail
  | Recorded persisted ->
    let* wake = request_worker persisted in
    Ok { candidate = persisted; persistence = Candidate_recorded; wake }
  | Duplicate persisted ->
    let* wake =
      match status_view persisted.status with
      | Direct_resumable (Resumable_pending _ | Resumable_judged _)
      | Requeued_resumable
          { resumable = (Resumable_pending _ | Resumable_judged _); _ } ->
        request_worker persisted
      | Direct_resumable (Resumable_consumed _)
      | Requeued_resumable { resumable = Resumable_consumed _; _ }
      | Suspended_quarantine _ -> Ok Wake_not_required
    in
    Ok
      { candidate = persisted
      ; persistence = Candidate_already_present
      ; wake
      }
;;

type judgment_delivery_outcome =
  | Delivered of candidate
  | Candidate_absent
      (** The candidate this partition's [Completed] item names is not in the
          live ledger. A retire moves the whole candidate store aside as one
          directory (scripts/check-runtime-deployment-preflight.sh); it never
          leaves a tombstone the live ledger can read back, so this cannot
          distinguish "retired" from any other cause a candidate is gone —
          both mean the same thing for this delivery: it cannot succeed on a
          retry of the identical request, because the row it would update no
          longer exists. Every other failure below stays a typed [Error],
          because those represent a live candidate in an unexpected state,
          which is a bug this function must keep reporting loudly rather than
          quietly resolve. *)

let apply_judgment_and_deliver ~base_path ~keeper_name ~candidate_id ~judgment =
  let* candidates = load_candidates ~base_path ~keeper_name in
  match find_candidate candidates candidate_id with
  | None -> Ok Candidate_absent
  | Some candidate ->
    let* judged_candidate =
      match status_view candidate.status with
      | Direct_resumable (Resumable_pending _)
      | Requeued_resumable { resumable = Resumable_pending _; _ } ->
        record_judgment ~base_path candidate judgment
      | Direct_resumable (Resumable_judged judged)
      | Requeued_resumable
          { resumable = Resumable_judged judged; _ }
        when same_judgment judged.judgment judgment ->
        Ok candidate
      | Direct_resumable (Resumable_consumed consumed)
      | Requeued_resumable
          { resumable = Resumable_consumed consumed; _ }
        when same_judgment consumed.judgment judgment ->
        Ok candidate
      | Direct_resumable (Resumable_judged _ | Resumable_consumed _)
      | Requeued_resumable
          { resumable = (Resumable_judged _ | Resumable_consumed _); _ } ->
        Error ("Board attention candidate judgment conflicts with worker result: " ^ candidate_id)
      | Suspended_quarantine _ ->
        Error
          ("Quarantined or requeue-requested Board attention candidate cannot be settled: "
           ^ candidate_id)
    in
    let* delivered_candidate =
      match status_view judged_candidate.status with
      | Direct_resumable (Resumable_consumed _)
      | Requeued_resumable { resumable = Resumable_consumed _; _ } ->
        normalize_requeued_consumed ~base_path ~keeper_name ~candidate_id
      | Direct_resumable (Resumable_pending _)
      | Requeued_resumable { resumable = Resumable_pending _; _ } ->
        Error ("Board attention candidate remained Pending after judgment commit: " ^ candidate_id)
      | Direct_resumable (Resumable_judged judged)
      | Requeued_resumable
          { resumable = Resumable_judged judged; _ } ->
        let* delivered = consume_judged ~base_path judged_candidate judged in
        (match status_view delivered.status with
         | Direct_resumable (Resumable_consumed _)
         | Requeued_resumable { resumable = Resumable_consumed _; _ } ->
           normalize_requeued_consumed ~base_path ~keeper_name ~candidate_id
         | Direct_resumable (Resumable_pending _ | Resumable_judged _)
         | Requeued_resumable
             { resumable = (Resumable_pending _ | Resumable_judged _); _ } ->
           Error
             ("Board attention candidate delivery did not reach Consumed: "
              ^ candidate_id)
         | Suspended_quarantine _ ->
           Error
             ("Board attention candidate became quarantined during delivery: "
              ^ candidate_id))
      | Suspended_quarantine _ ->
        Error
          ("Quarantined or requeue-requested Board attention candidate cannot be settled: "
           ^ candidate_id)
    in
    Ok (Delivered delivered_candidate)
;;
