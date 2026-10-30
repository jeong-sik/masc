open Types

type priority =
  | Preserve_input_order
  | Visual_first

let reorder priority (blocks : content_block list) : content_block list =
  match priority with
  | Preserve_input_order -> blocks
  | Visual_first ->
    let is_visual = function
      | Image _ | Audio _ | Document _ -> true
      | Text _
      | Thinking _
      | ReasoningDetails _
      | RedactedThinking _
      | ToolUse _
      | ToolResult _ -> false
    in
    let visuals, others = List.partition is_visual blocks in
    visuals @ others
;;
