(** Keeper-owned current Memory OS snapshot. *)

open Keeper_memory_os_types
open Result.Syntax

module Snapshot_codec = Keeper_memory_os_snapshot_codec
module Journal_codec = Keeper_memory_os_journal_codec
module Successor_recall = Keeper_memory_os_successor_recall
module Receipt_selection = Keeper_memory_os_receipt_selection

include Keeper_memory_os_current_types
open Keeper_memory_os_support_core
include Keeper_memory_os_current_layout
include Keeper_memory_os_current_range_codec
include Keeper_memory_os_current_receipt_store
include Keeper_memory_os_current_journal
include Keeper_memory_os_current_retraction_plan
include Keeper_memory_os_current_publication
include Keeper_memory_os_current_read_anchor
include Keeper_memory_os_current_update
include Keeper_memory_os_current_revision_evidence

(* Apply a librarian's disposition to whatever the snapshot holds when the
   lock is taken.

   The librarian says what changes: retire that one for this reason, add these
   new claims. A fact the disposition never mentions is left alone.

   A fact the librarian retires is retired even if the keeper re-observed it
   during the pass: the judgment was about the claim, and a re-observation does
   not answer it. The keeper can state it again on its next turn. *)
type disposition =
  { snapshot : t
  ; commit : commit_effect
  ; absorbed_applied : Keeper_memory_os_types.absorbed_statement list
  ; absorbed_not_applied : Keeper_memory_os_types.absorbed_statement list
  ; claims_not_applied : Keeper_memory_os_types.fact list
  ; revisions_applied : Keeper_memory_os_types.revision list
  }

type disposition_basis =
  { expected_revision : int option
  ; expected_facts : Keeper_memory_os_types.fact list option
  }

type disposition_error =
  | Basis_superseded of t option
  | Destination_absent of { memory_id : string; current : t option }
  | Disposition_store_failed of string

type program_source =
  | Atom_program_source of
      { range : durable_range_id
      ; checkpoint : Agent_core.Types.message list
      }
  | Official_program_source of
      { range : official_range_id
      ; selected_turns : (int * Ids.Turn_ref.t * Agent_core.Types.message list) list
      }

type program_commit =
  { snapshot : t
  ; proof : Keeper_memory_os_program_types.publication
  }

