module Objects = Agent_core.Checkpoint_objects
open Keeper_checkpoint_store_history_files
open Keeper_checkpoint_store_decode
open Keeper_checkpoint_store_summary
open Keeper_checkpoint_store_lineage
open Keeper_checkpoint_store_session
open Keeper_checkpoint_store_canonical

(* Who a save keeps a lineage for. Only a Keeper's own saves do; a save by a
   tool or a test writes the file and keeps nothing. *)
type save_lineage =
  | Save_for_keeper of string
  | Save_without_lineage

(* The summary and the lineage are kept under the identity of the head this
   save wrote, from its own descriptor ([written_file]). A stat of the path
   after the rename would name whatever file is there by then.

   Rolling history snapshots are archived only when a turn closes
   ([Turn_closes]). Archiving on intermediate mid-turn saves ([Turn_continues])
   churned hardlinks, directory reads, and unlinks on every tool stage and
   evicted earlier completed turns out of the retention window within one tool
   round. *)
let save_outcome_after_write
    ~session_dir ~canonical_path ~save_lineage ~memo ~written_file ~known
    ~history_retained ~boundary ~payload_writer ~(plan : Objects.plan) ckpt
  =
  let identity = canonical_identity_of_stats written_file in
  publish_summary ~canonical_path (summary_of_head ~identity ~objects:Objects_seen plan.head);
  (match save_lineage with
   | Save_for_keeper keeper_name ->
     keep_lineage ~canonical_path ~identity ~memo ~keeper_name (Some plan.decoded)
   | Save_without_lineage -> ());
  (match boundary with
   | Objects.Turn_closes ->
     archive_agent_core_history_best_effort
       ~payload_writer ~session_dir ~retained:history_retained ~head_bytes:plan.head_bytes ckpt
   | Objects.Turn_continues -> ());
  Ok
    (Saved
       { relation = save_relation ~known ~incoming:ckpt.turn_count
       ; turn_count = ckpt.turn_count
       ; canonical_bytes = identity.size
       ; checkpoint = ckpt
       })

let write_canonical_durably ~ownership_root path head_bytes =
  Keeper_fs.save_bytes_durable_atomic_stats ~ownership_root path head_bytes

(* Pure CPU phase of a save: transcript structural validation, save planning,
   and one drop-unencodable recovery retry run in a single Domain_pool job so
   a save queues on the pool once instead of two or three times. *)
type validated_plan =
  | Plan_ready of
      { payload : Agent_core.Checkpoint.t
      ; plan : Objects.plan
      ; recovered_from : Agent_core.Error.t option
      }
  | Plan_structurally_invalid of Keeper_transcript_unit.structural_error
  | Plan_unencodable of Agent_core.Error.t

let validate_on_pool ckpt =
  offload_checkpoint_cpu (fun () -> Keeper_transcript_unit.validate ckpt.Agent_core.Checkpoint.messages)

let validate_and_plan_on_pool ~memo ~previous ~absent ~boundary ckpt =
  offload_checkpoint_cpu (fun () ->
    match Keeper_transcript_unit.validate ckpt.Agent_core.Checkpoint.messages with
    | Error structural -> Plan_structurally_invalid structural
    | Ok () ->
      (match Objects.plan_save memo ?previous ~absent boundary ckpt with
       | Ok plan -> Plan_ready { payload = ckpt; plan; recovered_from = None }
       (* #31677: a payload-encode refusal means the in-memory checkpoint
          carries a json payload the contract cannot encode -- a
          provider-authored duplicate key or non-finite float. Without
          recovery the write refuses at this stage of every later turn,
          which is what bricked keepers for hours on 2026-08-29. The
          codec still rejects the original; this drop-and-retry-once
          stores the recovered copy, so the keeper survives and the next
          restart loads a clean checkpoint. A refusal with nothing
          droppable keeps the original error. *)
       | Error error ->
         (match Agent_core.Checkpoint.drop_unencodable_json ckpt with
          | None -> Plan_unencodable error
          | Some recovered ->
            (match Objects.plan_save memo ?previous ~absent boundary recovered with
             | Error retry_error -> Plan_unencodable retry_error
             | Ok plan ->
               Plan_ready { payload = recovered; plan; recovered_from = Some error }))))

