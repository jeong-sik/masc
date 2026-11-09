type target = Post of string | Comment of string
type t = { checked : (target, bool) Hashtbl.t }
type proof = target list

let create () = { checked = Hashtbl.create 32 }

let public_parent = function
  | Post post_id ->
    Board_dispatch.read_post_for_evidence_unchecked ~post_id
    |> Result.map_error Board.board_error_of_read_error
  | Comment comment_id ->
    Board_dispatch.get_comment_parent_for_evidence_unchecked ~comment_id

let is_public target =
  match public_parent target with
  | Ok { visibility = Board.Public; _ } -> true
  | Ok { visibility = (Board.Unlisted | Board.Internal | Board.Direct); _ }
  | Error _ -> false

let check reader target =
  match Hashtbl.find_opt reader.checked target with
  | Some result -> result
  | None ->
    let result = is_public target in
    Hashtbl.add reader.checked target result;
    result

let targets (event : Activity_graph.event) =
  let fields = match event.payload with `Assoc fields -> fields | _ -> [] in
  let string_field name =
    match List.assoc_opt name fields with Some (`String value) -> Some value | _ -> None
  in
  let target kind id =
    match kind with "post" -> Some (Post id) | "comment" -> Some (Comment id) | _ -> None
  in
  let direct =
    [ Option.map (fun id -> Post id) (string_field "post_id")
    ; Option.map (fun id -> Comment id) (string_field "comment_id")
    ; Option.bind event.subject (fun subject -> target subject.kind subject.id)
    ]
  in
  let indirect =
    match string_field "target_id" with
    | None -> []
    | Some id ->
      [ Option.bind (string_field "target_kind") (fun kind -> target kind id)
      ; Option.bind (string_field "target_type") (fun kind -> target kind id)
      ]
  in
  List.filter_map Fun.id (direct @ indirect) |> List.sort_uniq Stdlib.compare

let safe_board_tool_metadata fields =
  List.assoc_opt "tool_io_redacted" fields = Some (`Bool true)
  && List.for_all (function
    | ("tool_name" | "source" | "provider" | "keeper_name"), `String _ -> true
    | ("success" | "tool_io_redacted"), `Bool _ -> true
    | ("duration_ms" | "agent_core_turn" | "keeper_turn_id"), (`Int _ | `Null) -> true
    | "task_id", (`String _ | `Null) -> true
    | ("error" | "tool_args_preview" | "typed_outcome"), `Null -> true
    | _ -> false) fields

let keep reader (event : Activity_graph.event) =
  match Event_kind.Board.of_string event.kind with
  | None ->
    (* Old generic tool rows can contain Board arguments/results in previews.
       They have no authoritative parent reference, so they cannot authorize
       their content on this public projection. Keep other tool telemetry. *)
    (match Activity_graph.tool_execution_event_kind_of_string event.kind with
     | None -> true
     | Some (Activity_graph.External_tool_called | Keeper_in_turn_tool_executed) ->
       match event.payload with
       | `Assoc fields ->
         (match List.assoc_opt "tool_name" fields with
          | Some (`String name) ->
            (match Tool_name.Board_name.of_string name with
             | None -> true
             | Some _ -> safe_board_tool_metadata fields)
          | _ -> true)
       | _ -> true)
  | Some (Event_kind.Board.Posted | Commented | Voted | Deleted) ->
    match targets event with
    | [] -> false
    | targets -> List.for_all (check reader) targets

let proof reader =
  Hashtbl.fold (fun target allowed acc -> if allowed then target :: acc else acc)
    reader.checked []

let is_current proof = List.for_all is_public proof
