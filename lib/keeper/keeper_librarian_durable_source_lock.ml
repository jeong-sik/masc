module Request = Keeper_librarian_durable_request
module Capture = Keeper_librarian_durable_capture
module Checkpoint = Keeper_checkpoint_store
module Fragments = Keeper_turn_fragments
module Boundaries = Keeper_turn_boundaries
module Progress = Keeper_librarian_progress
module Official = Keeper_librarian_official_progress
module Cursor = Keeper_external_read_cursor
open Result.Syntax
let require condition detail = if condition then Ok () else Error detail
let parts = function
  | Capture.Held.Checkpoint_only checkpoint -> Some checkpoint,[]
  | Official_only official -> None,official.traces
  | Mixed (checkpoint,official) -> Some checkpoint,official.traces
let same_generation (checkpoint : Capture.Held.checkpoint) boundaries =
  let trace_id=Keeper_id.Trace_id.to_string checkpoint.trace_id in
  List.fold_left (fun result (line,record) ->
    let* ()=result in
    if line<=checkpoint.boundary_lines_seen then Ok () else
    match record with
    | Error error -> Error ("Later completed-turn boundary is unreadable: " ^ Boundaries.read_error_to_string error)
    | Ok {Boundaries.event=History_restarted {trace_id=restarted};_} ->
      require (restarted<>trace_id) "Original checkpoint history generation restarted"
    | Ok {Boundaries.event=Turn_ended {turn_ref;history_at_start=Fresh_history;_};_} ->
      require (Ids.Turn_ref.trace_id turn_ref<>trace_id) "Original checkpoint history generation started fresh"
    | Ok {Boundaries.event=Turn_ended {history_at_start=(Continued_history | Continued_history_from _);_};_} ->
      Ok ()) (Ok ()) boundaries
let positions_unchanged request =
  let source=Request.source request in
  let keeper_id=Request.keeper_id (Request.physical_owner request) in
  let runtime_keepers_dir=Capture.runtime_keepers_dir source in
  let* position=Progress.read ~keepers_dir:runtime_keepers_dir ~keeper_id
    |> Result.map_error Progress.read_error_to_string in
  let* official=Official.read ~keepers_dir:runtime_keepers_dir ~keeper_id
    |> Result.map_error Official.read_error_to_string in
  Ok (position=(Capture.positions source).current && official=(Capture.positions source).official)
let validate_state request =
  let source=Request.source request in
  let keeper_id=Request.keeper_id (Request.physical_owner request) in
  let runtime_keepers_dir=Capture.runtime_keepers_dir source in
  let* ()=Request.confirm_owner request in
  let* unchanged=positions_unchanged request in
  let* ()=require unchanged "Original history read positions changed before Memory publication" in
  let* external_cursor=Cursor.observe ~runtime_keepers_dir ~keeper_name:keeper_id in
  require (Yojson.Safe.equal (Cursor.observation_to_json external_cursor)
    (Cursor.observation_to_json (Capture.external_prepared source)))
    "Original external preparation changed before Memory publication"
