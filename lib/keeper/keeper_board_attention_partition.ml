(* See .mli. *)

include Keeper_board_attention_partition_types
module Id_map = Map.Make (String)
module Id_set = Set.Make (String)

module Worker_epoch = struct
  include Keeper_board_attention_partition_types.Worker_epoch

  (* NDT-OK: entropy is opaque process identity only; scheduling never branches
     on random contents. Stdlib mutex is required because generation can occur
     before or outside an Eio scheduler and the critical section never yields. *)
  let rng = Random.State.make_self_init ()
  let mutex = Stdlib.Mutex.create ()

  let generate () =
    Stdlib.Mutex.protect mutex (fun () -> Uuidm.v4_gen rng ())
  ;;

end

let ( let* ) = Result.bind

type ready_confirmation =
  Keeper_board_attention_partition_wire.ready_confirmation =
  { partition_id : string
  ; generation : Generation.t
  ; confirmed_at : float
  ; runtime_instance_id : string
  }

let state_to_string = Keeper_board_attention_partition_wire.state_to_string
let to_yojson = Keeper_board_attention_partition_wire.to_yojson
let of_yojson = Keeper_board_attention_partition_wire.of_yojson
let confirmed_ready_to_yojson = Keeper_board_attention_partition_wire.confirmed_ready_to_yojson
let parse = Keeper_board_attention_partition_wire.parse
let serialize = Keeper_board_attention_partition_wire.serialize
let serialize_confirmations = Keeper_board_attention_partition_wire.serialize_confirmations

let partition_dir base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "board_attention_partitions"
;;

let path ~base_path ~keeper_name =
  Filename.concat
    (partition_dir base_path)
    (Workspace_utils_backend_setup.sanitize_namespace_segment keeper_name ^ ".jsonl")
;;

let framed values =
  values
  |> List.map (fun value -> Printf.sprintf "%d:%s" (String.length value) value)
  |> String.concat ""
;;

let root_id ~keeper_name ~context_key ~candidate_id =
  let payload =
    framed
      [ "singleton"
      ; keeper_name
      ; Candidate.Context_key.to_canonical_string context_key
      ; candidate_id
      ]
  in
  "ba-root-" ^ Digestif.SHA256.(digest_string payload |> to_hex)
;;

module Ready_order = struct
  type nonrec t =
    { created_at : float
    ; partition_id : string
    }

  let compare left right =
    match Float.compare left.created_at right.created_at with
    | 0 -> String.compare left.partition_id right.partition_id
    | ordering -> ordering
  ;;
end

module Ready_set = Set.Make (Ready_order)

type view =
  { cursor : Fs_compat.Private_jsonl_cursor.t
  ; by_id : t Id_map.t
  ; ready : Ready_set.t
  ; completed : Id_set.t
  ; live_candidate_owner : string Id_map.t
  }

let empty_view cursor =
  { cursor
  ; by_id = Id_map.empty
  ; ready = Ready_set.empty
  ; completed = Id_set.empty
  ; live_candidate_owner = Id_map.empty
  }
;;

let is_live = function
  | Ready | Running _ | Completed _ | Blocked _ -> true
  | Settled _ | Abandoned _ -> false
;;

let compare_partition left right =
  match Float.compare left.created_at right.created_at with
  | 0 -> String.compare left.partition_id right.partition_id
  | ordering -> ordering
;;

let ready_order partition : Ready_order.t =
  { created_at = partition.created_at; partition_id = partition.partition_id }
;;

let remove_partition_indexes view partition =
  let ready =
    match partition.state with
    | Ready -> Ready_set.remove (ready_order partition) view.ready
    | Running _ | Completed _ | Settled _ | Abandoned _ | Blocked _ -> view.ready
  in
  let completed =
    match partition.state with
    | Completed _ -> Id_set.remove partition.partition_id view.completed
    | Ready | Running _ | Settled _ | Abandoned _ | Blocked _ -> view.completed
  in
  let live_candidate_owner =
    if is_live partition.state
    then Id_map.remove partition.candidate_id view.live_candidate_owner
    else view.live_candidate_owner
  in
  { view with ready; completed; live_candidate_owner }
;;

let add_partition_indexes view partition =
  let* live_candidate_owner =
    if not (is_live partition.state)
    then Ok view.live_candidate_owner
    else
      match Id_map.find_opt partition.candidate_id view.live_candidate_owner with
      | None ->
        Ok
          (Id_map.add
             partition.candidate_id
             partition.partition_id
             view.live_candidate_owner)
      | Some existing ->
        Error
          (Printf.sprintf
             "candidate %s belongs to live partitions %s and %s"
             partition.candidate_id
             existing
             partition.partition_id)
  in
  let ready =
    match partition.state with
    | Ready -> Ready_set.add (ready_order partition) view.ready
    | Running _ | Completed _ | Settled _ | Abandoned _ | Blocked _ -> view.ready
  in
  let completed =
    match partition.state with
    | Completed _ -> Id_set.add partition.partition_id view.completed
    | Ready | Running _ | Settled _ | Abandoned _ | Blocked _ -> view.completed
  in
  Ok
    { view with
      by_id = Id_map.add partition.partition_id partition view.by_id
    ; ready
    ; completed
    ; live_candidate_owner
    }
;;

let same_partition_identity (left : t) (right : t) =
  String.equal left.partition_id right.partition_id
  && String.equal left.keeper_name right.keeper_name
  && Candidate.Context_key.equal left.context_key right.context_key
  && String.equal left.candidate_id right.candidate_id
  && Float.equal left.created_at right.created_at
;;

let legal_transition previous next =
  match previous, next with
  | Ready, Running { progress = Unbound; _ } -> true
  (* Any running progress may return to [Ready]: an Unbound claim at process
     start, a bound run a restart cut, and a run whose lane was exhausted
     ([defer]). The judgment is a read-only model call, so a new claim that
     dispatches again spends tokens and nothing else. *)
  | Running _, Ready -> true
  | Running { progress = Unbound; _ }, Running { progress = Bound _; _ } -> true
  | Running { progress = Unbound; _ }, Running { progress = Advancing _; _ } -> true
  | Running { progress = Unbound; _ }, Completed _ -> true
  | Running { progress = Bound _; _ }, Running { progress = Advancing _; _ } -> true
  | Running { progress = Advancing _; _ }, Running { progress = Advancing _; _ } ->
    true
  | Running { progress = Advancing _; _ }, Running { progress = Bound _; _ } -> true
  | Running { progress = Bound _; _ }, Completed _ -> true
  (* Only a CLI tail answer completes from [Advancing]: the tail runs after
     AGENT_CORE ended the HTTP walk, so the named next slot is never bound.
     [complete] makes the same check before it appends the row. *)
  | ( Running { progress = Advancing _; _ }
    , Completed { item = { judgment = { source = Candidate.Cli_lane_slot; _ }; _ }; _ } )
    -> true
  | Running _, Blocked _ -> true
  | Blocked _, Ready -> true
  | (Completed _ | Blocked _), Settled _ -> true
  | Blocked _, Abandoned _ -> true
  | Abandoned _, Ready -> true
  | Ready, _
  | Running _, _
  | Completed _, _
  | Settled _, _
  | Abandoned _, _
  | Blocked _, _ -> false
