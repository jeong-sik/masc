type reader =
  | Anonymous
  | Named of { name : string; addressed_by : Board_types.Agent_id.t -> bool }
  | Operator

let named name =
  Named { name; addressed_by = (fun id -> String.equal name (Board_types.Agent_id.to_string id)) }

let name = function Anonymous | Operator -> None | Named reader -> Some reader.name
let is_operator = function Operator -> true | Anonymous | Named _ -> false
let cache_key = function
  | Anonymous -> "anonymous"
  | Operator -> "operator"
  | Named reader -> Printf.sprintf "named:%d:%s" (String.length reader.name) reader.name

let can_read_fields ~reader ~author ~visibility ~audience =
  match visibility, reader with
  | (Board_types.Public | Board_types.Unlisted | Board_types.Internal), _ -> true
  | Board_types.Direct, Operator -> true
  | Board_types.Direct, Anonymous -> false
  | Board_types.Direct, Named reader ->
    String.equal reader.name (Board_types.Agent_id.to_string author)
    || (match audience with
        | Some (Board_types.Targets targets) -> List.exists reader.addressed_by targets
        | None | Some (Board_types.Broadcast | Board_types.Thread_participants | Board_types.Discoverable) -> false)

let can_read ~reader (post : Board_types.post) =
  can_read_fields ~reader ~author:post.author ~visibility:post.visibility ~audience:post.audience

let can_post_in_sub_board ~author_id (board : Board_types.sub_board) =
  let author = Board_types.Agent_id.to_string author_id in
  let owner = Board_types.Agent_id.to_string board.owner in
  match board.access with
  | Board_types.Open -> true
  | Board_types.Owner_only -> String.equal author owner
  | Board_types.Members_only ->
    String.equal author owner || List.exists (fun member ->
      String.equal author (Board_types.Agent_id.to_string member)) board.members
