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
type cursor = Prepared_as_captured | Moves
let with_fence ~request ~cursor read =
  let source=Request.source request and owner=Request.physical_owner request in
  let checkpoint,traces=parts (Capture.source source) in
  let checkpoint_id=Option.map (fun (value : Capture.Held.checkpoint) ->
    Keeper_id.Trace_id.to_string value.trace_id) checkpoint in
  let ids=List.map (fun (trace : Capture.Held.trace) -> trace.id) traces
    @ Option.to_list checkpoint_id |> List.sort_uniq String.compare in
  let root=Keeper_fs.session_store_path_for_base_path (Request.base_path owner) in
  let validate snapshot =
    let* ()=Request.confirm_owner request in
    let* boundaries=Keeper_turn_boundaries.read ~keepers_dir:(Capture.runtime_keepers_dir source)
      ~keeper_id:(Request.keeper_id owner) in
    let* live=List.fold_right (fun (trace : Capture.Held.trace) rest ->
      let* rest=rest in
      let session_dir=Filename.concat root trace.id in
      let* main=Fragments.read ~session_dir Fragments.Main in
      let* internal=Fragments.read ~session_dir Fragments.Internal in
      Ok ({Capture.trace_id=trace.id;main;internal}::rest)) traces (Ok []) in
    let* ()=Capture.confirm_sources ~boundaries ~messages:(Option.map Checkpoint.exact_snapshot_messages snapshot)
      ~traces:live source |> Result.map_error Capture.error_to_string in
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
        require unchanged "Original history read positions changed before the floor read its source" in
    read ~messages:(Option.map Checkpoint.exact_snapshot_messages snapshot) in
  let rec lock snapshot = function
    | [] -> validate snapshot
    | id::rest ->
      let session_dir=Filename.concat root id in
      if checkpoint_id=Some id then
        Checkpoint.with_agent_core_exact_snapshot ~session_dir ~session_id:id
          (fun actual -> lock (Some actual) rest)
        |> Result.map_error Checkpoint.checkpoint_ref_load_error_to_string |> Result.join
      else
        Checkpoint.with_session_lock ~session_dir (fun _canonical -> lock snapshot rest)
        |> Result.join in
  lock None ids
let with_original ~request publish =
  with_fence ~request ~cursor:Prepared_as_captured (fun ~messages:_ -> publish ())
let with_original_snapshot ~request read = with_fence ~request ~cursor:Moves read