;;

let validate_root_identity partition =
  let expected =
    root_id
      ~keeper_name:partition.keeper_name
      ~context_key:partition.context_key
      ~candidate_id:partition.candidate_id
  in
  if String.equal expected partition.partition_id
  then Ok ()
  else
    Error
      (Printf.sprintf
         "partition root identity mismatch expected=%s observed=%s"
         expected
         partition.partition_id)
;;

let apply_row view partition =
  let* () = validate_root_identity partition in
  match Id_map.find_opt partition.partition_id view.by_id with
  | None -> add_partition_indexes view partition
  | Some previous ->
    if not (same_partition_identity previous partition)
    then Error ("partition changed immutable identity: " ^ partition.partition_id)
    else if previous = partition
    then Ok view
    else if
      not
        (Generation.is_direct_successor
           ~previous:previous.generation
           partition.generation)
    then
      Error
        (Printf.sprintf
           "partition %s generation is not the direct successor"
           partition.partition_id)
    else if not (legal_transition previous.state partition.state)
    then
      Error
        (Printf.sprintf
           "partition %s illegal transition %s -> %s"
           partition.partition_id
           (state_to_string previous.state)
           (state_to_string partition.state))
    else
      add_partition_indexes (remove_partition_indexes view previous) partition
;;

let apply_rows view rows =
  List.fold_left
    (fun result partition ->
       let* view = result in
       apply_row view partition)
    (Ok view)
    rows
;;

let view_partitions view =
  view.by_id
  |> Id_map.bindings
  |> List.map snd
  |> List.sort compare_partition
;;

type cache_entry =
  { cached : view option Atomic.t
  ; mutation_mutex : Stdlib.Mutex.t
  }

let cache_registry : (string, cache_entry) Hashtbl.t = Hashtbl.create 32
let cache_registry_mutex = Stdlib.Mutex.create ()

let cache_entry ledger_path =
  Stdlib.Mutex.protect cache_registry_mutex (fun () ->
    match Hashtbl.find_opt cache_registry ledger_path with
    | Some entry -> entry
    | None ->
      let entry =
        { cached = Atomic.make None; mutation_mutex = Stdlib.Mutex.create () }
      in
      Hashtbl.add cache_registry ledger_path entry;
      entry)
;;

let run_blocking label operation =
  match Eio.Fiber.is_cancelled () with
  | true | false -> Eio_unix.run_in_systhread ~label operation
  | exception Effect.Unhandled _ -> operation ()
;;

let store_error = Fs_compat.private_jsonl_transaction_error_to_string

let observe_settlement_warning ~ledger_path error =
  Log.Keeper.error
    "board_attention_partition: descriptor settlement incomplete ledger=%s detail=%s"
    ledger_path
    (store_error error)
;;

let snapshot_result ~ledger_path result =
  match Fs_compat.private_jsonl_snapshot_success_receipt result with
  | Error error -> Error (store_error error)
  | Ok { value; settlement_error } ->
    Option.iter (observe_settlement_warning ~ledger_path) settlement_error;
    Ok value
;;

let cursor_result ~ledger_path result =
  match Fs_compat.private_jsonl_cursor_success_receipt result with
  | Error error -> Error (store_error error)
  | Ok { value; settlement_error } ->
    Option.iter (observe_settlement_warning ~ledger_path) settlement_error;
    Ok value
;;

let exact_cursor_result ~ledger_path result =
  match Fs_compat.private_jsonl_cursor_success_receipt result with
  | Error error -> Error (store_error error)
  | Ok { value; settlement_error = None } -> Ok (value, Fsync_completed)
  | Ok { value; settlement_error = Some error } ->
    observe_settlement_warning ~ledger_path error;
    Ok (value, Visible_sync_unconfirmed (store_error error))
;;

let invalidate_cached entry observed =
  (* fire-and-forget: false means a concurrent writer won; the loser simply keeps no stale cache *)
  ignore (Atomic.compare_and_set entry.cached observed None : bool)
;;

let publish_cached entry observed view =
  (* fire-and-forget: false means a concurrent writer won; readers fall back to recomputing *)
  ignore (Atomic.compare_and_set entry.cached observed (Some view) : bool)
;;

let read_view_blocking ledger_path =
  let entry = cache_entry ledger_path in
  let observed = Atomic.get entry.cached in
  let after = Option.map (fun view -> view.cursor) observed in
  match
    Fs_compat.read_private_jsonl_durable_locked_result ledger_path ~after
    |> snapshot_result ~ledger_path
  with
  | Error error ->
    invalidate_cached entry observed;
    Error error
  | Ok snapshot ->
    let* rows, _confirmations = parse snapshot.bytes in
    let base =
      match observed with
      | Some view -> view
      | None -> empty_view snapshot.cursor
    in
    let* view = apply_rows base rows in
    let view = { view with cursor = snapshot.cursor } in
    publish_cached entry observed view;
    Ok view
;;

let read_view ledger_path =
  run_blocking "board-attention-partition-read" (fun () ->
    let entry = cache_entry ledger_path in
    Stdlib.Mutex.protect entry.mutation_mutex (fun () -> read_view_blocking ledger_path))
;;

let validate_keeper_identity ~keeper_name view =
  Id_map.fold
    (fun _ partition result ->
       let* () = result in
       if String.equal partition.keeper_name keeper_name
       then Ok ()
       else
         Error
           (Printf.sprintf
              "Board attention partition keeper mismatch expected=%s actual=%s partition=%s"
              keeper_name
              partition.keeper_name
              partition.partition_id))
    view.by_id
    (Ok ())
;;

let load ~base_path ~keeper_name =
  let* view = read_view (path ~base_path ~keeper_name) in
  let* () = validate_keeper_identity ~keeper_name view in
  Ok (view_partitions view)
;;

let purge ~base_path ~keeper_name =
  let ledger_path = path ~base_path ~keeper_name in
  run_blocking "board-attention-partition-purge" (fun () ->
    let entry = cache_entry ledger_path in
    Stdlib.Mutex.protect entry.mutation_mutex (fun () ->
      (* Never replace this entry while another transaction can be waiting on
         its mutex. A failed purge can already have unlinked the old inode. *)
      Atomic.set entry.cached None;
      Fs_compat.purge_private_jsonl_durable_locked_result ledger_path
      |> cursor_result ~ledger_path
      |> Result.map (fun _cursor -> ())))
