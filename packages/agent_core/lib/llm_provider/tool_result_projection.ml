open Types
module Id_map = Map.Make (String)

type error =
  | Duplicate_tool_use_id of
      { tool_use_id : string
      ; tool_name : string
      }
  | Conflicting_tool_use_id of
      { tool_use_id : string
      ; first_name : string
      ; conflicting_name : string
      }
  | Duplicate_tool_result_id of { tool_use_id : string }
  | Missing_tool_use_id of { tool_use_id : string }
  | Invalid_tool_use_role of
      { tool_use_id : string
      ; role : Types.role
      }
  | Invalid_tool_result_role of
      { tool_use_id : string
      ; role : Types.role
      }

type active_batch =
  { remaining : string Id_map.t
  ; consumed : string Id_map.t
  }

type resolved_message =
  { original : Types.message
  ; content : (Types.content_block * string option) list
  }

type t = resolved_message list

let error_to_string = function
  | Duplicate_tool_use_id { tool_use_id; tool_name } ->
    Printf.sprintf
      "duplicate ToolUse identity %S for name %S in one assistant batch"
      tool_use_id
      tool_name
  | Conflicting_tool_use_id { tool_use_id; first_name; conflicting_name } ->
    Printf.sprintf
      "conflicting ToolUse identity %S names %S and %S in one assistant batch"
      tool_use_id
      first_name
      conflicting_name
  | Duplicate_tool_result_id { tool_use_id } ->
    Printf.sprintf "duplicate ToolResult identity %S in one active tool batch" tool_use_id
  | Missing_tool_use_id { tool_use_id } ->
    Printf.sprintf
      "ToolResult identity %S has no matching ToolUse in the active assistant batch"
      tool_use_id
  | Invalid_tool_use_role { tool_use_id; role } ->
    Printf.sprintf
      "ToolUse identity %S must use role assistant, got role %s"
      tool_use_id
      (Types.role_to_string role)
  | Invalid_tool_result_role { tool_use_id; role } ->
    Printf.sprintf
      "ToolResult identity %S must use role tool, got role %s"
      tool_use_id
      (Types.role_to_string role)
;;

let assistant_message_content blocks =
  let rec loop names resolved = function
    | [] ->
      let batch =
        if Id_map.is_empty names
        then None
        else Some { remaining = names; consumed = Id_map.empty }
      in
      Ok (batch, List.rev resolved)
    | (ToolUse { id; name; _ } as block) :: rest ->
      (match Id_map.find_opt id names with
       | None -> loop (Id_map.add id name names) ((block, None) :: resolved) rest
       | Some first_name when String.equal first_name name ->
         Error (Duplicate_tool_use_id { tool_use_id = id; tool_name = name })
       | Some first_name ->
         Error
           (Conflicting_tool_use_id
              { tool_use_id = id; first_name; conflicting_name = name }))
    | (ToolResult { tool_use_id; _ } as _block) :: _ ->
      Error (Invalid_tool_result_role { tool_use_id; role = Assistant })
    | (( Text _
       | Thinking _
       | ReasoningDetails _
       | RedactedThinking _
       | Image _
       | Document _
       | Audio _ ) as block)
      :: rest -> loop names ((block, None) :: resolved) rest
  in
  loop Id_map.empty [] blocks
;;

let plain_message_content ~role blocks =
  let rec loop resolved = function
    | [] -> Ok (List.rev resolved)
    | ToolUse { id; _ } :: _ -> Error (Invalid_tool_use_role { tool_use_id = id; role })
    | ToolResult { tool_use_id; _ } :: _ ->
      Error (Invalid_tool_result_role { tool_use_id; role })
    | (( Text _
       | Thinking _
       | ReasoningDetails _
       | RedactedThinking _
       | Image _
       | Document _
       | Audio _ ) as block)
      :: rest -> loop ((block, None) :: resolved) rest
  in
  loop [] blocks
;;

