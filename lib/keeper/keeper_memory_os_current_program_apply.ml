open Keeper_memory_os_types
open Result.Syntax
open Keeper_memory_os_current_types
open Keeper_memory_os_support_core
open Keeper_memory_os_current_range_codec
open Keeper_memory_os_current_receipt_store
open Keeper_memory_os_current_read_anchor
open Keeper_memory_os_current_update

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