;;

let update ~base_path ~keeper_name decide =
  let ledger_path = path ~base_path ~keeper_name in
  run_blocking "board-attention-partition-update" (fun () ->
    let entry = cache_entry ledger_path in
    Stdlib.Mutex.protect entry.mutation_mutex (fun () ->
      let* view = read_view_blocking ledger_path in
      let* () = validate_keeper_identity ~keeper_name view in
      let* rows, result = decide view in
      match rows with
      | [] -> Ok result
      | _ :: _ ->
        let* updated = apply_rows view rows in
        let suffix = serialize rows in
        (match
           Fs_compat.append_private_jsonl_durable_locked_at_cursor_result
             ledger_path
             ~expected:view.cursor
             suffix
           |> cursor_result ~ledger_path
         with
         | Error error -> Error error
         | Ok cursor ->
           Atomic.set entry.cached (Some { updated with cursor });
           Ok result)))
;;

let update_exact ?ready_confirmation ~base_path ~keeper_name decide =
  let ledger_path = path ~base_path ~keeper_name in
  run_blocking "board-attention-partition-exact-update" (fun () ->
    let entry = cache_entry ledger_path in
    Stdlib.Mutex.protect entry.mutation_mutex (fun () ->
      let* view = read_view_blocking ledger_path in
      let* () = validate_keeper_identity ~keeper_name view in
      let* rows, result = decide view in
      match rows with
      | [] -> Error "exact partition update must append a cursor-fenced row"
      | _ :: _ ->
        let* updated = apply_rows view rows in
        let* suffix =
          match ready_confirmation, rows with
          | None, _ -> Ok (serialize rows)
          | Some partition, [ row ] when row = partition ->
            let confirmation =
              { partition_id = partition.partition_id
              ; generation = partition.generation
              ; confirmed_at = Time_compat.now ()
              ; runtime_instance_id = Build_identity.runtime_instance_id
              }
            in
            Ok
              (Yojson.Safe.to_string (confirmed_ready_to_yojson row confirmation)
               ^ "\n")
          | Some _, _ -> Error "Ready confirmation must append its exact Ready row"
        in
        (match
           Fs_compat.append_private_jsonl_durable_locked_at_cursor_result
             ledger_path
             ~expected:view.cursor
             suffix
           |> exact_cursor_result ~ledger_path
         with
         | Error error -> Error error
         | Ok (cursor, write_outcome) ->
           Atomic.set entry.cached (Some { updated with cursor });
           Ok (result, write_outcome))))
;;

let compare_candidate left right =
  match Float.compare left.Candidate.recorded_at right.Candidate.recorded_at with
  | 0 -> String.compare left.candidate_id right.candidate_id
  | ordering -> ordering
;;

let valid_time label value =
  if Float.is_finite value then Ok () else Error (label ^ " must be finite")
;;

let nonempty label value =
  if String.equal (String.trim value) "" then Error (label ^ " must not be empty") else Ok ()
;;

let validate_judgment (judgment : Candidate.judgment) =
  let* () = nonempty "partition judgment slot_id" judgment.slot_id in
  let* () =
    match judgment.source with
    | Candidate.Cli_lane_slot -> Ok ()
    | Candidate.Vendor_system_one provenance ->
      let* () =
        nonempty
          "partition judgment vendor destination"
          provenance.destination_uri
      in
      let* () =
        nonempty
          "partition judgment vendor answering identity"
          provenance.answering_model_id
      in
      let* () =
        nonempty
          "partition judgment vendor request digest"
          provenance.request_body_sha256
      in
      if String.equal judgment.slot_id provenance.answering_model_id
      then Ok ()
      else Error "partition judgment vendor identity must equal slot_id"
    | Candidate.Exact_attempt { call_id; plan_fingerprint; request_body_sha256 } ->
      let* () = nonempty "partition judgment call_id" call_id in
      let* () = nonempty "partition judgment plan_fingerprint" plan_fingerprint in
      nonempty "partition judgment request_body_sha256" request_body_sha256
  in
  let* () = valid_time "partition judgment judged_at" judgment.judged_at in
  Keeper_board_attention_judgment.of_yojson
    (Keeper_board_attention_judgment.to_yojson judgment.verdict)
  |> Result.map ignore
;;

let validate_exact_provenance (provenance : exact_provenance) =
  let* () = nonempty "partition exact provenance slot_id" provenance.slot_id in
  let* () = nonempty "partition exact provenance call_id" provenance.call_id in
  let* () =
    nonempty
      "partition exact provenance plan_fingerprint"
      provenance.plan_fingerprint
  in
  nonempty
    "partition exact provenance request_body_sha256"
    provenance.request_body_sha256
;;

let exact_provenance_equal
      (left : exact_provenance)
      (right : exact_provenance)
  =
  String.equal left.slot_id right.slot_id
  && String.equal left.call_id right.call_id
  && String.equal left.plan_fingerprint right.plan_fingerprint
  && String.equal left.request_body_sha256 right.request_body_sha256
;;

let candidate_visit_equal left right =
  String.equal left.flow_id right.flow_id
  && Int.equal left.ordinal right.ordinal
  && String.equal left.slot_id right.slot_id
  && String.equal
       left.catalog_generation_fingerprint
       right.catalog_generation_fingerprint
  && String.equal left.catalog_evidence_sha256 right.catalog_evidence_sha256
  && String.equal
       left.target_identity_fingerprint
       right.target_identity_fingerprint
;;

let advance_source_slot_id = function
  | Executed_failure provenance -> provenance.slot_id
  | Predispatch_rejection visit -> visit.slot_id
;;

let validate_candidate_visit visit =
  let* () = nonempty "partition candidate visit flow_id" visit.flow_id in
  let* () =
    if visit.ordinal >= 0
    then Ok ()
    else Error "partition candidate visit ordinal must be nonnegative"
  in
  let* () = nonempty "partition candidate visit slot_id" visit.slot_id in
  let* () =
    nonempty
      "partition candidate visit catalog_generation_fingerprint"
      visit.catalog_generation_fingerprint
  in
  let* () =
    nonempty
      "partition candidate visit catalog_evidence_sha256"
      visit.catalog_evidence_sha256
  in
  nonempty
    "partition candidate visit target_identity_fingerprint"
    visit.target_identity_fingerprint
;;

let validate_advance_source = function
  | Executed_failure provenance -> validate_exact_provenance provenance
  | Predispatch_rejection visit -> validate_candidate_visit visit
;;

(* A CLI-slot or vendor judgment has no attempt to project: [None] is the
   answer, not a blank record. Its completion is checked by a different rule
   below. *)
