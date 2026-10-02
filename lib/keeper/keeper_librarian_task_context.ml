module B = Keeper_turn_boundaries
module Window = Runtime_model_input_tail_window

type source =
  | Atom_span of { trace_id : string; start_atom : int; end_atom : int }
  | Official_turn
  | Boundary_only

type attribution =
  | Observed of { turn_ref : Ids.Turn_ref.t; task_context : Keeper_turn_task_context.t }
  | Unattributed

type scope = { source : source; attribution : attribution }
type t = { scope : scope; first_message : int; after_message : int;
  first_tool_observation : int; after_tool_observation : int }

let atom_spans ~trace_id ~messages ~start_atom ~end_atom ~boundary =
  let span attribution start_atom end_atom =
    {source=Atom_span {trace_id;start_atom;end_atom};attribution} in
  let gap start_atom end_atom =
    if start_atom < end_atom then [span Unattributed start_atom end_atom] else [] in
  match boundary with
  | Some { B.event = B.Turn_ended {turn_ref;task_context;history_at_start;
      position=B.Atom_history position}; _ }
    when String.equal trace_id (Ids.Turn_ref.trace_id turn_ref)
      && end_atom <= position.end_atom
      && Window.atom_opening_digest messages (position.end_atom - 1)
         = Some position.last_atom_digest ->
    let attribution = Observed {turn_ref;task_context} in
    let admitted_start = match history_at_start with
      | B.Fresh_history -> Some 0
      | B.Continued_history -> None
      | B.Continued_history_from {start_atom;start_atom_digest} ->
        if start_atom > 0 && start_atom <= position.end_atom
           && Window.atom_opening_digest messages (start_atom - 1) = Some start_atom_digest
        then Some start_atom else None in
    (match admitted_start with
     | Some admitted_start ->
       let known_start = max start_atom admitted_start in
       gap start_atom (min end_atom known_start)
       @ (if known_start < end_atom then [span attribution known_start end_atom] else [])
     | None -> gap start_atom end_atom @ [{source=Boundary_only;attribution}])
  | Some _ | None -> gap start_atom end_atom

let source_to_json = function
  | Atom_span {trace_id;start_atom;end_atom} ->
    `Assoc ["kind",`String "atoms";"trace_id",`String trace_id;
      "start_atom",`Int start_atom;"end_atom",`Int end_atom]
  | Official_turn -> `Assoc ["kind",`String "official_turn"]
  | Boundary_only -> `Assoc ["kind",`String "boundary_only"]

let to_json values = `List (List.map (fun {scope;first_message;after_message;first_tool_observation;after_tool_observation} ->
  let attribution = match scope.attribution with
    | Unattributed -> `Assoc ["kind",`String "unattributed"]
    | Observed {turn_ref;task_context} ->
      `Assoc ["kind",`String "observed";"turn_ref",Ids.Turn_ref.to_yojson turn_ref;
        "task_context",Keeper_turn_task_context.to_json task_context] in
  `Assoc ["source",source_to_json scope.source;"attribution",attribution;
    "first_message",`Int first_message;"after_message",`Int after_message;
    "first_tool_observation",`Int first_tool_observation;
    "after_tool_observation",`Int after_tool_observation]) values)
