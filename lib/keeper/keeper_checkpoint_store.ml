(** Keeper_checkpoint_store — checkpoint file I/O.

    Handles saving, loading, listing, and pruning AGENT_CORE checkpoint JSON files
    within a session directory. Separated from [Keeper_working_context]
    so that file I/O concerns do not mix with context types and
    pure operations.

    @since keeper-ctx-split *)

open Printf

include Keeper_checkpoint_store_history_files
include Keeper_checkpoint_store_decode
include Keeper_checkpoint_store_summary
include Keeper_checkpoint_store_lineage
include Keeper_checkpoint_store_load
include Keeper_checkpoint_store_session
include Keeper_checkpoint_store_canonical
include Keeper_checkpoint_store_ref_errors
include Keeper_checkpoint_store_installation
include Keeper_checkpoint_store_exact_snapshot
include Keeper_checkpoint_store_cas_save
include Keeper_checkpoint_store_retained
include Keeper_checkpoint_store_export

(* ================================================================ *)
(* AGENT_CORE Checkpoints                                                    *)
(* ================================================================ *)

module Objects = Agent_core.Checkpoint_objects

(* Who a save keeps a lineage for. Only a Keeper's own saves do; a save by a
   tool or a test writes the file and keeps nothing. *)
type save_lineage =
  | Save_for_keeper of string
  | Save_without_lineage

(* The summary and the lineage are kept under the identity of the head this
   save wrote, from its own descriptor ([written_file]). A stat of the path
   after the rename would name whatever file is there by then. *)
let save_outcome_after_write
    ~session_dir ~canonical_path ~save_lineage ~memo ~written_file ~known
    ~history_retained ~payload_writer ~(plan : Objects.plan) ckpt
  =
  let identity = canonical_identity_of_stats written_file in
  publish_summary ~canonical_path (summary_of_head ~identity ~objects:Objects_seen plan.head);
  (match save_lineage with
   | Save_for_keeper keeper_name ->
     keep_lineage ~canonical_path ~identity ~memo ~keeper_name (Some plan.decoded)
   | Save_without_lineage -> ());
  archive_agent_core_history_best_effort
    ~payload_writer ~session_dir ~retained:history_retained ~head_bytes:plan.head_bytes ckpt;
  Ok
    (Saved
       { relation = save_relation ~known ~incoming:ckpt.turn_count
       ; turn_count = ckpt.turn_count
       ; canonical_bytes = identity.size
       ; checkpoint = ckpt
       })

let write_canonical_durably ~ownership_root path encoded_source =
  Keeper_fs.save_encoded_durable_atomic_from ~ownership_root path encoded_source

let save_agent_core_classified_typed
    ~(write_canonical :
       ownership_root:string ->
       string ->
       (unit -> string list) ->
       (Unix.stats, Keeper_fs.durable_write_error) result)
    ~save_lineage ~payload_writer
    ~(session_dir : string)
    ~(history_retained : int)
    ~boundary
    (ckpt : Agent_core.Checkpoint.t)
  : (save_agent_core_outcome, save_agent_core_error) result =
  match Keeper_transcript_unit.validate ckpt.messages with
  | Error structural -> Error (Structurally_invalid structural)
  | Ok () ->
  match Keeper_id.Trace_id.of_string ckpt.session_id with
  | Error reason -> Error (Invalid_session_id reason)
  | Ok trace_id ->
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
          Log.Keeper.warn
            "AGENT_CORE checkpoint %s is version %d, superseded by %d; this \
             turn's checkpoint replaces it"
            canonical_path got expected;
          Ok None
        | ( Error
              ( Not_found | Store_error _ | Parse_error _ | Newer_version _ | Io_error _
              | Read_failed _ | Agent_core_error _ | Objects_invalid _ )
          | Ok _ ) as answer -> answer
      with
      | Error error -> Error (Existing_checkpoint_unreadable error)
      | Ok (Some existing) when not (String.equal existing.known_session_id session_id) ->
        Error
          (Existing_checkpoint_unreadable
             (Store_error
                (Printf.sprintf
                   "canonical checkpoint identity mismatch: expected=%s actual=%s"
                   session_id existing.known_session_id)))
      | Ok (Some existing) when ckpt.turn_count < existing.known_turn_count ->
        Log.Keeper.warn
          "stale AGENT_CORE checkpoint write skipped for %s: incoming turn_count=%d, last saved=%d"
          ckpt.session_id ckpt.turn_count existing.known_turn_count;
        Otel_metric_store.inc_counter
          "masc_keeper_checkpoint_stale_noop_total"
          ~labels:[("site", "store_watermark")]
          ();
        Ok
          (Stale_noop
             { incoming_turn_count = ckpt.turn_count
             ; known_turn_count = existing.known_turn_count
             })
      | Ok existing ->
        let known = Option.map (fun known -> known.known_turn_count) existing in
        let previous = Option.map (fun known -> known.known_head) existing in
        let absent = Option.fold ~none:[] ~some:(absent_objects ~session_dir) existing in
        let ownership_root = Filename.dirname session_dir in
        let memo =
          match save_lineage with
          | Save_for_keeper _ -> lineage_memo ~canonical_path
          | Save_without_lineage -> Objects.create_memo ()
        in
        let plan payload =
          offload_checkpoint_cpu (fun () -> Objects.plan_save memo ?previous ~absent boundary payload)
        in
        (* The objects first, then the head that names them (RFC-0476 §3.3). *)
        let install payload (plan : Objects.plan) =
          match Keeper_checkpoint_object_store.write ~session_dir plan.objects with
          | Error error -> Error (Objects_write_failed error)
          | Ok object_bytes ->
            Checkpoint_payload_writer.note payload_writer (Some object_bytes);
            (match
               Checkpoint_payload_writer.canonical payload_writer ~write:write_canonical
                 ~ownership_root canonical_path
                 (fun () -> [ plan.head_bytes ])
             with
             | Error error -> Error (Canonical_write_failed error)
             | Ok written_file ->
               save_outcome_after_write
                 ~session_dir ~canonical_path ~save_lineage ~memo ~written_file
                 ~known ~history_retained ~payload_writer ~plan payload)
        in
        (match plan ckpt with
         | Ok planned -> install ckpt planned
         (* #31677: a payload-encode refusal means the in-memory checkpoint
            carries a json payload the contract cannot encode -- a
            provider-authored duplicate key or non-finite float. Without
            recovery the write refuses at this stage of every later turn,
            which is what bricked keepers for hours on 2026-08-29. The
            codec still rejects the original; this drop-and-retry-once
            stores the recovered copy, so the keeper survives and the next
            restart loads a clean checkpoint. A refusal with nothing
            droppable keeps the original error. *)
         | Error error -> (
           match Agent_core.Checkpoint.drop_unencodable_json ckpt with
           | None -> Error (Checkpoint_unencodable error)
           | Some recovered ->
             Log.Keeper.warn
               "checkpoint payload unencodable (%s); storing the recovery \
                copy with the offending json dropped for %s"
               (Agent_core.Error.to_string error)
               ckpt.session_id;
             (match plan recovered with
              | Error retry_error -> Error (Checkpoint_unencodable retry_error)
              | Ok planned -> install recovered planned))))

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

