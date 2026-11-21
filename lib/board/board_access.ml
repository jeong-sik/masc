type reader =
  | Anonymous
  | Named of { name : string; addressed_by : Board_types.Agent_id.t -> bool }
  | Operator
  | Workspace_member of
      { actor_id : string
      ; owned_keeper_ids : string list
      }

let named name =
  Named { name; addressed_by = (fun id -> String.equal name (Board_types.Agent_id.to_string id)) }

let name = function
  | Anonymous | Operator -> None
  | Named reader -> Some reader.name
  | Workspace_member reader -> Some reader.actor_id

let is_operator = function Operator -> true | Anonymous | Named _ | Workspace_member _ -> false

let cache_key = function
  | Anonymous -> "anonymous"
  | Operator -> "operator"
  | Named reader -> Printf.sprintf "named:%d:%s" (String.length reader.name) reader.name
  | Workspace_member reader ->
    (* One caller's Direct posts and votes must never be served to another from
       the dashboard cache, so the key names the actor and every Keeper whose
       deliveries it may read. The Keeper list is sorted: two readers with the
       same set must share one entry. *)
    let keepers = List.sort_uniq String.compare reader.owned_keeper_ids in
    Printf.sprintf
      "member:%d:%s|keepers:%d:%s"
      (String.length reader.actor_id)
      reader.actor_id
      (List.length keepers)
      (String.concat "," keepers)

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
  | Board_types.Direct, Workspace_member reader ->
    (* A workspace Admin is an operations role, not a reader of every Direct
       post: the same rule applies to every member. The author reads their own
       post, an addressed member reads it, and an owner reads what was delivered
       to one of their Keepers. A Direct post with no valid target stays closed. *)
    let addressed target =
      let id = Board_types.Agent_id.to_string target in
      String.equal id reader.actor_id || List.mem id reader.owned_keeper_ids
    in
    String.equal reader.actor_id (Board_types.Agent_id.to_string author)
    || (match audience with
        | Some (Board_types.Targets targets) -> List.exists addressed targets
        | None
        | Some (Board_types.Broadcast | Board_types.Thread_participants | Board_types.Discoverable) ->
          false)

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
