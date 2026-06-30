module Canonical_tool = Agent_sdk.Canonical_tool

let role_to_string role = Agent_sdk.Types.role_to_string role

(* Issue #8623: returns [Some] only for the 4 wire-format names.
   Callers must handle [None] explicitly — the previous Variant
   shape silently routed unknowns to [User], which misattributes
   checkpoint messages: a "system" / "assistant" / "tool" decoded as
   "user" causes the LLM to treat tool output as user instructions,
   echo prior assistant replies as user input, or downgrade system
   prompt privileges. Same anti-pattern class as #8605/#8615. *)
let role_of_string_opt role = Agent_sdk.Types.role_of_string role

let content_blocks_to_json
    (blocks : Agent_sdk.Types.content_block list) : Yojson.Safe.t =
  `List (List.map Agent_sdk.Api.content_block_to_json blocks)

let content_blocks_of_json
    (json : Yojson.Safe.t) : Agent_sdk.Types.content_block list option =
  match Json_util.assoc_member_opt "content_blocks" json with
  | Some (`List blocks) ->
      let parsed = List.filter_map Agent_sdk.Api.content_block_of_json blocks in
      if List.length parsed = List.length blocks then Some parsed else None
  | _ -> None

let string_field_opt key value =
  match value with
  | Some text -> [ (key, `String text) ]
  | None -> []

let metadata_of_json (json : Yojson.Safe.t) : (string * Yojson.Safe.t) list =
  match Json_util.assoc_member_opt "metadata" json with
  | Some (`Assoc fields) -> fields
  | _ -> []

let message_to_json (m : Agent_sdk.Types.message) : Yojson.Safe.t =
  let m = Inference_utils.sanitize_message_utf8 m in
  let tool_call_id =
    match m.tool_call_id with
    | Some _ as explicit -> explicit
    | None -> (
        match m.role with
        | Agent_sdk.Types.Tool ->
            List.find_map
              (fun block ->
                Canonical_tool.tool_result_of_block block
                |> Option.map (fun result -> result.Canonical_tool.call_id))
              m.content
        (* Non-Tool roles never own a tool_call_id. *)
        | Agent_sdk.Types.System
        | Agent_sdk.Types.User
        | Agent_sdk.Types.Assistant -> None)
  in
  let base =
    [
      ("role", `String (role_to_string m.role));
      ("content_blocks", content_blocks_to_json m.content);
    ]
  in
  `Assoc
    (base
     @ string_field_opt "name" m.name
     @ string_field_opt "tool_call_id" tool_call_id
     @ if m.metadata = [] then [] else [ ("metadata", `Assoc m.metadata) ])

let message_of_json (json : Yojson.Safe.t) : Agent_sdk.Types.message =
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
    {
      Agent_sdk.Types.role;
      content;
      name =
        (Json_util.get_string json "name"
         |> Option.map Inference_utils.sanitize_text_utf8);
      tool_call_id =
        (Json_util.get_string json "tool_call_id"
         |> Option.map Inference_utils.sanitize_text_utf8);
      metadata = [];
    }

(** Extract human-readable text from a single history.jsonl line.
    Structured [content_blocks] is the only supported message-content shape. *)
let text_of_history_jsonl_json (json : Yojson.Safe.t) : string =
  let text_of_blocks blocks =
    if blocks = []
    then ""
    else
      Inference_utils.sanitize_text_utf8 (Agent_sdk.Types.text_of_content blocks)
  in
  match content_blocks_of_json json with
  | Some blocks -> text_of_blocks blocks
  | None -> ""
