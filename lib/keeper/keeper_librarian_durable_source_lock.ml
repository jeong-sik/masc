module Request = Keeper_librarian_durable_request
module Capture = Keeper_librarian_durable_capture
module Checkpoint = Keeper_checkpoint_store
module Fragments = Keeper_turn_fragments
module Boundaries = Keeper_turn_boundaries
module Progress = Keeper_librarian_progress
module Official = Keeper_librarian_official_progress
module Cursor = Keeper_external_read_cursor
module Current = Keeper_memory_os_current
let ( let* ) = Result.bind
let require condition detail = if condition then Ok () else Error detail
let rec prefix equal before current = match before,current with
  | [],_ -> true
  | _::_,[] -> false
  | first::rest,other::tail -> equal first other && prefix equal rest tail
let parts = function
  | Capture.Checkpoint_only checkpoint -> Some checkpoint,[]
  | Official_only official -> None,official.traces
  | Mixed (checkpoint,official) -> Some checkpoint,official.traces
let same_generation (checkpoint : Capture.checkpoint) boundaries =
  let trace_id=Keeper_id.Trace_id.to_string checkpoint.reference.trace_id in
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
let validate_state request =
  let source=Request.source request in
  let owner=Request.physical_owner request in
  let keeper_id=Request.keeper_id owner in
  let runtime_keepers_dir=Capture.runtime_keepers_dir source in
  let* ()=Request.confirm_owner request in
  let* position=Progress.read ~keepers_dir:runtime_keepers_dir ~keeper_id
    |> Result.map_error Progress.read_error_to_string in
  let* official=Official.read ~keepers_dir:runtime_keepers_dir ~keeper_id
    |> Result.map_error Official.read_error_to_string in
  let* ()=require (position=(Capture.positions source).current
    && official=(Capture.positions source).official)
    "Original history read positions changed before Memory publication" in
  let* external_cursor=Cursor.observe ~runtime_keepers_dir ~keeper_name:keeper_id in
  let* ()=require (Yojson.Safe.equal (Cursor.observation_to_json external_cursor)
    (Cursor.observation_to_json (Capture.external_prepared source)))
    "Original external preparation changed before Memory publication" in
  let* snapshot=Current.read_for_keepers_dir ~keepers_dir:(Request.keepers_dir owner) ~keeper_id in
  let revision=Option.map (fun (snapshot : Current.t) -> snapshot.revision) snapshot in
  let facts=Option.map (fun (snapshot : Current.t) -> snapshot.facts) snapshot in
  let original_facts=Option.map (fun (current : Keeper_librarian.current_selection) -> current.facts)
    (Capture.input source).current in
  require (revision=Capture.expected_revision source && facts=original_facts)
    "Original complete current Memory changed before publication"
let with_original ~request publish =
  let source=Request.source request and owner=Request.physical_owner request in
  let checkpoint,traces=parts (Capture.source source) in
  let checkpoint_id=Option.map (fun (value : Capture.checkpoint) ->
    Keeper_id.Trace_id.to_string value.reference.trace_id) checkpoint in
  let ids=List.map (fun (trace : Capture.official_trace) -> trace.trace_id) traces
    @ Option.to_list checkpoint_id |> List.sort_uniq String.compare in
  let root=Keeper_fs.session_store_path_for_base_path (Request.base_path owner) in
  let validate snapshot =
    let* ()=Request.confirm_owner request in
    let* boundaries=Keeper_turn_boundaries.read ~keepers_dir:(Capture.runtime_keepers_dir source)
      ~keeper_id:(Request.keeper_id owner) in
    let* ()=require (prefix ( = ) (Capture.boundaries source) boundaries)
      "Original completed-turn boundary prefix changed" in
    let* ()=match checkpoint,snapshot with
      | None,None -> Ok ()
      | Some original,Some current ->
        let* ()=same_generation original boundaries in
        (* The actual checkpoint deliberately does not persist richer live
           ToolResult.json. Compare the checkpoint-bound representation on
           both sides; the separate original request still retains all rich
           input fields and is never reconstructed from this projection. *)
        let same_message left right=Yojson.Safe.equal
          (Agent_core.Checkpoint.message_to_json left) (Agent_core.Checkpoint.message_to_json right) in
        require (prefix same_message original.messages (Checkpoint.exact_snapshot_messages current))
          "Original checkpoint message prefix changed"
      | None,Some _ | Some _,None -> Error "Original checkpoint lock observation is missing" in
    let* ()=List.fold_left (fun result (trace : Capture.official_trace) ->
      let* ()=result in
      let session_dir=Filename.concat root trace.trace_id in
      let* main=Fragments.read ~session_dir Fragments.Main in
      let* internal=Fragments.read ~session_dir Fragments.Internal in
      require (prefix ( = ) trace.main main && prefix ( = ) trace.internal internal)
        "Original official-client fragment prefix changed") (Ok ()) traces in
    let* ()=Keeper_librarian_input_sources.validate_original_selection (Capture.counterparts source)
      ~base_dir:(Request.base_path owner) ~keeper_name:(Request.keeper_id owner)
      |> Result.map_error Keeper_librarian_input_sources.read_error_to_string in
    let* ()=validate_state request in
    publish () in
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
