
let role_to_string role = Agent_core.Types.role_to_string role

(* Issue #8623: returns [Some] only for the 4 wire-format names.
   Callers must handle [None] explicitly — the previous Variant
   shape silently routed unknowns to [User], which misattributes
   checkpoint messages: a "system" / "assistant" / "tool" decoded as
   "user" causes the LLM to treat tool output as user instructions,
   echo prior assistant replies as user input, or downgrade system
   prompt privileges. Same anti-pattern class as #8605/#8615. *)
let role_of_string_opt role = Agent_core.Types.role_of_string role

(* Blocks are written in the history codec ({!Agent_core.History}), which
   keeps media by reference and a ToolResult's typed outcome. Its [json]
   payload has no field there, so it rides alongside as [tool_result_json]
   and a ToolResult comes back as it was written (#25109). *)
let tool_result_json_key = "tool_result_json"

let content_block_to_history_json (block : Agent_core.Types.content_block) =
  let json = Agent_core.History.content_block_to_json block in
  match block, json with
  | Agent_core.Types.ToolResult { json = Some payload; _ }, `Assoc fields ->
    `Assoc (fields @ [ tool_result_json_key, payload ])
  | Agent_core.Types.ToolResult { json = Some _; _ },
    (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _)
  | Agent_core.Types.ToolResult { json = None; _ }, _
  | ( ( Agent_core.Types.Text _ | Agent_core.Types.Thinking _
      | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _
      | Agent_core.Types.ToolUse _ | Agent_core.Types.Image _
      | Agent_core.Types.Document _ | Agent_core.Types.Audio _ ),
      _ ) -> json

let content_block_of_history_json (json : Yojson.Safe.t) =
  let block_json, payload =
    match json with
    | `Assoc fields ->
      ( `Assoc (List.filter (fun (key, _) -> not (String.equal key tool_result_json_key)) fields)
      , List.assoc_opt tool_result_json_key fields )
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> json, None
  in
  match Agent_core.History.content_block_of_json block_json, payload with
  | Ok (Agent_core.Types.ToolResult result), payload ->
    Some (Agent_core.Types.ToolResult { result with json = payload })
  | Ok
      (( Agent_core.Types.Text _ | Agent_core.Types.Thinking _
       | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _
       | Agent_core.Types.ToolUse _ | Agent_core.Types.Image _
       | Agent_core.Types.Document _ | Agent_core.Types.Audio _ ) as block),
    None -> Some block
  | Ok
      ( Agent_core.Types.Text _ | Agent_core.Types.Thinking _
      | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _
      | Agent_core.Types.ToolUse _ | Agent_core.Types.Image _
      | Agent_core.Types.Document _ | Agent_core.Types.Audio _ ),
    Some _
  | Error _, _ -> None

let content_blocks_to_json
    (blocks : Agent_core.Types.content_block list) : Yojson.Safe.t =
  `List (List.map content_block_to_history_json blocks)

let content_blocks_of_json
    (json : Yojson.Safe.t) : Agent_core.Types.content_block list option =
  match Json_util.assoc_member_opt "content_blocks" json with
  | Some (`List blocks) ->
      let parsed = List.filter_map content_block_of_history_json blocks in
      if List.length parsed = List.length blocks then Some parsed else None
  | _ -> None

let string_field_opt key value =
  match value with
  | Some text -> [ (key, `String text) ]
  | None -> []

let metadata_of_json (json : Yojson.Safe.t) : (string * Yojson.Safe.t) list =
  match Json_util.assoc_member_opt "metadata" json with
  | Some (`Assoc fields) -> fields
  | None -> []
  | Some _ -> invalid_arg "keeper_context_core: invalid metadata"

let message_to_json (m : Agent_core.Types.message) : Yojson.Safe.t =
  let m = Inference_utils.sanitize_message_utf8 m in
  let tool_call_id =
    match m.tool_call_id with
    | Some _ as explicit -> explicit
    | None -> (
        match m.role with
        | Agent_core.Types.Tool ->
            List.find_map
              (fun (block : Agent_core.Types.content_block) ->
                match block with
                | Agent_core.Types.ToolResult { tool_use_id; _ } -> Some tool_use_id
                | Agent_core.Types.Text _ | Agent_core.Types.Thinking _
                | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _
                | Agent_core.Types.ToolUse _ | Agent_core.Types.Image _
                | Agent_core.Types.Document _ | Agent_core.Types.Audio _ -> None)
              m.content
        (* Non-Tool roles never own a tool_call_id. *)
        | Agent_core.Types.System
        | Agent_core.Types.User
        | Agent_core.Types.Assistant -> None)
  in
  let base =
    [
      ("role", `String (role_to_string m.role));
      ("origin", `String (Agent_core.Types.message_origin_to_string m.origin));
      ("content_blocks", content_blocks_to_json m.content);
    ]
  in
  `Assoc
    (base
     @ string_field_opt "name" m.name
     @ string_field_opt "tool_call_id" tool_call_id
     @ if m.metadata = [] then [] else [ ("metadata", `Assoc m.metadata) ])

