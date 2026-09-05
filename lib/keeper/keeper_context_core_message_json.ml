module Canonical_tool = Agent_core.Canonical_tool

let role_to_string role = Agent_core.Types.role_to_string role

(* Issue #8623: returns [Some] only for the 4 wire-format names.
   Callers must handle [None] explicitly — the previous Variant
   shape silently routed unknowns to [User], which misattributes
   checkpoint messages: a "system" / "assistant" / "tool" decoded as
   "user" causes the LLM to treat tool output as user instructions,
   echo prior assistant replies as user input, or downgrade system
   prompt privileges. Same anti-pattern class as #8605/#8615. *)
let role_of_string_opt role = Agent_core.Types.role_of_string role

(* [content_block_to_json] is the provider-wire projection, and for ToolResult
   the wire cannot carry everything the type holds: [outcome] flattens to
   [is_error], and [json] has no field at all. Reading that back guesses — any
   error becomes [Reported_tool_error], and [json] is re-derived by parsing
   [content], which only agrees when the two happened to be the same text.

   History is not a wire. These two fields ride alongside the wire shape so a
   ToolResult comes back as it was written (#25109). A block without them
   parses exactly as before. *)
let tool_result_history_fields (block : Agent_core.Types.content_block) =
  match block with
  | Agent_core.Types.ToolResult { outcome; json; _ } ->
      let outcome_field =
        match outcome with
        | Agent_core.Types.Tool_succeeded -> []
        | Agent_core.Types.Tool_failed { failure_kind; error_class } ->
            [ ( "tool_failure",
                `Assoc
                  (( "failure_kind",
                     Agent_core.Types.tool_failure_kind_to_yojson failure_kind )
                  :: (match error_class with
                     | Some cls ->
                         [ ( "error_class",
                             Agent_core.Types.tool_error_class_to_yojson cls ) ]
                     | None -> [])) ) ]
      in
      (match json with
       | Some payload -> ("tool_result_json", payload) :: outcome_field
       | None -> outcome_field)
  | _ -> []

let content_block_to_history_json block =
  match
    ( Agent_core.Llm_provider.Api_common.content_block_to_json block,
      tool_result_history_fields block )
  with
  | wire, [] -> wire
  | `Assoc wire, extra -> `Assoc (wire @ extra)
  | wire, _ -> wire

let content_block_of_history_json json =
  match
    Agent_core.Llm_provider.Api_common.content_block_of_json
      ~parse_tool_result_json:false
      json
  with
  | Some (Agent_core.Types.ToolResult result) ->
      let outcome =
        match Json_util.assoc_member_opt "tool_failure" json with
        | Some (`Assoc _ as failure) -> (
            let kind =
              Json_util.assoc_member_opt "failure_kind" failure
              |> Option.map Agent_core.Types.tool_failure_kind_of_yojson
            in
            let error_class =
              match Json_util.assoc_member_opt "error_class" failure with
              | Some value -> (
                  match Agent_core.Types.tool_error_class_of_yojson value with
                  | Ok cls -> Some cls
                  | Error _ -> None)
              | None -> None
            in
            match kind with
            | Some (Ok failure_kind) ->
                Agent_core.Types.Tool_failed { failure_kind; error_class }
            | _ -> result.outcome)
        | _ -> result.outcome
      in
      let json_payload =
        match Json_util.assoc_member_opt "tool_result_json" json with
        | Some payload -> Some payload
        | None -> None
      in
      Some
        (Agent_core.Types.ToolResult
           { result with outcome; json = json_payload })
  | other -> other

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
  | _ -> []

let message_to_json (m : Agent_core.Types.message) : Yojson.Safe.t =
  let m = Inference_utils.sanitize_message_utf8 m in
  let tool_call_id =
    match m.tool_call_id with
    | Some _ as explicit -> explicit
    | None -> (
        match m.role with
        | Agent_core.Types.Tool ->
            List.find_map
              (fun block ->
                Canonical_tool.tool_result_of_block block
                |> Option.map (fun result -> result.Canonical_tool.call_id))
              m.content
        (* Non-Tool roles never own a tool_call_id. *)
        | Agent_core.Types.System
        | Agent_core.Types.User
        | Agent_core.Types.Assistant -> None)
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

let message_of_json (json : Yojson.Safe.t) : Agent_core.Types.message =
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
      Agent_core.Types.role;
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
      Inference_utils.sanitize_text_utf8 (Agent_core.Types.text_of_content blocks)
  in
  match content_blocks_of_json json with
  | Some blocks -> text_of_blocks blocks
  | None -> ""