let judgment_provenance (judgment : Candidate.judgment) =
  match judgment.source with
  | Candidate.Cli_lane_slot | Candidate.Vendor_system_one _ -> None
  | Candidate.Exact_attempt { call_id; plan_fingerprint; request_body_sha256 } ->
    Some
      { slot_id = judgment.slot_id
      ; call_id
      ; plan_fingerprint
      ; request_body_sha256
      }
;;

let validate_durable_progress = function
  | Bound provenance -> validate_exact_provenance provenance
  | Advancing { execution_anchor; last_from; next } ->
    let* () =
      match execution_anchor with
      | Some provenance -> validate_exact_provenance provenance
      | None -> Ok ()
    in
    let* () =
      match last_from with
      | Some visit -> validate_candidate_visit visit
      | None -> Ok ()
    in
    let* () =
      match execution_anchor, last_from with
      | None, None ->
        Error "advancing progress requires an execution anchor or rejected visit"
      | _ -> Ok ()
    in
    validate_candidate_visit next
  | Unbound -> Error "unbound execution cannot retain durable progress"
;;

let validate_classified_failure detail progress =
  let* () = nonempty "classified execution failure detail" detail in
  match progress with
  | Some progress -> validate_durable_progress progress
  | None -> Ok ()
;;

let validate_blocked_reason = function
  | Candidate_membership_conflict detail ->
    nonempty "candidate membership conflict detail" detail
  | Durable_partition_invariant detail ->
    nonempty "durable partition invariant detail" detail
  | Exact_setup_unavailable detail ->
    nonempty "exact setup unavailable detail" detail
  | Exact_flow_replayed (Some progress) -> validate_durable_progress progress
  | Exact_flow_replayed None -> Ok ()
  | Exact_lane_exhausted { detail; progress }
  | Exact_flow_bookkeeping_failed { detail; progress }
  | Exact_completion_failed { detail; progress }
  | Domain_output_invalid { detail; progress }
  | Execution_provenance_mismatch { detail; progress }
  | Unexpected_worker_failure { detail; progress } ->
    validate_classified_failure detail progress
  | Exact_execution_quarantined progress -> validate_durable_progress progress
  | Exact_execution_interrupted progress -> validate_durable_progress progress
  | Restored_candidate_quarantine { failure_category = _; attempt_provenance } ->
    (match attempt_provenance with
     | None -> Ok ()
     | Some provenance ->
       validate_exact_provenance
         { slot_id = provenance.slot_id
         ; call_id = provenance.call_id
         ; plan_fingerprint = provenance.plan_fingerprint
         ; request_body_sha256 = provenance.request_body_sha256
         })
;;

let advance_state partition state =
  if partition.state = state
  then Ok partition
  else
    let* generation = Generation.next partition.generation in
    Ok { partition with generation; state }
;;