let message_of_json (json : Yojson.Safe.t) : Agent_core.Types.message =
  let origin = match json with
    | `Assoc fields ->
      (match List.filter_map (fun (key,value) -> if key="origin" then Some value else None) fields with
       | [`String value] ->
         (match Agent_core.Types.message_origin_of_string value with
          | Some origin -> origin
          | None -> invalid_arg "keeper_context_core: unknown message origin")
       | [] | _::_ -> invalid_arg "keeper_context_core: missing or duplicate message origin")
    | _ -> invalid_arg "keeper_context_core: message must be an object" in
  let raw_role =
    match Json_util.get_string json "role" with
    | Some s -> s
    | None -> invalid_arg "keeper_context_core: missing role field"
  in
  let role =
    match role_of_string_opt raw_role with
    | Some role -> role
    | None ->
        invalid_arg
          (Printf.sprintf "keeper_context_core: unknown role %S" raw_role)
  in
  let content =
    match content_blocks_of_json json with
    | Some blocks -> blocks
    | None ->
        invalid_arg "keeper_context_core: missing or invalid content_blocks"
  in
  Inference_utils.sanitize_message_utf8
    { origin; Agent_core.Types.role;
      content;
      name =
        (Json_util.get_string json "name"
         |> Option.map Inference_utils.sanitize_text_utf8);
      tool_call_id =
        (Json_util.get_string json "tool_call_id"
         |> Option.map Inference_utils.sanitize_text_utf8);
      metadata = metadata_of_json json;
    }

(** Extract human-readable text from a single history.jsonl line.
    Structured [content_blocks] is the only supported message-content shape. *)
let text_of_history_jsonl_json (json : Yojson.Safe.t) : string =
  let text_of_blocks blocks =
    if blocks = []
    then ""
    else
      Inference_utils.sanitize_text_utf8 (Agent_core.Types.text_of_content blocks)
  in
  match content_blocks_of_json json with
  | Some blocks -> text_of_blocks blocks
  | None -> ""

(* How many bytes [message_to_json] would serialize to, counted by writing the
   value and reading how much was written. [Yojson.Safe.to_string] is
   [to_buffer] followed by [Buffer.contents], so the count is the same one and
   the copy is what this drops.

   One buffer per measurer, and a measurer belongs to one walk. [clear] keeps
   the capacity the largest message already paid for, so a walk pays for the
   buffer once instead of once per message; the buffer dies with the measurer.
   Callers that measure a single message still want a measurer -- the buffer
   costs more than the string a single measurement would have built. *)
let message_measurer () =
  let buffer = Buffer.create 65536 in
  fun (message : Agent_core.Types.message) ->
    Buffer.clear buffer;
    Yojson.Safe.to_buffer buffer (message_to_json message);
    (* A [Stored] source is a digest here; the request carries its base64. *)
    List.fold_left
      (fun total block -> total + Agent_core.History.media_wire_length block)
      (Buffer.length buffer)
      message.content
;;