let tool_message_content active blocks =
  let rec loop active saw_result resolved = function
    | [] -> Ok ((if saw_result then active else None), List.rev resolved)
    | ToolUse { id; _ } :: _ ->
      Error (Invalid_tool_use_role { tool_use_id = id; role = Tool })
    | (ToolResult { tool_use_id; _ } as block) :: rest ->
      (match active with
       | None -> Error (Missing_tool_use_id { tool_use_id })
       | Some batch ->
         (match Id_map.find_opt tool_use_id batch.remaining with
          | Some tool_name ->
            let active =
              Some
                { remaining = Id_map.remove tool_use_id batch.remaining
                ; consumed = Id_map.add tool_use_id tool_name batch.consumed
                }
            in
            loop active true ((block, Some tool_name) :: resolved) rest
          | None ->
            if Id_map.mem tool_use_id batch.consumed
            then Error (Duplicate_tool_result_id { tool_use_id })
            else Error (Missing_tool_use_id { tool_use_id })))
    | (( Text _
       | Thinking _
       | ReasoningDetails _
       | RedactedThinking _
       | Image _
       | Document _
       | Audio _ ) as block)
      :: rest -> loop active saw_result ((block, None) :: resolved) rest
  in
  loop active false [] blocks
;;

let of_messages messages =
  (* Active correlation state is a persistent map scoped to one canonical
     assistant ToolUse occurrence batch. The returned projection is immutable;
     no provider serializer owns a cursor or scans backward through history. *)
  let rec loop active resolved = function
    | [] -> Ok (List.rev resolved)
    | (message : Types.message) :: rest ->
      let next =
        match message.role with
        | Assistant ->
          Result.map
            (fun (active, content) -> active, { original = message; content })
            (assistant_message_content message.content)
        | Tool ->
          Result.map
            (fun (active, content) -> active, { original = message; content })
            (tool_message_content active message.content)
        | User | System ->
          Result.map
            (fun content -> None, { original = message; content })
            (plain_message_content ~role:message.role message.content)
      in
      (match next with
       | Error _ as error -> error
       | Ok (active, message) -> loop active (message :: resolved) rest)
  in
  loop None [] messages
;;

let messages projection = projection
let original_message resolved = resolved.original
let content resolved = resolved.content

[@@@coverage off]

let message role content : Types.message =
  { role; content; name = None; tool_call_id = None; metadata = [] }
;;

let tool_use id name = ToolUse { id; name; input = `Assoc [] }

let tool_result id =
  ToolResult
    { tool_use_id = id
    ; content = "ok"
    ; outcome = Tool_succeeded
    ; json = None
    ; content_blocks = None
    }
;;

let projected_tool_names projection =
  projection |> messages |> List.concat_map content |> List.filter_map snd
;;

let%test "blank tool identity may be reused by a later occurrence" =
  match
    of_messages
      [ message User [ Text "first" ]
      ; message Assistant [ tool_use "" "lookup" ]
      ; message Tool [ tool_result "" ]
      ; message Assistant [ tool_use "" "write" ]
      ; message Tool [ tool_result "" ]
      ]
  with
  | Ok projection -> projected_tool_names projection = [ "lookup"; "write" ]
  | Error _ -> false
;;

let%test "duplicate identity in one assistant batch is rejected" =
  match
    of_messages
      [ message Assistant [ tool_use "call-1" "lookup"; tool_use "call-1" "lookup" ] ]
  with
  | Error (Duplicate_tool_use_id { tool_use_id = "call-1"; tool_name = "lookup" }) -> true
  | Ok _ | Error _ -> false
;;

let%test "conflicting identity in one assistant batch is rejected" =
  match
    of_messages
      [ message Assistant [ tool_use "call-1" "lookup"; tool_use "call-1" "write" ] ]
  with
  | Error
      (Conflicting_tool_use_id
         { tool_use_id = "call-1"; first_name = "lookup"; conflicting_name = "write" }) ->
    true
  | Ok _ | Error _ -> false
;;

let%test "duplicate result in one active batch is rejected" =
  match
    of_messages
      [ message Assistant [ tool_use "call-1" "lookup" ]
      ; message Tool [ tool_result "call-1"; tool_result "call-1" ]
      ]
  with
  | Error (Duplicate_tool_result_id { tool_use_id = "call-1" }) -> true
  | Ok _ | Error _ -> false
;;

let%test "missing active tool identity is explicit" =
  match of_messages [ message Tool [ tool_result "absent" ] ] with
  | Error (Missing_tool_use_id { tool_use_id = "absent" }) -> true
  | Ok _ | Error _ -> false
;;
