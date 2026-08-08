(** Redacted response-shape diagnostics for completed provider responses. *)

type t =
  { text_chars : int
  ; text_blocks : int
  ; thinking_blocks : int
  ; thinking_chars : int
  ; redacted_thinking_blocks : int
  ; tool_use_count : int
  ; tool_result_count : int
  ; image_count : int
  ; document_count : int
  ; audio_count : int
  ; content_kinds : string list
  }

type content_shape =
  | Empty
  | Thinking_only
  | Blank_text_only
  | Tool_result_only
  | Media_only
  | Mixed_without_deliverable_content
  | Has_deliverable_content

let empty =
  { text_chars = 0
  ; text_blocks = 0
  ; thinking_blocks = 0
  ; thinking_chars = 0
  ; redacted_thinking_blocks = 0
  ; tool_use_count = 0
  ; tool_result_count = 0
  ; image_count = 0
  ; document_count = 0
  ; audio_count = 0
  ; content_kinds = []
  }
;;

let add_kind kind shape = { shape with content_kinds = kind :: shape.content_kinds }

let dedupe_keep_order values =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | value :: rest ->
      if List.exists (String.equal value) seen
      then loop seen acc rest
      else loop (value :: seen) (value :: acc) rest
  in
  loop [] [] values
;;

let summarize_blocks (content : Types.content_block list) =
  let shape =
    List.fold_left
      (fun shape -> function
         | Types.Text text ->
           { (add_kind "text" shape) with
             text_blocks = shape.text_blocks + 1
           ; text_chars = shape.text_chars + String.length (String.trim text)
           }
         | Types.Thinking { content; _ } ->
           { (add_kind "thinking" shape) with
             thinking_blocks = shape.thinking_blocks + 1
           ; thinking_chars = shape.thinking_chars + String.length content
           }
         | Types.ReasoningDetails { reasoning_content; details } ->
           { (add_kind "reasoning_details" shape) with
             thinking_blocks = shape.thinking_blocks + 1
           ; thinking_chars =
               shape.thinking_chars
               + String.length (Types.reasoning_details_text ~reasoning_content ~details)
           }
         | Types.RedactedThinking _ ->
           { (add_kind "redacted_thinking" shape) with
             redacted_thinking_blocks = shape.redacted_thinking_blocks + 1
           }
         | Types.ToolUse _ ->
           { (add_kind "tool_use" shape) with tool_use_count = shape.tool_use_count + 1 }
         | Types.ToolResult _ ->
           { (add_kind "tool_result" shape) with
             tool_result_count = shape.tool_result_count + 1
           }
         | Types.Image _ ->
           { (add_kind "image" shape) with image_count = shape.image_count + 1 }
         | Types.Document _ ->
           { (add_kind "document" shape) with document_count = shape.document_count + 1 }
         | Types.Audio _ ->
           { (add_kind "audio" shape) with audio_count = shape.audio_count + 1 })
      empty
      content
  in
  { shape with content_kinds = List.rev shape.content_kinds |> dedupe_keep_order }
;;

let summarize (response : Types.api_response) = summarize_blocks response.content

let has_deliverable_content shape =
  shape.text_chars > 0
  || shape.tool_use_count > 0
  || shape.image_count > 0
  || shape.document_count > 0
  || shape.audio_count > 0
;;

let content_shape (response : Types.api_response) shape =
  match response.content with
  | [] -> Empty
  | _
    when shape.image_count + shape.document_count + shape.audio_count > 0
         && shape.text_chars = 0
         && shape.tool_use_count = 0
         && shape.tool_result_count = 0
         && shape.thinking_blocks = 0
         && shape.redacted_thinking_blocks = 0 -> Media_only
  | _ when has_deliverable_content shape -> Has_deliverable_content
  | _
    when shape.thinking_blocks + shape.redacted_thinking_blocks > 0
         && shape.text_chars = 0
         && shape.tool_use_count = 0
         && shape.tool_result_count = 0
         && shape.image_count = 0
         && shape.document_count = 0
         && shape.audio_count = 0 -> Thinking_only
  | _
    when shape.text_blocks > 0
         && shape.text_chars = 0
         && shape.thinking_blocks = 0
         && shape.redacted_thinking_blocks = 0
         && shape.tool_use_count = 0
         && shape.tool_result_count = 0
         && shape.image_count = 0
         && shape.document_count = 0
         && shape.audio_count = 0 -> Blank_text_only
  | _
    when shape.tool_result_count > 0
         && shape.text_chars = 0
         && shape.tool_use_count = 0
         && shape.thinking_blocks = 0
         && shape.redacted_thinking_blocks = 0
         && shape.image_count = 0
         && shape.document_count = 0
         && shape.audio_count = 0 -> Tool_result_only
  | _ -> Mixed_without_deliverable_content
;;

let content_shape_to_string = function
  | Empty -> "empty"
  | Thinking_only -> "thinking_only"
  | Blank_text_only -> "blank_text_only"
  | Tool_result_only -> "tool_result_only"
  | Media_only -> "media_only"
  | Mixed_without_deliverable_content -> "mixed_without_deliverable_content"
  | Has_deliverable_content -> "has_deliverable_content"
;;

let ended_without_deliverable_content response =
  let shape = summarize response in
  response.Types.stop_reason = Types.EndTurn && not (has_deliverable_content shape)
;;

let stop_reason_diagnostic_string = function
  | Types.Unknown raw -> Printf.sprintf "unknown(%S)" raw
  | stop_reason -> Types.stop_reason_to_string stop_reason
;;

let diagnostic_summary response =
  let shape = summarize response in
  let content_kinds =
    match shape.content_kinds with
    | [] -> "none"
    | kinds -> String.concat "," kinds
  in
  Printf.sprintf
    "shape=%s stop_reason=%s text_chars=%d content_blocks=%d content_kinds=[%s] \
     tool_use_count=%d tool_result_count=%d thinking_blocks=%d thinking_chars=%d \
     redacted_thinking_blocks=%d image_count=%d document_count=%d audio_count=%d"
    (content_shape_to_string (content_shape response shape))
    (stop_reason_diagnostic_string response.stop_reason)
    shape.text_chars
    (List.length response.content)
    content_kinds
    shape.tool_use_count
    shape.tool_result_count
    shape.thinking_blocks
    shape.thinking_chars
    shape.redacted_thinking_blocks
    shape.image_count
    shape.document_count
    shape.audio_count
;;
