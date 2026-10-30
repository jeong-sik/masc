module Request = Keeper_librarian_durable_request
module Source = Keeper_librarian_durable_capture
module Current = Keeper_memory_os_current
module Boundaries = Keeper_turn_boundaries
module Atom = Keeper_librarian_progress
module Official = Keeper_librarian_official_progress
module External = Keeper_external_read_cursor
open Result.Syntax
let atom_past (old:Current.durable_range_id) (actual:Current.durable_range_id) (cursor:Atom.t) =
  actual.receipt_scope=old.receipt_scope && actual.trace_id=old.trace_id
  && actual.history_start_boundary_line=old.history_start_boundary_line
  && actual.end_atom>=old.end_atom && actual.end_boundary_line>=old.end_boundary_line
  && (actual.end_atom<>old.end_atom || actual.last_atom_digest=old.last_atom_digest)
  && cursor.position.trace_id=old.trace_id && cursor.position.end_atom>=old.end_atom
  && (cursor.position.end_atom<>old.end_atom || cursor.position.last_atom_digest=old.last_atom_digest)
let official_end (range:Current.official_range_id) =
  List.fold_left (fun latest (line,_) -> max latest line) range.after_boundary_line range.turns
let official_past (old:Current.official_range_id) (actual:Current.official_range_id) (cursor:Official.t) =
  actual.receipt_scope=old.receipt_scope && official_end actual>=official_end old
  && cursor.boundary_line>=official_end old
let atom_cut_matches lines (range:Current.durable_range_id) =
  match List.assoc_opt range.end_boundary_line lines with
  | Some (Ok record) ->
    (match Boundaries.atom_position_stated ~trace_id:range.trace_id record with
     | Some (_,end_atom,digest) -> end_atom=range.end_atom && digest=range.last_atom_digest
     | None -> false)
  | None | Some (Error _) -> false
let official_cuts_match lines (range:Current.official_range_id) =
  List.for_all (fun (line,turn_ref) ->
    match List.assoc_opt line lines with
    | Some (Ok record) ->
      (match record.Boundaries.event with
       | History_restarted _ -> false
       | Turn_ended {turn_ref=actual;position;_} ->
         match position with
         | No_atom_history -> Ids.Turn_ref.equal turn_ref actual
         | Atom_history _ | Empty_atom_history | Stale_noop -> false)
    | None | Some (Error _) -> false) range.turns
let past_original request =
  let source=Request.source request and owner=Request.physical_owner request in
  let keepers_dir=Request.keepers_dir owner and keeper_id=Request.keeper_id owner in
  let runtime_keepers_dir=Source.runtime_keepers_dir source in
  let* external_cursor=External.observe ~runtime_keepers_dir ~keeper_name:keeper_id in
  if External.observation_offset external_cursor<Keeper_librarian_input_sources.external_through (Source.counterparts source)
  then Ok false else
  let* atom=match Source.range_id source with
    | None -> Ok None
    | Some expected ->
      let* actual=Current.committed_durable_coverage ~keepers_dir ~keeper_id ~receipt_scope:expected.receipt_scope in
      let* cursor=Atom.read ~keepers_dir:runtime_keepers_dir ~keeper_id
        |> Result.map_error Atom.read_error_to_string in
      Ok (Some (match actual,cursor with Some actual,Some cursor -> atom_past expected actual cursor
        | (None | Some _),(None | Some _) -> false)) in
  let* official=match Source.official_range_id source with
    | None -> Ok None
    | Some expected ->
      let* actual=Current.committed_official_coverage ~keepers_dir ~keeper_id ~receipt_scope:expected.receipt_scope in
      let* cursor=Official.read ~keepers_dir:runtime_keepers_dir ~keeper_id
        |> Result.map_error Official.read_error_to_string in
      Ok (Some (match actual,cursor with Some actual,Some cursor -> official_past expected actual cursor
        | (None | Some _),(None | Some _) -> false)) in
  let proofs=Option.to_list atom @ Option.to_list official in
  if proofs=[] || not (List.for_all Fun.id proofs) then Ok false else
  let* lines=Boundaries.read ~keepers_dir:runtime_keepers_dir ~keeper_id in
  Ok (Option.fold ~none:true ~some:(atom_cut_matches lines) (Source.range_id source)
    && Option.fold ~none:true ~some:(official_cuts_match lines) (Source.official_range_id source))