(* The external cursor is prepared again on every pass that selects the range,
   so it moves between passes as admissions arrive. Only a publication of the
   original's own preparation requires it to be as captured. *)
type cursor = Prepared_as_captured | Moves | Recovering_settlement | Compatible_publication
type material = Source_only | Message_manifest
let with_fence ?(checkpoint_for_settlement=false) ~request ~cursor ~material read =
  let source=Request.source request and owner=Request.physical_owner request in
  let checkpoint,traces=parts (Capture.source source) in
  let checkpoint_id=Option.map (fun (value : Capture.Held.checkpoint) ->
    Keeper_id.Trace_id.to_string value.trace_id) checkpoint in
  let ids=List.map (fun (trace : Capture.Held.trace) -> trace.id) traces
    @ Option.to_list checkpoint_id |> List.sort_uniq String.compare in
  let root=Keeper_fs.session_store_path_for_base_path (Request.base_path owner) in
  let validate snapshot =
    let* ()=Request.confirm_owner request in
    match cursor with
    | Recovering_settlement ->
      read ~messages:(Option.map Checkpoint.exact_snapshot_messages snapshot) ~manifest:None
    | Prepared_as_captured | Moves | Compatible_publication ->
    let* boundaries=Keeper_turn_boundaries.read ~keepers_dir:(Capture.runtime_keepers_dir source)
      ~keeper_id:(Request.keeper_id owner) in
    let* live =
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | (trace : Capture.Held.trace) :: rest ->
          let session_dir = Filename.concat root trace.id in
          let* main = Fragments.read ~session_dir Fragments.Main in
          let* internal = Fragments.read ~session_dir Fragments.Internal in
          loop ({ Capture.trace_id = trace.id; main; internal } :: acc) rest
      in
      loop [] traces
    in
    let messages=Option.map Checkpoint.exact_snapshot_messages snapshot in
    let* manifest=match material with
      | Source_only ->
        let+ ()=Capture.confirm_sources ~boundaries ~messages ~traces:live source
          |> Result.map_error Capture.error_to_string in None
      | Message_manifest ->
        let+ manifest=Capture.message_manifest ~boundaries ~messages ~traces:live source
          |> Result.map_error Capture.error_to_string in Some manifest in
    let* ()=match checkpoint,snapshot with
      | None,None -> Ok ()
      | Some original,Some _ -> same_generation original boundaries
      | None,Some _ | Some _,None -> Error "Original checkpoint lock observation is missing" in
    let* ()=Keeper_librarian_input_sources.validate_original_selection (Capture.counterparts source)
      ~base_dir:(Request.base_path owner) ~keeper_name:(Request.keeper_id owner)
      |> Result.map_error Keeper_librarian_input_sources.read_error_to_string in
    let* ()=match cursor with
      | Prepared_as_captured -> validate_state request
      | Moves ->
        let* unchanged=positions_unchanged request in
        require unchanged "Original history read positions changed before the floor read its source"
      | Compatible_publication -> Ok ()
      | Recovering_settlement -> Error "Settlement scope entered source-publication validation" in
    read ~messages ~manifest in
  let read_checkpoint=match cursor with
    | Prepared_as_captured | Moves | Compatible_publication -> true
    | Recovering_settlement -> checkpoint_for_settlement in
  let rec lock snapshot = function
    | [] -> validate snapshot
    | id::rest ->
      let session_dir=Filename.concat root id in
      if checkpoint_id=Some id && read_checkpoint then
        Checkpoint.with_agent_core_exact_snapshot ~session_dir ~session_id:id
          (fun actual -> lock (Some actual) rest)
        |> Result.map_error Checkpoint.checkpoint_ref_load_error_to_string |> Result.join
      else
        Checkpoint.with_session_lock ~session_dir (fun _canonical -> lock snapshot rest)
        |> Result.join in
  lock None ids
let with_original ~request publish =
  with_fence ~request ~cursor:Prepared_as_captured ~material:Source_only (fun ~messages:_ ~manifest:_ -> publish ())
let with_original_snapshot ~request read =
  with_fence ~request ~cursor:Moves ~material:Source_only (fun ~messages ~manifest:_ -> read ~messages)
let with_original_settlement ~request settle =
  with_fence ~request ~cursor:Recovering_settlement ~material:Source_only (fun ~messages:_ ~manifest:_ -> settle ())
let with_original_manifest ~request read =
  with_fence ~request ~cursor:Moves ~material:Message_manifest (fun ~messages:_ ~manifest ->
    match manifest with Some manifest -> read manifest | None -> Error "Original source manifest is absent")

type 'a frontier =
  | Advance of { observed : 'a option; target : 'a }
  | Keep_exact of 'a option
  | Keep_later of 'a
type position_plan = {
  request : Request.t;
  atom : Progress.t frontier;
  official : Official.t frontier;
  external_before : Cursor.observation;
}
let atom_frontier plan = plan.atom
let official_frontier plan = plan.official
let before = function Advance {observed;_} -> observed | Keep_exact value -> value | Keep_later value -> Some value
let after = function Advance {target;_} -> Some target | Keep_exact value -> value | Keep_later value -> Some value
let atom_target source = Option.map (fun (range:Keeper_memory_os_current.durable_range_id) : Progress.t ->
  {position={trace_id=range.trace_id;end_atom=range.end_atom;last_atom_digest=range.last_atom_digest};
   boundary_lines_seen=range.boundary_lines_seen}) (Capture.range_id source)
let official_target source = Option.map (fun (range:Keeper_memory_os_current.official_range_id) : Official.t ->
  {boundary_line=List.fold_left (fun line (next,_) -> max line next)
    range.after_boundary_line range.turns}) (Capture.official_range_id source)
let read_positions request =
  let source=Request.source request and owner=Request.physical_owner request in
  let keepers_dir=Capture.runtime_keepers_dir source and keeper_id=Request.keeper_id owner in
  let* atom=Progress.read ~keepers_dir ~keeper_id |> Result.map_error Progress.read_error_to_string in
  let+ official=Official.read ~keepers_dir ~keeper_id |> Result.map_error Official.read_error_to_string in
  atom,official
let captured_or_target ~captured ~target actual =
  actual=captured || Option.exists (fun target -> actual=Some target) target
let frontier ~captured ~target ~actual ~later =
  if actual=captured then Ok (match target with
    | None -> Keep_exact actual
    | Some target -> if actual=Some target then Keep_exact actual else Advance {observed=actual;target})
  else match actual,target with
  | Some actual,Some target when actual=target -> Ok (Keep_exact (Some actual))
  | Some actual,Some target -> let+ ()=later actual target in Keep_later actual
  | None,(None | Some _) | Some _,None -> Error "Original history frontier moved outside its source"
let canonical_atom request ~messages ~lines (actual:Progress.t) (target:Progress.t) =
  let source=Request.source request in
  let checkpoint,_=parts (Capture.source source) in
  let* checkpoint=Option.to_result ~none:"Later atom position has no original checkpoint" checkpoint in
  let* messages=Option.to_result ~none:"Later atom position needs a fresh locked checkpoint; retry" messages in
  let* ()=same_generation checkpoint lines in
  let position=actual.position in
  let count,digest_at=Runtime_model_input_tail_window.atom_opening_index messages in
  let* ()=require (position.trace_id=target.position.trace_id
    && position.trace_id=Keeper_id.Trace_id.to_string checkpoint.trace_id
    && position.end_atom>target.position.end_atom && position.end_atom<=count
    && digest_at (position.end_atom-1)=Some position.last_atom_digest
    && actual.boundary_lines_seen>=target.boundary_lines_seen
    && actual.boundary_lines_seen<=List.length lines)
    "Later atom position is not in the original canonical checkpoint" in
  require (Option.is_some (Boundaries.witness_line ~through:actual.boundary_lines_seen
    ~trace_id:position.trace_id ~end_atom:position.end_atom ~last_atom_digest:position.last_atom_digest lines))
    "Later atom position has no canonical completed-history witness"
let canonical_official ~lines (actual:Official.t) (target:Official.t) =
  require (actual.boundary_line>target.boundary_line
    && List.exists (fun (line,decoded) -> line=actual.boundary_line && match decoded with
      | Ok {Boundaries.event=Turn_ended {position=No_atom_history;_};_} -> true
      | Ok {event=History_restarted _;_}
      | Ok {event=Turn_ended {position=(Atom_history _ | Empty_atom_history | Stale_noop);_};_}
      | Error _ -> false) lines)
    "Later official position has no canonical completed official turn"
let make_plan ~publication ~request ~messages =
  let* ()=Request.confirm_owner request in
  let source=Request.source request and owner=Request.physical_owner request in
  let positions=Capture.positions source in
  let* atom,official=read_positions request in
  let atom_target=atom_target source and official_target=official_target source in
  let* lines=if captured_or_target ~captured:positions.current ~target:atom_target atom
    && captured_or_target ~captured:positions.official ~target:official_target official then Ok []
    else
      let* lines=Boundaries.read ~keepers_dir:(Capture.runtime_keepers_dir source) ~keeper_id:(Request.keeper_id owner) in
      let+ ()=Capture.confirm_boundary_prefix ~boundaries:lines source |> Result.map_error Capture.error_to_string in lines in
  let* atom=frontier ~captured:positions.current ~target:atom_target ~actual:atom
    ~later:(canonical_atom request ~messages ~lines) in
  let* official=frontier ~captured:positions.official ~target:official_target ~actual:official
    ~later:(canonical_official ~lines) in
  let* external_before=Cursor.observe ~runtime_keepers_dir:(Capture.runtime_keepers_dir source)
    ~keeper_name:(Request.keeper_id owner) in
  let through=Keeper_librarian_input_sources.external_through (Capture.counterparts source) in
  let* ()=require (Yojson.Safe.equal (Cursor.observation_to_json external_before)
      (Cursor.observation_to_json (Capture.external_prepared source))
    || (not publication && Cursor.observation_matches_preparation external_before
      ~after:through ~through ~atom:None ~official:None))
    "Original external preparation changed before position settlement" in
  Ok {request;atom;official;external_before}
let recheck_positions plan atom official =
  let* ()=Request.confirm_owner plan.request in
  let* actual_atom,actual_official=read_positions plan.request in
  require (actual_atom=atom && actual_official=official) "Original history frontiers changed during their locked plan"
let recheck_before plan =
  let* ()=recheck_positions plan (before plan.atom) (before plan.official) in
  let source=Request.source plan.request and owner=Request.physical_owner plan.request in
  let* actual=Cursor.observe ~runtime_keepers_dir:(Capture.runtime_keepers_dir source) ~keeper_name:(Request.keeper_id owner) in
  require (Yojson.Safe.equal (Cursor.observation_to_json actual) (Cursor.observation_to_json plan.external_before))
    "Original external preparation changed during its locked plan"
let recheck_after plan =
  let* ()=recheck_positions plan (after plan.atom) (after plan.official) in
  let source=Request.source plan.request and owner=Request.physical_owner plan.request in
  let* actual=Cursor.observe ~runtime_keepers_dir:(Capture.runtime_keepers_dir source) ~keeper_name:(Request.keeper_id owner) in
  let through=Keeper_librarian_input_sources.external_through (Capture.counterparts source) in
  require (Cursor.observation_matches_preparation actual ~after:through ~through ~atom:None ~official:None)
    "Original external ACK remains unconfirmed"
let with_original_publication ~request publish =
  with_fence ~request ~cursor:Compatible_publication ~material:Source_only (fun ~messages ~manifest:_ ->
    let* plan=make_plan ~publication:true ~request ~messages in publish plan)
let with_original_settlement_plan ~request settle =
  let source=Request.source request in
  let* atom,_=read_positions request in
  (* This read chooses only whether to load the checkpoint. The locked read
     in [make_plan] is authoritative and refuses a changed, insufficient hint. *)
  let checkpoint_for_settlement=not (captured_or_target
    ~captured:(Capture.positions source).current ~target:(atom_target source) atom) in
  with_fence ~checkpoint_for_settlement ~request ~cursor:Recovering_settlement ~material:Source_only
    (fun ~messages ~manifest:_ -> let* plan=make_plan ~publication:false ~request ~messages in settle plan)