let messages_sha256 messages =
  sha256 (Yojson.Safe.to_string (`List (List.map Agent_core.Checkpoint.message_to_json messages)))

let prepare_program_source source (program : Keeper_memory_os_program.t) =
  let module P = Keeper_memory_os_program_types in
  let module Unread = Keeper_librarian_unread in
  match source with
  | Atom_program_source {range;checkpoint} ->
    let* _ = durable_range_id_of_json (durable_range_id_to_json range)
      |> Result.map_error wire_error_to_string in
    let* sources = Unread.sources_for_atom_range ~trace_id:range.trace_id
      ~history_start_boundary_line:range.history_start_boundary_line ~start_atom:range.start_atom
      ~end_atom:range.end_atom ~messages:checkpoint in
    if sources <> program.sources || range.unread_messages <> program.unread
       || Runtime_model_input_tail_window.atom_opening_digest checkpoint (range.end_atom-1)
          <> Some range.last_atom_digest
    then Error "ordered program does not cover its exact original atom boundary"
    else Ok (Some range,None,
      P.Atom_boundary {receipt_scope=range.receipt_scope;trace_id=range.trace_id;
        history_start_boundary_line=range.history_start_boundary_line;start_atom=range.start_atom;
        end_atom=range.end_atom;last_atom_digest=range.last_atom_digest;
        end_boundary_line=range.end_boundary_line;boundary_lines_seen=range.boundary_lines_seen;
        checkpoint_sha256=messages_sha256 checkpoint})
  | Official_program_source {range;selected_turns} ->
    let* _ = official_range_id_of_json (official_range_id_to_json range)
      |> Result.map_error wire_error_to_string in
    let selected = List.map (fun (line,turn_ref,_) -> line,turn_ref) selected_turns in
    let sources = List.concat_map (fun (boundary_line,turn_ref,messages) ->
      List.mapi (fun message_in_turn message ->
        Unread.Official_turn {turn_ref;boundary_line;message_in_turn;
          message_sha256=Unread.message_digest message}) messages) selected_turns in
    if selected <> range.turns || sources <> program.sources || range.unread_messages <> program.unread
    then Error "ordered program does not cover its exact original official-turn boundary"
    else Ok (None,Some range,P.Official_boundary {receipt_scope=range.receipt_scope;
      after_boundary_line=range.after_boundary_line;
      turns=List.map (fun (line,turn_ref,messages) -> line,turn_ref,messages_sha256 messages) selected_turns})

let apply_program_with_io ?write_snapshot ?sync_snapshot ?finalize_journal ?on_committed ?clock ~keepers_dir ~keeper_id ~now ~anchor ~source ~validate_source program =
  let module P = Keeper_memory_os_program_types in
  let* () =
    if Keeper_identity.Keeper_id.to_string program.Keeper_memory_os_program.keeper_id=keeper_id
    then Ok () else Error "ordered Memory program Keeper differs from the store identity" in
  let* durable_range_id,official_range_id,boundary = prepare_program_source source program in
  update_locked_with_output ?write_snapshot ?sync_snapshot ?finalize_journal ?clock ?durable_range_id ?official_range_id
    ~program_of_output:Fun.id
    ?observe_output:(Option.map (fun observe snapshot (_ : commit_effect) proof ->
      observe {snapshot;proof}) on_committed)
    ~equal_facts:(Write_revision None) ~store_error:Fun.id ~keepers_dir ~keeper_id ~now
    (fun ~snapshot_content previous ->
      let* () = validate_source () in
      let* locked_prior = verify_program_anchor ~keepers_dir ~keeper_id anchor ~snapshot_content previous program in
      let current = Option.fold ~none:[] ~some:(fun (current : t) -> current.facts) previous in
      let* execution = Keeper_memory_os_program.replay program ~current in
      let source = {kind=Librarian;trace_id=Ids.Turn_ref.trace_id program.turn_ref} in
      let* next = make_snapshot_from_maintained ~previous ~now ~source
        ~facts:execution.final_facts ~invalidated:[] () in
      Ok (next,({execution;captured=anchor.anchor_identity;locked_prior;boundary} : P.publication)))
  |> Result.map (fun (snapshot,(_ : commit_effect),proof) -> {snapshot;proof})

let apply_program ?on_committed ?clock ~keepers_dir ~keeper_id ~now ~anchor ~source ~validate_source program =
  apply_program_with_io ?on_committed ?clock ~keepers_dir ~keeper_id ~now ~anchor ~source ~validate_source program

let apply_disposition_guarded
      ?expected_basis
      ?on_committed
      ?clock
      ?dropped_statements
      ?durable_range_id
      ?official_range_id
      ?(explicit_candidate_ids = [])
      ?admission_recall
      ?(required_memory_ids = [])
      ~absorbed
      ~revisions
      ~keepers_dir
      ~keeper_id
      ~now
      ~source
      ~new_claims
      ()
  =
  let store_error detail = Disposition_store_failed detail in
  let ids_of facts =
    List.fold_left
      (fun ids fact -> Set_util.StringSet.add (memory_id fact) ids)
      Set_util.StringSet.empty
      facts
  in
  let plan_of (previous : t option) =
    let current = match previous with None -> [] | Some snapshot -> snapshot.facts in
    Keeper_memory_os_disposition_core.plan ~current
      ~dropped:(Option.value dropped_statements ~default:[])
      ~absorbed ~revisions ~new_claims
  in
  (* What the commit did: an absorption is applied when its row is written (its
     source left the snapshot into its target), a revision when its old id left
     the snapshot and its successor is in the next one. Set by the one
     [before_replace] under the lock, which runs on every commit; read only
     after the commit succeeded. *)
  let outcome = ref (([], absorbed), [], []) in
  let disposition_of snapshot commit =
    let (absorbed_applied, absorbed_not_applied), claims_not_applied, revisions_applied =
      !outcome
    in
    { snapshot
    ; commit
    ; absorbed_applied
    ; absorbed_not_applied
    ; claims_not_applied
    ; revisions_applied
    }
  in
  (* RFC-0456 §4.2: an absorbed fact leaves the snapshot only with its row kept.
     The rows are the absorbed facts the locked snapshot held and the next one
     does not, so a fact the keeper retracted during the pass has no row, and
     they are written just before the replace; a failed write fails this
     commit. *)
  let write_absorbed_rows ~(previous : t option) ~(next : t) =
    let plan = plan_of previous in
    let previous_facts =
      match previous with
      | None -> []
      | Some snapshot -> snapshot.facts
    in
    let previous_ids = ids_of previous_facts in
    let next_ids = ids_of next.facts in
    let rows =
      List.filter_map
        (fun fact ->
           let identity = memory_id fact in
           match Set_util.StringMap.find_opt identity plan.absorbed_into with
           | Some into when not (Set_util.StringSet.mem identity next_ids) ->
             Some
               { Keeper_memory_absorbed.recorded_at = now
               ; trace_id = (source : source).trace_id
               ; memory_id = identity
               ; into
               ; fact
               }
           | Some _ | None -> None)
        previous_facts
    in
    let revisions_applied =
      List.filter
        (fun (revision : Keeper_memory_os_types.revision) ->
           Set_util.StringSet.mem revision.superseded previous_ids
           && (not (Set_util.StringSet.mem revision.superseded next_ids))
           && Set_util.StringSet.mem revision.superseded_by next_ids)
        revisions
    in
    outcome
    := ( List.partition
           (fun (statement : Keeper_memory_os_types.absorbed_statement) ->
              List.exists
                (fun (row : Keeper_memory_absorbed.record) ->
                   String.equal row.memory_id statement.absorbed
                   && String.equal row.into statement.into)
                rows)
           absorbed
       , plan.claims_refused
       , revisions_applied );
    Keeper_memory_absorbed.append_all ~keepers_dir ~keeper_id rows
    |> Result.map_error (fun error -> store_error (Keeper_memory_absorbed.append_error_to_string error))
  in
  update_locked_with_output
    ?on_committed:
      (Option.map
         (fun on_committed snapshot commit -> on_committed (disposition_of snapshot commit))
         on_committed)
    ?clock
    ?dropped_statements
    ?durable_range_id
    ?official_range_id
    ~explicit_candidate_ids
    ?admission_recall
    ~declared_revisions:revisions
    ~before_replace:write_absorbed_rows
    ~equal_facts:Keep_stored
    ~store_error
    ~keepers_dir
    ~keeper_id
    ~now
    (fun ~snapshot_content:_ previous ->
       let* () = match expected_basis with
         | None -> Ok ()
         | Some (basis : disposition_basis) ->
           let revision = Option.map (fun (snapshot : t) -> snapshot.revision) previous in
           let facts = Option.map (fun (snapshot : t) -> snapshot.facts) previous in
           if revision = basis.expected_revision && facts = basis.expected_facts
           then Ok () else Error (Basis_superseded previous) in
       let plan = plan_of previous in
       let* next = make_snapshot_from_maintained ~previous ~now ~source ~facts:plan.facts
         ~invalidated:plan.invalidated () |> Result.map_error store_error in
       let actual = ids_of next.facts in
       match List.find_opt (fun identity -> not (Set_util.StringSet.mem identity actual)) required_memory_ids with
       | Some memory_id -> Error (Destination_absent { memory_id; current = previous })
       | None -> Ok (next, ()))
  |> Result.map (fun (snapshot, commit, ()) -> disposition_of snapshot commit)
;;

let disposition_error_to_string = function
  | Basis_superseded _ -> "current Memory OS disposition basis changed"
  | Destination_absent { memory_id; current = _ } ->
    "explicit admission destination is not current: " ^ memory_id
  | Disposition_store_failed detail -> detail
;;

let apply_disposition
      ?expected_basis ?on_committed ?clock ?dropped_statements ?durable_range_id
      ?official_range_id ?explicit_candidate_ids ?admission_recall ?required_memory_ids
      ~absorbed ~revisions ~keepers_dir ~keeper_id ~now ~source ~new_claims () =
  apply_disposition_guarded
    ?expected_basis ?on_committed ?clock ?dropped_statements ?durable_range_id
    ?official_range_id ?explicit_candidate_ids ?admission_recall ?required_memory_ids
    ~absorbed ~revisions ~keepers_dir ~keeper_id ~now ~source ~new_claims ()
  |> Result.map_error disposition_error_to_string
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
let upsert_fact ?clock ~keepers_dir ~keeper_id ~now ~source incoming =
  update_locked_with_error
    ?clock
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
    update_locked_with_output
      ?clock
      ~declared_revisions:[{superseded=superseded_memory_id; superseded_by=incoming_identity}]
      ~dropped_statements:
        [ { Keeper_memory_os_types.memory_id = superseded_memory_id
          ; reason = "superseded_by " ^ incoming_identity
          }
        ]
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
  |> List.map (fun (line_offset, result) ->
       match Journal_codec.journal_line_to_json result with
       | `Assoc fields ->
         `Assoc
           (( "structural_id"
            , `String (journal_projection_identity ~keeper_id line_offset) )
            :: fields)
       | json -> json)
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
      ~keepers_dir ~keeper_id ~now ~anchor ~source ~validate_source program =
    apply_program_with_io ~write_snapshot ~sync_snapshot ~on_committed
      ~finalize_journal:(fun ~keepers_dir ~keeper_id receipt ->
        before_journal (); record_publication_journal ~keepers_dir ~keeper_id receipt)
      ~keepers_dir ~keeper_id ~now ~anchor ~source ~validate_source program

  let replace_with_publication_io ~write_snapshot ~sync_snapshot ~on_committed ~before_journal
      ~keepers_dir ~keeper_id ~now ~source ~facts =
    update_locked_with_output ~write_snapshot ~sync_snapshot ~on_committed
      ~finalize_journal:(fun ~keepers_dir ~keeper_id receipt ->
        before_journal (); record_publication_journal ~keepers_dir ~keeper_id receipt)
      ~equal_facts:(Write_revision None)
      ~store_error:Fun.id ~keepers_dir ~keeper_id ~now
      (fun ~snapshot_content:_ previous ->
        let+ snapshot = make_snapshot ~previous ~now ~source ~facts () in snapshot, ())
    |> Result.map (fun (snapshot, _, ()) -> snapshot)

  let durable_range_receipt_decodes () = Atomic.get durable_range_receipt_decodes
end