let save_agent_core_classified_typed
    ~(write_canonical :
       ownership_root:string ->
       string ->
       string ->
       (Unix.stats, Keeper_fs.durable_write_error) result)
    ~save_lineage ~payload_writer
    ~(session_dir : string)
    ~(history_retained : int)
    ~boundary
    (ckpt : Agent_core.Checkpoint.t)
  : (save_agent_core_outcome, save_agent_core_error) result =
  (* Keep structural validation's error precedence on early error and stale
     paths while merging validation and planning into one CPU pool job on the
     hot save path. *)
  let guard_structural fallback =
    match validate_on_pool ckpt with
    | Error structural -> Error (Structurally_invalid structural)
    | Ok () -> fallback
  in
  match Keeper_id.Trace_id.of_string ckpt.session_id with
  | Error reason -> guard_structural (Error (Invalid_session_id reason))
  | Ok trace_id ->
    (match
       with_session_lock_typed ~session_dir (fun session_dir ->
         let session_id = Keeper_id.Trace_id.to_string trace_id in
         let canonical_path = agent_core_checkpoint_path ~session_dir ~session_id in
         match
           (* A canonical this binary supersedes carries no watermark to respect.
              The load already refused it and started the keeper fresh, so nothing
              in memory descends from it, and the write below replaces it -- under
              the same durable session lock as every other write here. Reporting
              it as unreadable instead made every save fail the same way forever,
              because nothing ever replaced the file: a keeper whose workspace
              predates the version bump could not checkpoint again until someone
              deleted it by hand. *)
           match known_canonical ~canonical_path with
           | Error (Superseded_version { expected; got }) ->
             Ok (None, Some (expected, got))
           | Ok existing -> Ok (existing, None)
           | Error
               (( Not_found | Store_error _ | Parse_error _ | Newer_version _ | Io_error _
                | Read_failed _ | Agent_core_error _ | Objects_invalid _ ) as error) ->
             Error error
         with
         | Error error -> Error (Existing_checkpoint_unreadable error)
         | Ok (Some existing, _) when not (String.equal existing.known_session_id session_id) ->
           Error
             (Existing_checkpoint_unreadable
                (Store_error
                   (Printf.sprintf
                      "canonical checkpoint identity mismatch: expected=%s actual=%s"
                      session_id existing.known_session_id)))
         | Ok (Some existing, _) when ckpt.turn_count < existing.known_turn_count ->
           Ok
             (Stale_noop
                { incoming_turn_count = ckpt.turn_count
                ; known_turn_count = existing.known_turn_count
                })
         | Ok (existing, superseded) ->
           let known = Option.map (fun known -> known.known_turn_count) existing in
           let previous = Option.map (fun known -> known.known_head) existing in
           let absent = Option.fold ~none:[] ~some:(absent_objects ~session_dir) existing in
           let ownership_root = Filename.dirname session_dir in
           let run_with_lineage f =
             (* Pin in-flight save for BOTH [Save_for_keeper] and
                [Save_without_lineage] so periodic object sweeps never race with
                an un-tracked save writer. *)
             with_active_lineage ~canonical_path (fun () ->
               match save_lineage with
               | Save_for_keeper _ -> f (lineage_memo ~canonical_path)
               | Save_without_lineage -> f (Objects.create_memo ()))
           in
           run_with_lineage (fun memo ->
             match validate_and_plan_on_pool ~memo ~previous ~absent ~boundary ckpt with
             | Plan_structurally_invalid structural -> Error (Structurally_invalid structural)
             | Plan_unencodable error -> Error (Checkpoint_unencodable error)
             | Plan_ready { payload; plan; recovered_from } ->
               Option.iter
                 (fun (expected, got) ->
                   Log.Keeper.warn
                     "AGENT_CORE checkpoint %s is version %d, superseded by %d; this \
                      turn's checkpoint replaces it"
                     canonical_path got expected)
                 superseded;
               Option.iter
                 (fun error ->
                   Log.Keeper.warn
                     "checkpoint payload unencodable (%s); storing the recovery \
                      copy with the offending json dropped for %s"
                     (Agent_core.Error.to_string error)
                     ckpt.session_id)
                 recovered_from;
               (* The objects first, then the head that names them. *)
               (match Keeper_checkpoint_object_store.write ~session_dir plan.objects with
                | Error error -> Error (Objects_write_failed error)
                | Ok object_bytes ->
                  Checkpoint_payload_writer.note payload_writer (Some object_bytes);
                  (match
                     Checkpoint_payload_writer.canonical payload_writer ~write:write_canonical
                       ~ownership_root canonical_path plan.head_bytes
                   with
                   | Error error -> Error (Canonical_write_failed error)
                   | Ok written_file ->
                     save_outcome_after_write
                       ~session_dir ~canonical_path ~save_lineage ~memo ~written_file
                       ~known ~history_retained ~boundary ~payload_writer ~plan payload))))
     with
     | Ok (Stale_noop { incoming_turn_count; known_turn_count } as outcome) ->
       (match validate_on_pool ckpt with
        | Error structural -> Error (Structurally_invalid structural)
        | Ok () ->
          Log.Keeper.warn
            "stale AGENT_CORE checkpoint write skipped for %s: incoming turn_count=%d, last saved=%d"
            ckpt.session_id incoming_turn_count known_turn_count;
          Otel_metric_store.inc_counter
            "masc_keeper_checkpoint_stale_noop_total"
            ~labels:[("site", "store_watermark")]
            ();
          Ok outcome)
     | Error
         (( Session_directory_unavailable _
          | Transaction_lock_failed _
          | Existing_checkpoint_unreadable _ ) as error) ->
       guard_structural (Error error)
     | (Ok (Saved _)
       | Error
           ( Invalid_session_id _
           | Checkpoint_unencodable _
           | Objects_write_failed _
           | Canonical_write_failed _
           | Structurally_invalid _ )) as outcome -> outcome)

let save_agent_core_classified
    ~(session_dir : string) ~(history_retained : int) ~boundary (ckpt : Agent_core.Checkpoint.t)
  : (save_agent_core_outcome, string) result =
  save_agent_core_classified_typed
    ~write_canonical:write_canonical_durably
    ~save_lineage:Save_without_lineage ~payload_writer:Checkpoint_payload_writer.Unmeasured ~session_dir ~history_retained ~boundary ckpt
  |> Result.map_error save_agent_core_error_to_string

let save_agent_core_for_keeper
    ~keeper_name ~(session_dir : string) ~(history_retained : int) ~boundary (ckpt : Agent_core.Checkpoint.t)
  : (save_agent_core_outcome, string) result =
  save_agent_core_classified_typed
    ~write_canonical:write_canonical_durably
    ~save_lineage:(Save_for_keeper keeper_name) ~payload_writer:Checkpoint_payload_writer.Unmeasured ~session_dir ~history_retained ~boundary ckpt
  |> Result.map_error save_agent_core_error_to_string
