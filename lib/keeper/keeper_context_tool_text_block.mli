(** Tool-use / tool-result block text renderers. *)

(** Build the text fallback for a ToolResult.  When [content] is empty,
    serialize [json] if it fits within [max_chars]; otherwise emit
    [\[tool:json id:_ bytes:_ elided\]]. *)
val tool_result_text_of_block
  :  tool_use_id:string
  -> content:string
  -> json:Yojson.Safe.t option
  -> max_chars:int
  -> string