module For_testing = struct
  module Inode_set = Set.Make (struct
    type t = int * int

    let compare (d1, i1) (d2, i2) =
      let c = Int.compare d1 d2 in
      if c <> 0 then c else Int.compare i1 i2
  end)

  let retained_payload_bytes ~directory =
    let seen = ref Inode_set.empty in
    let rec count total path =
      let stat = Unix.lstat path in
      match stat.Unix.st_kind with
      | Unix.S_DIR ->
        Array.fold_left (fun total leaf -> count total (Filename.concat path leaf))
          total (Sys.readdir path)
      | Unix.S_REG ->
        let key = stat.Unix.st_dev, stat.Unix.st_ino in
        if Inode_set.mem key !seen then total
        else (
          seen := Inode_set.add key !seen;
          if stat.Unix.st_size > max_int - total then invalid_arg "retained payload byte count overflow";
          total + stat.Unix.st_size)
      | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK -> total
    in
    count 0 directory

  let save_agent_core_for_keeper_measured ~keeper_name ~session_dir ~history_retained ~boundary ckpt =
    let bytes = ref (Some 0) in
    let on_payload observation =
      bytes := (match !bytes, observation with
        | Some total, Some count when count <= max_int - total -> Some (total + count)
        | Some _, Some _ | None, Some _ | Some _, None | None, None -> None)
    in
    save_agent_core_classified_typed
      ~write_canonical:write_canonical_durably
      ~save_lineage:(Save_for_keeper keeper_name) ~payload_writer:(Checkpoint_payload_writer.Measured on_payload) ~session_dir ~history_retained ~boundary ckpt
    |> Result.map (fun outcome -> outcome, !bytes)
    |> Result.map_error save_agent_core_error_to_string

  let with_before_history_link hook f =
    let previous = Atomic.exchange before_history_link_hook (Some hook) in
    Fun.protect ~finally:(fun () -> Atomic.set before_history_link_hook previous) f

  let retain_exact_snapshot_with_writer = retain_exact_snapshot_with

  let save_agent_core_if_source_with_observer
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate =
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate
  ;;

  let save_agent_core_if_source_with_release_failure
      ~release_failure
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate =
    let with_release_failure ~session_dir f =
      match canonical_session_location session_dir with
      | Error error ->
        not_installed
          (Source_unavailable
             (Ref_lock_failed (save_agent_core_error_to_string error)))
      | Ok session_dir ->
        let lock_path = session_dir ^ ".checkpoint.lock" in
        File_lock_eio.For_testing.with_durable_lock_observed_with_release_failure
          ~release_failure
          ~lock_path
          (fun () -> f session_dir)
        |> installation_of_lock_observation
    in
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock:with_release_failure
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate
  ;;

  let save_agent_core_if_source_with_acquire_failure
      ~acquire_failure
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate =
    let with_acquire_failure ~session_dir:_ _f =
      installation_of_lock_observation
        (File_lock_eio.Lock_not_acquired acquire_failure)
    in
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock:with_acquire_failure
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate
  ;;

  let save_agent_core_if_source_with_writer
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate =
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate
  ;;

  let save_agent_core_if_source_with_post_commit_unwind
      ~post_commit_unwind
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate =
    let with_post_commit_unwind ~session_dir f =
      match with_checkpoint_cas_lock ~session_dir f with
      | Installed _ as installation ->
        post_commit_unwind ();
        installation
      | Not_installed _ as outcome -> outcome
    in
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock:with_post_commit_unwind
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate
  ;;

  let save_agent_core_for_keeper_with_before_stage
      ~before_stage ~keeper_name ~session_dir ~history_retained ~boundary ckpt
    =
    save_agent_core_classified_typed
      ~write_canonical:(fun ~ownership_root path encoded_source ->
        Keeper_fs.For_testing.save_encoded_durable_atomic_from
          ~before_stage ~ownership_root path encoded_source)
      ~save_lineage:(Save_for_keeper keeper_name) ~payload_writer:Checkpoint_payload_writer.Unmeasured ~session_dir ~history_retained ~boundary ckpt
    |> Result.map_error save_agent_core_error_to_string
  ;;
end
