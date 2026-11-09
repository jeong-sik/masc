type reader =
  | Anonymous
  | Named of { name : string; addressed_by : Board.Agent_id.t -> bool }
  | Operator

let named name =
  Named { name; addressed_by = (fun id -> String.equal name (Board.Agent_id.to_string id)) }

let name = function Anonymous | Operator -> None | Named reader -> Some reader.name
let is_operator = function Operator -> true | Anonymous | Named _ -> false
let cache_key = function
  | Anonymous -> "anonymous"
  | Operator -> "operator"
  | Named reader -> Printf.sprintf "named:%d:%s" (String.length reader.name) reader.name

let can_read_fields ~reader ~author ~visibility ~audience =
  match visibility, reader with
  | (Board.Public | Board.Unlisted | Board.Internal), _ -> true
  | Board.Direct, Operator -> true
  | Board.Direct, Anonymous -> false
  | Board.Direct, Named reader ->
    String.equal reader.name (Board.Agent_id.to_string author)
    || (match audience with
        | Some (Board.Targets targets) -> List.exists reader.addressed_by targets
        | None | Some (Board.Broadcast | Board.Thread_participants | Board.Discoverable) -> false)

let can_read ~reader (post : Board.post) =
  can_read_fields ~reader ~author:post.author ~visibility:post.visibility ~audience:post.audience
