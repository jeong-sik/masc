(* Tool-use / tool-result block text renderers for the keeper context.

   These build the *text-block fallback* shown when a structured
   ToolUse/ToolResult message must be flattened into plain text - for
   downgrade fallbacks (orphan repair) and for verifier-facing
   serializations.

   Cap-aware: ToolResult JSON over [max_chars] collapses to a stub so
   one orphan-repair pass cannot inflate one Text block to multi-MB
   and trigger the same escape-depth blow-up that motivated the
   artifact-store work (see [tool_blob_store] + tool-output-washing
   series).

   Extracted from [Keeper_context_core] (godfile decomp). Pure mapping
   over the input - the per-result cap is injected by the caller so
   this module has no dependency on parent constants. *)

let tool_result_text_of_block
      ~(tool_use_id : string)
      ~(content : string)
      ~(json : Yojson.Safe.t option)
      ~(max_chars : int)
  : string
  =
  let content = Inference_utils.sanitize_text_utf8 (String.trim content) in
  if content <> ""
  then content
  else (
    match json with
    | Some value ->
      let serialized = Yojson.Safe.to_string value in
      let len = String.length serialized in
      if len <= max_chars
      then serialized
      else Printf.sprintf "[tool:json id:%s bytes:%d elided]" tool_use_id len
    | None -> Printf.sprintf "[tool result %s]" tool_use_id)
;;

let tool_use_text_of_block
      ~(tool_use_id : string)
      ~(tool_name : string)
      ~(input : Yojson.Safe.t)
  : string
  =
  let tool_name = Inference_utils.sanitize_text_utf8 (String.trim tool_name) in
  let tool_use_id = Inference_utils.sanitize_text_utf8 (String.trim tool_use_id) in
  let tool_name = if tool_name = "" then "unknown_tool" else tool_name in
  let input_json =
    Yojson.Safe.to_string input |> Inference_utils.sanitize_text_utf8
  in
  Printf.sprintf "[tool use %s %s input=%s]" tool_name tool_use_id input_json
;;
