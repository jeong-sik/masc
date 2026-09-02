module Types = Agent_core.Types

type section = Text of string | Json of string | Marker of string

(* The block walk reads the same typed decode the wire writer used, so a new
   block variant is a compile error here rather than a silent drop. Media
   blocks state their size and nothing else: their bytes are not readable
   text and pretending otherwise helps no one. *)
let rec block_sections (block : Types.content_block) : section list =
  match block with
  | Types.Text text -> [ Text text ]
  | Types.Thinking { content; _ } -> [ Marker "thinking"; Text content ]
  | Types.ReasoningDetails { reasoning_content; details } ->
      [ Marker "reasoning" ]
      @ [ Text (Types.reasoning_details_text ~reasoning_content ~details) ]
  | Types.RedactedThinking _ -> [ Marker "redacted thinking" ]
  | Types.ToolUse { name; input; _ } ->
      [ Marker ("tool use " ^ name); Json (Yojson.Safe.pretty_to_string input) ]
  | Types.ToolResult { content; outcome; json; content_blocks; _ } ->
      let marker =
        if Types.tool_result_outcome_is_error outcome then "tool result (error)"
        else "tool result"
      in
      let structured =
        match content_blocks with
        | Some blocks -> List.concat_map block_sections blocks
        | None -> [ Text content ]
      in
      let payload =
        match json with Some payload -> [ Json (Yojson.Safe.pretty_to_string payload) ] | None -> []
      in
      Marker marker :: structured @ payload
  | Types.Image { media_type; data; _ } ->
      [ Marker (Printf.sprintf "image %s, %d bytes" media_type (String.length data)) ]
  | Types.Document { media_type; data; _ } ->
      [ Marker (Printf.sprintf "document %s, %d bytes" media_type (String.length data)) ]
  | Types.Audio { media_type; data; _ } ->
      [ Marker (Printf.sprintf "audio %s, %d bytes" media_type (String.length data)) ]

let sections ~text =
  match Yojson.Safe.from_string text with
  | Error _ -> [ Text text ]
  | Ok json -> (
    match Masc.Keeper_context_core_message_json.content_blocks_of_json json with
    | Some blocks -> List.concat_map block_sections blocks
    | None -> [ Json text ])
