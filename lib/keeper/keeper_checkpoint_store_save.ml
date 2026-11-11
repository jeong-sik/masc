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
  (* The validation reads every block of every message. On the caller's
     domain, which for a Keeper turn is the main one, it was 204 of 21,576
     main-thread samples over 60 s on a live root of 29 Keepers (about 0.6 s,
     2026-11-11). It is pure, so it runs where the encoding below runs. *)
  match offload_checkpoint_cpu (fun () -> Keeper_transcript_unit.validate ckpt.messages) with
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
