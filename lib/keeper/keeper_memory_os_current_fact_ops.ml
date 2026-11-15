open Keeper_memory_os_types
open Result.Syntax
module Journal_codec = Keeper_memory_os_journal_codec
open Keeper_memory_os_current_types
open Keeper_memory_os_support_core
open Keeper_memory_os_current_layout
open Keeper_memory_os_current_range_codec
open Keeper_memory_os_current_receipt_store
open Keeper_memory_os_current_journal
open Keeper_memory_os_current_publication
open Keeper_memory_os_current_read_anchor
open Keeper_memory_os_current_update
open Keeper_memory_os_current_program_apply
module Change_metrics = Keeper_memory_os_current_change_metrics

(* An explicit write or retraction names no absorption and no revision, so
   every ID that leaves its commit is dropped. *)
let explicit_change_count pass =
  Change_metrics.Counted
    { pass
    ; count =
        (fun (snapshot : t) () ->
           Change_metrics.of_change ~absorbed:[] ~revisions:[] snapshot.change)
    }
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
    ~change_count:Change_metrics.Not_counted
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
let upsert_fact ?clock ~pass ~keepers_dir ~keeper_id ~now ~source incoming =
  update_locked_with_error
    ?clock
    ~change_count:(explicit_change_count pass)
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
      ~pass
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
      ~change_count:(explicit_change_count pass)
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
      ~pass
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
    let revision : Keeper_memory_os_types.revision =
      { superseded = superseded_memory_id; superseded_by = incoming_identity }
    in
    update_locked_with_output
      ?clock
      ~declared_revisions:[ revision ]
      ~dropped_statements:
        [ { Keeper_memory_os_types.memory_id = superseded_memory_id
          ; reason = "superseded_by " ^ incoming_identity
          }
        ]
      ~change_count:
        (Change_metrics.Counted
           { pass
           ; count =
               (fun (snapshot : t) (_ : supersession) ->
                  Change_metrics.of_change ~absorbed:[] ~revisions:[ revision ] snapshot.change)
           })
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
      ~pass
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
      ~change_count:(explicit_change_count pass)
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
  |> Result.map
       (List.map (fun (line_offset, result) ->
          match Journal_codec.journal_line_to_json result with
          | `Assoc fields ->
            `Assoc
              (( "structural_id"
               , `String (journal_projection_identity ~keeper_id line_offset) )
               :: fields)
          | json -> json))
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
      ~pass ~keepers_dir ~keeper_id ~now ~anchor ~source ~validate_source program =
    apply_program_with_io ~write_snapshot ~sync_snapshot ~on_committed ~pass
      ~finalize_journal:(fun ~keepers_dir ~keeper_id receipt ->
        before_journal (); record_publication_journal ~keepers_dir ~keeper_id receipt)
      ~keepers_dir ~keeper_id ~now ~anchor ~source ~validate_source program

  let replace_with_publication_io ~write_snapshot ~sync_snapshot ~on_committed ~before_journal
      ~keepers_dir ~keeper_id ~now ~source ~facts =
    update_locked_with_output ~write_snapshot ~sync_snapshot ~on_committed
      ~finalize_journal:(fun ~keepers_dir ~keeper_id receipt ->
        before_journal (); record_publication_journal ~keepers_dir ~keeper_id receipt)
      ~change_count:Change_metrics.Not_counted
      ~equal_facts:(Write_revision None)
      ~store_error:Fun.id ~keepers_dir ~keeper_id ~now
      (fun ~snapshot_content:_ previous ->
        let+ snapshot = make_snapshot ~previous ~now ~source ~facts () in snapshot, ())
    |> Result.map (fun (snapshot, _, ()) -> snapshot)

  let durable_range_receipt_decodes () = Atomic.get durable_range_receipt_decodes
end