let ensure_roots_with_reader ~base_path ~keeper_name read_candidates =
  update ~base_path ~keeper_name (fun view ->
    let* candidates = read_candidates () in
    let* roots =
      candidates
      |> List.sort compare_candidate
      |> List.fold_left
           (fun result (candidate : Candidate.candidate) ->
              let* roots = result in
              if not (String.equal candidate.keeper_name keeper_name)
              then Error "candidate Keeper differs from partition ledger Keeper"
              else
                let* () = valid_time "candidate recorded_at" candidate.recorded_at in
                let resolve_root ~reopen_abandoned () =
                  let* context_key = Candidate.Context_key.of_candidate candidate in
                  match Id_map.find_opt candidate.candidate_id view.live_candidate_owner with
                  | Some owner_id ->
                    (match Id_map.find_opt owner_id view.by_id with
                     | Some owner
                       when Candidate.Context_key.equal owner.context_key context_key ->
                       Ok roots
                     | Some owner ->
                       Error
                         (Printf.sprintf
                            "candidate %s authority differs from live partition %s"
                            candidate.candidate_id
                            owner.partition_id)
                     | None -> Error ("live owner index lost partition " ^ owner_id))
                  | None ->
                    let partition_id =
                      root_id ~keeper_name ~context_key ~candidate_id:candidate.candidate_id
                    in
                    (match Id_map.find_opt partition_id view.by_id with
                     | None ->
                       Ok
                         ({ partition_id
                          ; keeper_name
                          ; context_key
                          ; candidate_id = candidate.candidate_id
                          ; created_at = candidate.recorded_at
                          ; generation = Generation.initial
                          ; state = Ready
                          }
                          :: roots)
                     | Some historical
                       when String.equal historical.candidate_id candidate.candidate_id
                            && Candidate.Context_key.equal historical.context_key context_key ->
                       (* [candidate_id] is the stable typed Board-event identity and
                          [root_id] hashes it with this exact context. [recorded_at]
                          deliberately participates in neither identity. A compacted
                          candidate ledger can be reconstructed after its partition
                          has already settled, giving the same event a later
                          observation time. Requiring that volatile time here turned
                          the deterministic root into a collision with itself and
                          stopped the whole Keeper's attention worker. *)
                       (match historical.state with
                        | Abandoned _ when reopen_abandoned ->
                          (* [reopen_abandoned] is true only for a candidate
                             still [Resumable_pending]: the Candidate ledger
                             never recorded any judgment for it, so an
                             [Abandoned] root can only be the "candidate
                             permanently absent" give-up in
                             [reconcile_quarantines], which never writes a
                             judgment. A [Resumable_judged] or
                             [Requeued_resumable] historical match keeps the
                             no-op: those already carry (or are
                             mid-quarantine toward) a judgment, and reopening
                             them here would race the dedicated
                             quarantine-generation bookkeeping in
                             [reconcile_quarantines] instead of going through
                             it. [Settled] never reopens: it records a
                             judgment. *)
                          let* reopened = advance_state historical Ready in
                          Ok (reopened :: roots)
                        | Ready
                        | Running _
                        | Completed _
                        | Blocked _
                        | Settled _
                        | Abandoned _ -> Ok roots)
                     | Some _ -> Error ("partition identity collision: " ^ partition_id))
                in
                let restore_quarantined_root
                      (quarantine : Candidate.quarantine)
                  =
                  let* context_key = Candidate.Context_key.of_candidate candidate in
                  let partition_id =
                    root_id
                      ~keeper_name
                      ~context_key
                      ~candidate_id:candidate.candidate_id
                  in
                  let* () =
                    if String.equal partition_id quarantine.partition_id
                    then Ok ()
                    else
                      Error
                        ("candidate quarantine names a different partition: "
                         ^ candidate.candidate_id)
                  in
                  match Id_map.find_opt partition_id view.by_id with
                  | Some partition
                    when String.equal partition.candidate_id candidate.candidate_id
                         && Candidate.Context_key.equal partition.context_key context_key
                    -> Ok roots
                  | Some _ -> Error ("partition identity collision: " ^ partition_id)
                  | None ->
                    Ok
                      ({ partition_id
                       ; keeper_name
                       ; context_key
                       ; candidate_id = candidate.candidate_id
                       ; created_at = candidate.recorded_at
                       ; generation = quarantine.partition_generation
                       ; state =
                           Blocked
                             { reason =
                                 Restored_candidate_quarantine
                                   { failure_category = quarantine.failure_category
                                   ; attempt_provenance = quarantine.attempt_provenance
                                   }
                             ; blocked_at = quarantine.quarantined_at
                             }
                       }
                       :: roots)
                in
                match Candidate.status_view candidate.status with
                | Candidate.Suspended_quarantine state
                | Candidate.Requeued_resumable { quarantine = state; _ } ->
                  restore_quarantined_root state.quarantine
                | Candidate.Direct_resumable (Candidate.Resumable_consumed _) ->
                  Ok roots
                | Candidate.Direct_resumable (Candidate.Resumable_pending _) ->
                  resolve_root ~reopen_abandoned:true ()
                | Candidate.Direct_resumable (Candidate.Resumable_judged _)
                  -> resolve_root ~reopen_abandoned:false ())
           (Ok [])
      |> Result.map List.rev
    in
    Ok (roots, List.length roots))
;;

let ensure_roots ~base_path ~keeper_name candidates =
  ensure_roots_with_reader ~base_path ~keeper_name (fun () -> Ok candidates)
;;

let ensure_current_roots ~base_path ~keeper_name candidates =
  ensure_roots_with_reader ~base_path ~keeper_name (fun () ->
    (* The partition mutation lock encloses this candidate read and the root
       append. Purge removes candidates before partitions: a stale request
       either finishes before partition purge or sees the missing candidate.
       Re-reading before taking the partition lock would leave that race open. *)
    let* current = Candidate.load_candidates ~base_path ~keeper_name in
    if List.for_all (fun candidate -> List.mem candidate current) candidates
    then Ok candidates
    else Error "Board attention candidates changed before root restoration")
;;

type settled_receipt_gate =
  | Keep_all_settled
  | Drop_unless_open of Id_set.t (* candidate ids still non-terminal *)

let settled_receipt_droppable gate (partition : t) =
  match gate with
  | Keep_all_settled -> false
  | Drop_unless_open open_candidates ->
    not (Id_set.mem partition.candidate_id open_candidates)
;;

(* #41422: a settled receipt is droppable unless its candidate is still
   non-terminal on the candidate ledger — Pending, Judged, or in quarantine.
   Such a candidate replayed later must still find the settled root instead of
   re-minting a Ready root and re-running the judgment. A Consumed candidate,
   or one already pruned from the candidate ledger by the cursor-gated
   cleanup, adds nothing durable to the receipt, so the receipt goes with it.
   An unreadable candidate ledger keeps every receipt: nothing here loses the
   durable judgment record. The caller holds the partition mutation lock. *)
let settled_receipt_gate ~base_path ~keeper_name view =
  let has_settled =
    List.exists
      (fun (partition : t) ->
         match partition.state with
         | Settled _ -> true
         | Ready | Running _ | Completed _ | Abandoned _ | Blocked _ -> false)
      view
  in
  if not has_settled
  then Drop_unless_open Id_set.empty
  else
    match Candidate.load_candidates_with_rejections ~base_path ~keeper_name with
    | Error _ | Ok (_, _ :: _) ->
      (* Unreadable ledger, or rows the decoder refused: the hidden
         candidate may be non-terminal, so every receipt stays. *)
      Keep_all_settled
    | Ok (candidates, []) ->
      Drop_unless_open
        (Id_set.of_list
           (List.filter_map
              (fun (candidate : Candidate.candidate) ->
                 match candidate.status with
                 | Candidate.Consumed _ -> None
                 | Candidate.Pending _ | Candidate.Judged _
                 | Candidate.Quarantine _ -> Some candidate.candidate_id)
              candidates))
;;

let recover_for_process_start ~now ~base_path ~keeper_name =
  let* () = valid_time "partition process-start recovery time" now in
  let ledger_path = path ~base_path ~keeper_name in
  run_blocking "board-attention-partition-process-start" (fun () ->
    let entry = cache_entry ledger_path in
    Stdlib.Mutex.protect entry.mutation_mutex (fun () ->
      match
        (* Process-start recovery only: a torn tail from a mid-append crash is
           truncated to the last complete row; general reads keep hard-failing. *)
        Fs_compat.recover_private_jsonl_durable_locked_result ledger_path
        |> snapshot_result ~ledger_path
      with
      | Error error -> Error error
      | Ok snapshot ->
        let* rows, confirmations = parse snapshot.bytes in
        let* current = apply_rows (empty_view snapshot.cursor) rows in
        let* () = validate_keeper_identity ~keeper_name current in
        let view = view_partitions current in
        let settled_receipt_gate = settled_receipt_gate ~base_path ~keeper_name view in
        let* recovered, latest =
          view
          |> List.fold_left
               (fun result partition ->
                  let* recovered, latest = result in
                  match partition.state with
                  | Running _ ->
                    (* A restart that cut a run is not a judgment about its
                       candidate. The judgment lane is a read-only model
                       call and every claim starts a fresh AGENT_CORE flow
                       with its own flow id, so the next claim re-dispatches
                       without meeting the cut run's attempt. The live
                       ledger held 49 cut runs on 2026-09-26, each waiting
                       for an operator requeue before this returned them. *)
                    let* released = advance_state partition Ready in
                    Ok (recovered + 1, released :: latest)
                  | Settled _ when settled_receipt_droppable settled_receipt_gate partition ->
                    (* The candidate ledger holds the terminal judgment or
                       no candidate at all, so the receipt adds nothing
                       durable. Keeping every settled receipt made the
                       partition ledger grow with consumed board events,
                       one row per judgment, for the keeper's whole life. *)
                    Ok (recovered, latest)
                  | Ready | Completed _ | Settled _ | Abandoned _ | Blocked _ ->
                    Ok (recovered, partition :: latest))
               (Ok (0, []))
        in
        let latest = List.rev latest in
        let canonical = serialize latest ^ serialize_confirmations confirmations in
        if String.equal canonical snapshot.bytes
        then (
          Atomic.set entry.cached (Some current);
          Ok recovered)
        else
          (match
             Fs_compat.rewrite_private_jsonl_durable_locked_at_cursor_result
               ledger_path
               ~expected:snapshot.cursor
               canonical
             |> cursor_result ~ledger_path
           with
           | Error error -> Error error
           | Ok cursor ->
             let* compacted = apply_rows (empty_view cursor) latest in
             Atomic.set entry.cached (Some compacted);
             Ok recovered)))
;;

(* Startup recovery is not the only place a settled receipt can go: a Keeper
   that stays up drains for its whole run, and each judgment it settles would
   otherwise leave one row until the next restart. This applies the same gate
   on a drain, without releasing [Running] roots, which only a restart cuts. *)
let prune_settled_receipts ~base_path ~keeper_name =
  let ledger_path = path ~base_path ~keeper_name in
  run_blocking "board-attention-partition-settled-prune" (fun () ->
    let entry = cache_entry ledger_path in
    Stdlib.Mutex.protect entry.mutation_mutex (fun () ->
      let* cached = read_view_blocking ledger_path in
      let* () = validate_keeper_identity ~keeper_name cached in
      let any_settled =
        Id_map.exists
          (fun _ (partition : t) ->
             match partition.state with
             | Settled _ -> true
             | Ready | Running _ | Completed _ | Abandoned _ | Blocked _ -> false)
          cached.by_id
      in
      if not any_settled
      then Ok 0
      else
        (* The rewrite must carry every row and confirmation, so it reads the
           whole ledger rather than the cached view. *)
        match
          Fs_compat.read_private_jsonl_durable_locked_result ledger_path ~after:None
          |> snapshot_result ~ledger_path
        with
        | Error error -> Error error
        | Ok snapshot ->
          let* rows, confirmations = parse snapshot.bytes in
          let* current = apply_rows (empty_view snapshot.cursor) rows in
          let* () = validate_keeper_identity ~keeper_name current in
          let view = view_partitions current in
          let gate = settled_receipt_gate ~base_path ~keeper_name view in
          let kept =
            List.filter
              (fun (partition : t) ->
                 match partition.state with
                 | Settled _ -> not (settled_receipt_droppable gate partition)
                 | Ready | Running _ | Completed _ | Abandoned _ | Blocked _ -> true)
              view
          in
          let removed = List.length view - List.length kept in
          if removed = 0
          then (
            Atomic.set entry.cached (Some current);
            Ok 0)
          else (
            match
              Fs_compat.rewrite_private_jsonl_durable_locked_at_cursor_result
                ledger_path
                ~expected:snapshot.cursor
                (serialize kept ^ serialize_confirmations confirmations)
              |> cursor_result ~ledger_path
            with
            | Error error ->
              Atomic.set entry.cached None;
              Error error
            | Ok cursor ->
              let* compacted = apply_rows (empty_view cursor) kept in
              Atomic.set entry.cached (Some compacted);
              Ok removed)))
;;

let claim_ready_exact
      ~now
      ~worker_epoch
      ~base_path
      ~keeper_name
      ~partition_id
      ~generation
  =
  let* () = valid_time "partition claim time" now in
  let* () = nonempty "partition claim id" partition_id in
  let ledger_path = path ~base_path ~keeper_name in
  run_blocking "board-attention-partition-exact-claim" (fun () ->
    let entry = cache_entry ledger_path in
    Stdlib.Mutex.protect entry.mutation_mutex (fun () ->
      let* view = read_view_blocking ledger_path in
      let* () = validate_keeper_identity ~keeper_name view in
      match Id_map.find_opt partition_id view.by_id with
      | None -> Ok None
      | Some selected when Generation.equal selected.generation generation ->
        (match selected.state with
         | Ready ->
           let* claimed =
             advance_state
               selected
               (Running { worker_epoch; started_at = now; progress = Unbound })
           in
           let* updated = apply_rows view [ claimed ] in
           let suffix = serialize [ claimed ] in
           (match
              Fs_compat.append_private_jsonl_durable_locked_at_cursor_result
                ledger_path
                ~expected:view.cursor
                suffix
            with
            | Error (Fs_compat.Cursor_mismatch _) ->
              Atomic.set entry.cached None;
              Ok None
            | append_result ->
              let* cursor = cursor_result ~ledger_path append_result in
              Atomic.set entry.cached (Some { updated with cursor });
              Ok (Some claimed))
         | Running _ | Completed _ | Settled _ | Abandoned _ | Blocked _ -> Ok None)
      | Some _ -> Ok None))
;;

let transition_running_exact ~base_path ~partition ~worker_epoch decide =
  let* (partition, changed), write_outcome =
    update_exact ~base_path ~keeper_name:partition.keeper_name (fun view ->
      match Id_map.find_opt partition.partition_id view.by_id with
      | None -> Error ("Board attention partition not found: " ^ partition.partition_id)
      | Some current ->
        (match current.state with
         | Running running when Worker_epoch.equal running.worker_epoch worker_epoch ->
           let* state = decide running in
           let* updated = advance_state current state in
           Ok ([ updated ], (updated, updated <> current))
         | Running running ->
           Error
             (Printf.sprintf
                "partition %s is owned by worker %s"
                partition.partition_id
                (Worker_epoch.to_string running.worker_epoch))
         | Ready | Completed _ | Settled _ | Abandoned _ | Blocked _ ->
           Error ("partition is not Running: " ^ partition.partition_id)))
  in
  Ok { partition; changed; write_outcome }
;;

let bind_before_dispatch ~worker_epoch ~base_path ~partition ~provenance =
  let* () = validate_exact_provenance provenance in
  transition_running_exact
    ~base_path
    ~partition
    ~worker_epoch
    (fun running ->
      match running.progress with
      | Unbound ->
        Ok (Running { running with progress = Bound provenance })
      | Bound current when exact_provenance_equal current provenance ->
        Ok (Running running)
      | Bound _ ->
        Error "before-dispatch binding conflicts with the durable exact provenance"
      | Advancing { next; _ } when String.equal next.slot_id provenance.slot_id ->
        Ok (Running { running with progress = Bound provenance })
      | Advancing _ ->
        Error "before-dispatch binding differs from the durable next provenance")
;;

let record_before_advance ~worker_epoch ~base_path ~partition ~source ~next =
  let* () = validate_advance_source source in
  let* () = validate_candidate_visit next in
  if String.equal (advance_source_slot_id source) next.slot_id
  then Error "before-advance next visit must differ from the failed slot"
  else
    transition_running_exact
      ~base_path
      ~partition
      ~worker_epoch
      (fun running ->
        match running.progress with
        | Bound current ->
          (match source with
           | Executed_failure failed when exact_provenance_equal current failed ->
             Ok
               (Running
                  { running with
                    progress =
                      Advancing
                        { execution_anchor = Some failed
                        ; last_from = None
                        ; next
                        }
                  })
           | Executed_failure _ ->
             Error "before-advance failed provenance differs from the durable binding"
           | Predispatch_rejection _ ->
             Error "before-advance predispatch rejection requires a durable advancing visit")
        | Unbound ->
          (match source with
           | Predispatch_rejection last_from ->
             Ok
               (Running
                  { running with
                    progress =
                      Advancing
                        { execution_anchor = None
                        ; last_from = Some last_from
                        ; next
                        }
                  })
           | Executed_failure _ ->
             Error "before-advance executed failure requires a durable exact binding")
        | Advancing current ->
          (match source with
           | Executed_failure failed
             when (match current.execution_anchor with
                   | Some anchor -> exact_provenance_equal anchor failed
                   | None -> false)
                  && Option.is_none current.last_from
                  && candidate_visit_equal current.next next ->
             Ok (Running running)
           | Predispatch_rejection rejected
             when (match current.last_from with
                   | Some last_from -> candidate_visit_equal last_from rejected
                   | None -> false)
                  && candidate_visit_equal current.next next ->
             Ok (Running running)
           | Predispatch_rejection rejected
             when candidate_visit_equal current.next rejected ->
             Ok
               (Running
                  { running with
                    progress =
                      Advancing
                        { execution_anchor = current.execution_anchor
                        ; last_from = Some rejected
                        ; next
                        }
                  })
           | Executed_failure _
           | Predispatch_rejection _ ->
             Error "before-advance pair conflicts with the durable advancement")
        )
;;

let validate_completion ~now ~(partition : t) ~(item : completed_item) =
  let* () = valid_time "partition completion time" now in
  let* () = validate_judgment item.judgment in
  if not (String.equal item.candidate_id partition.candidate_id)
  then Error "partition completion candidate identity mismatch"
  else Ok ()
;;

(* [Advancing] names a next HTTP slot that AGENT_CORE has not bound, so an
   HTTP answer cannot complete it. A CLI tail answer can: the tail runs only
   after AGENT_CORE ended the HTTP walk (candidates exhausted, or every HTTP
   answer rejected by the domain decoder), and the flow never dispatches that
   next slot afterwards. When every HTTP slot is rejected before dispatch,
   the walk ends on [Advancing]; the live ledger held 126 CLI answers
   refused here and quarantined as [Exact_completion_failed] on 2026-09-24.
   A vendor answer comes before any HTTP slot, so it never meets
   [Advancing]. *)
let complete_after_advancing ~now (item : completed_item) =
  match item.judgment.source with
  | Candidate.Cli_lane_slot -> Ok (Completed { item; completed_at = now })
  | Candidate.Vendor_system_one _ | Candidate.Exact_attempt _ ->
    Error "partition completion cannot bypass pending advancement"
;;

let complete ~now ~worker_epoch ~base_path ~partition ~item =
  let* () = validate_completion ~now ~partition ~item in
  transition_running_exact
    ~base_path
    ~partition
    ~worker_epoch
    (fun running ->
      match judgment_provenance item.judgment, running.progress with
      (* An exact attempt answered: the completion must be the answer to the
         attempt that was durably bound before dispatch, not to some other one. *)
      | Some provenance, Bound current when exact_provenance_equal current provenance
        -> Ok (Completed { item; completed_at = now })
      | Some _, Bound _ ->
        Error "judgment provenance differs from the durable exact binding"
      (* A CLI or vendor judgment owns no HTTP receipt. The durable candidate
         claim and worker epoch authorize completion both for CLI-only lanes
         and for a CLI tail after an HTTP attempt, and for a vendor answer,
         which the flow asks for before its HTTP slots. *)
      | None, (Bound _ | Unbound) -> Ok (Completed { item; completed_at = now })
      | None, Advancing _ -> complete_after_advancing ~now item
      | Some _, Unbound ->
        Error "partition completion requires a durable exact binding"
      | Some _, Advancing _ ->
        Error "partition completion cannot bypass pending advancement")
;;

let complete_existing_judgment ~now ~worker_epoch ~base_path ~partition ~item =
  let* () = validate_completion ~now ~partition ~item in
  transition_running_exact
    ~base_path
    ~partition
    ~worker_epoch
    (fun running ->
      match running.progress with
      | Unbound -> Ok (Completed { item; completed_at = now })
      | Bound _ ->
        Error "existing judgment completion cannot bypass a durable exact binding"
      | Advancing _ ->
        Error "existing judgment completion cannot bypass pending advancement")
;;

let confirm_completed ~base_path ~(partition : t) =
  match partition.state with
  | Completed { item; completed_at } ->
    let* () = validate_completion ~now:completed_at ~partition ~item in
    let* (confirmed, changed), write_outcome =
      update_exact ~base_path ~keeper_name:partition.keeper_name (fun view ->
        match Id_map.find_opt partition.partition_id view.by_id with
        | None ->
          Error ("Board attention partition not found: " ^ partition.partition_id)
        | Some ({ state = Completed _; _ } as current)
          when current = partition -> Ok ([ current ], (current, false))
        | Some { state = Completed _; _ } ->
          Error
            ("completed partition item conflicts with durable state: "
             ^ partition.partition_id)
        | Some _ ->
          Error ("partition is not Completed: " ^ partition.partition_id))
    in
    Ok { partition = confirmed; changed; write_outcome }
  | Ready | Running _ | Settled _ | Abandoned _ | Blocked _ ->
    Error ("partition is not Completed: " ^ partition.partition_id)
;;

let block ~now ~worker_epoch ~base_path ~partition reason =
  let* () = valid_time "partition block time" now in
  let* () = validate_blocked_reason reason in
  transition_running_exact
    ~base_path
    ~partition
    ~worker_epoch
    (fun _ -> Ok (Blocked { reason; blocked_at = now }))
;;

let defer ~worker_epoch ~base_path ~partition =
  transition_running_exact
    ~base_path
    ~partition
    ~worker_epoch
    (fun (_ : running_state) -> Ok Ready)
;;

let confirm_blocked ~base_path ~(partition : t) =
  match partition.state with
  | Blocked { reason; blocked_at } ->
    let* () = valid_time "partition block time" blocked_at in
    let* () = validate_blocked_reason reason in
    let* (confirmed, changed), write_outcome =
      update_exact ~base_path ~keeper_name:partition.keeper_name (fun view ->
        match Id_map.find_opt partition.partition_id view.by_id with
        | None ->
          Error ("Board attention partition not found: " ^ partition.partition_id)
        | Some ({ state = Blocked _; _ } as durable)
          when durable = partition ->
          Ok ([ durable ], (durable, false))
        | Some { state = Blocked _; _ } ->
          Error
            ("blocked partition generation conflicts with durable state: "
             ^ partition.partition_id)
        | Some _ ->
          Error ("partition is not Blocked: " ^ partition.partition_id))
    in
    Ok { partition = confirmed; changed; write_outcome }
  | Ready | Running _ | Completed _ | Settled _ | Abandoned _ ->
    Error ("partition is not Blocked: " ^ partition.partition_id)
;;

type requeue_decision =
  | Append_ready of t
  | Observe_cursor_conflict of string
  | Observe_generation_conflict of string

let update_requeue_exact_or_observe ~base_path ~keeper_name decide =
  let ledger_path = path ~base_path ~keeper_name in
  run_blocking "board-attention-partition-exact-observe" (fun () ->
    let entry = cache_entry ledger_path in
    Stdlib.Mutex.protect entry.mutation_mutex (fun () ->
      let* view = read_view_blocking ledger_path in
      let* () = validate_keeper_identity ~keeper_name view in
      let* decision = decide view in
      match decision with
      | `Observe result -> Ok (`Observed result)
      | `Append (rows, result) ->
        (match rows with
         | [] -> Error "exact partition update must append a cursor-fenced row"
         | _ :: _ ->
           let* updated = apply_rows view rows in
           let suffix = serialize rows in
           (match
              Fs_compat.append_private_jsonl_durable_locked_at_cursor_result
                ledger_path
                ~expected:view.cursor
                suffix
            with
            | Error (Fs_compat.Cursor_mismatch _ as conflict) ->
              Ok
                (`Observed
                   (Observe_cursor_conflict
                      (Fs_compat.private_jsonl_transaction_error_to_string
                         conflict)))
            | append_result ->
              (match exact_cursor_result ~ledger_path append_result with
               | Error error -> Error error
               | Ok (cursor, write_outcome) ->
                 Atomic.set entry.cached (Some { updated with cursor });
                 Ok (`Written (result, write_outcome)))))))
;;

let requeue_blocked ~base_path ~(partition : t) =
  match partition.state with
  | Blocked _ ->
    let* outcome =
      update_requeue_exact_or_observe
        ~base_path
        ~keeper_name:partition.keeper_name
        (fun view ->
        match Id_map.find_opt partition.partition_id view.by_id with
        | None ->
          Error ("Board attention partition not found: " ^ partition.partition_id)
        | Some current when current = partition ->
          let* ready = advance_state current Ready in
          Ok (`Append ([ ready ], Append_ready ready))
        | Some { state = Blocked _; _ } ->
          Ok
            (`Observe
               (Observe_generation_conflict
                  ("blocked partition generation changed before manual requeue: "
                   ^ partition.partition_id)))
        | Some { state = Ready | Running _ | Completed _ | Settled _
               | Abandoned _; _ } ->
          Ok
            (`Observe
               (Observe_generation_conflict
                  ("partition already advanced beyond the observed Blocked generation: "
                   ^ partition.partition_id))))
    in
    (match outcome with
     | `Written (Append_ready ready, write_outcome) ->
       Ok
         (Requeued
            { partition = ready
            ; changed = true
            ; write_outcome
            })
     | `Observed (Observe_generation_conflict detail) ->
       Ok (Generation_conflict detail)
     | `Observed (Observe_cursor_conflict detail) ->
       Ok (Cursor_conflict detail)
     | `Written ((Observe_cursor_conflict _ | Observe_generation_conflict _), _)
     | `Observed (Append_ready _) ->
       Error "invalid exact requeue decision")
  | Ready | Running _ | Completed _ | Settled _ | Abandoned _ ->
    Error ("partition is not Blocked: " ^ partition.partition_id)
;;

let confirm_ready ~base_path ~(partition : t) =
  match partition.state with
  | Ready ->
    let* (confirmed, changed), write_outcome =
      update_exact
        ~ready_confirmation:partition
        ~base_path
        ~keeper_name:partition.keeper_name
        (fun view ->
        match Id_map.find_opt partition.partition_id view.by_id with
        | None ->
          Error ("Board attention partition not found: " ^ partition.partition_id)
        | Some current when current = partition ->
          Ok ([ current ], (current, false))
        | Some { state = Ready; _ } ->
          Error
            ("ready partition identity changed before fsync confirmation: "
             ^ partition.partition_id)
        | Some { state = Blocked _ | Running _ | Completed _ | Settled _
               | Abandoned _; _ } ->
          Error
            ("partition advanced before Ready fsync confirmation: "
             ^ partition.partition_id))
    in
    Ok { partition = confirmed; changed; write_outcome }
  | Blocked _ | Running _ | Completed _ | Settled _ | Abandoned _ ->
    Error ("partition is not Ready: " ^ partition.partition_id)
;;

let completed ~base_path ~keeper_name =
  let* view = read_view (path ~base_path ~keeper_name) in
  let* () = validate_keeper_identity ~keeper_name view in
  Id_set.fold
    (fun partition_id result ->
       let* completed = result in
       match Id_map.find_opt partition_id view.by_id with
       | Some partition -> Ok (partition :: completed)
       | None -> Error ("completed index lost partition " ^ partition_id))
    view.completed
    (Ok [])
  |> Result.map (List.sort compare_partition)
;;

let settle ~now ~base_path ~partition =
  let* () = valid_time "partition settlement time" now in
  update ~base_path ~keeper_name:partition.keeper_name (fun view ->
    match Id_map.find_opt partition.partition_id view.by_id with
    | None -> Error ("partition settlement target not found: " ^ partition.partition_id)
    | Some ({ state = Settled _; _ } as current) -> Ok ([], current)
    | Some ({ state = (Completed _ | Blocked _); _ } as current) ->
      let* settled = advance_state current (Settled { settled_at = now }) in
      Ok ([ settled ], settled)
    | Some current ->
      Error ("only Completed or Blocked partition can settle: " ^ current.partition_id))
;;

let abandon ~now ~base_path ~partition =
  let* () = valid_time "partition abandonment time" now in
  update ~base_path ~keeper_name:partition.keeper_name (fun view ->
    match Id_map.find_opt partition.partition_id view.by_id with
    | None -> Error ("partition abandonment target not found: " ^ partition.partition_id)
    | Some ({ state = Abandoned _; _ } as current) -> Ok ([], current)
    | Some ({ state = Blocked _; _ } as current) ->
      let* abandoned = advance_state current (Abandoned { abandoned_at = now }) in
      Ok ([ abandoned ], abandoned)
    | Some current ->
      Error ("only a Blocked partition can be abandoned: " ^ current.partition_id))
;;

let ledger_path = path
;;

(* For [Heap_roots]: walk the table under its own lock, so the diagnostic
   never counts a bucket array another domain is resizing. Never called from
   inside this module's critical sections; the lock is not reentrant. *)
let heap_root walk = Stdlib.Mutex.protect cache_registry_mutex (fun () -> walk (Obj.repr cache_registry))
