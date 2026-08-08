(** Canonical tool projections (RFC-OAS-024, WP8 Increments 1-2).

    Increment 1 shipped the {e result} projection. Increment 2 adds the call
    projection plus structural reasoning-adjacency metadata for consumers that
    need to render or execute interleaved Thinking -> ToolUse responses without
    receiving raw provider reasoning payloads.

    Pure, total projections over [Types.content_block]. This is {b not} a second
    in-memory SSOT: [content_block] remains the canonical representation and the
    projected value is derived from it at the provider boundary. Depends only on
    provider-boundary types and references no execution, policy, or coordinator
    concept (RFC-OAS-024 §1). Reasoning adjacency is purely structural: only
    contiguous reasoning blocks immediately before a ToolUse are linked.

    Lane A (Keystone K): no [id_origin]. [call_id] is the block's id verbatim,
    already the native wire id or an opaque OAS allocation depending on the
    provider parse path; ids are neither reallocated nor reclassified here. *)

type provider_reasoning_kind =
  | Visible_thinking
  | Redacted_thinking

type provider_reasoning_block =
  { order_index : int
  ; kind : provider_reasoning_kind
  ; signature : string option
  }

type adjacent_reasoning =
  | No_adjacent_reasoning
  | Adjacent_reasoning of provider_reasoning_block list

type provider_tool_call =
  { call_id : string
  ; name : string
  ; input : Yojson.Safe.t
  ; order_index : int
  ; provider_kind : Provider_kind.t option
  ; adjacent_reasoning : adjacent_reasoning
  }

type provider_tool_result =
  { call_id : string (** Correlates with the originating tool call. *)
  ; content : string (** Canonical string payload (mirror of [ToolResult.content]). *)
  ; content_blocks : Types.content_block list option
    (** Mirror of [ToolResult.content_blocks] (multi-block result). *)
  ; structured_content : Yojson.Safe.t option
    (** Projection of [ToolResult.json] (WP4 parsed payload), verbatim — not a
        fresh parse, and not the request-level structured-output contract
        (RFC-OAS-024 D7). *)
  ; outcome : Types.tool_result_outcome
  }

let provider_kind_of_response (response : Types.api_response) =
  match response.telemetry with
  | Some telemetry -> telemetry.provider_kind
  | None -> None
;;

let reasoning_of_block ~order_index (block : Types.content_block) =
  match block with
  | Types.Thinking { signature; _ } ->
    Some { order_index; kind = Visible_thinking; signature }
  | Types.ReasoningDetails { reasoning_content; details } ->
    let content = Types.reasoning_details_text ~reasoning_content ~details in
    if String.trim content = ""
    then None
    else Some { order_index; kind = Visible_thinking; signature = None }
  | Types.RedactedThinking _ ->
    Some { order_index; kind = Redacted_thinking; signature = None }
  | Types.Text _
  | Types.ToolUse _
  | Types.ToolResult _
  | Types.Image _
  | Types.Document _
  | Types.Audio _ -> None
;;

type scan_state =
  { block_index : int
  ; tool_index : int
  ; provider_kind : Provider_kind.t option
  ; pending_reasoning_rev : provider_reasoning_block list
  ; tool_calls_rev : provider_tool_call list
  }

let adjacent_reasoning_of_pending = function
  | [] -> No_adjacent_reasoning
  | pending_reasoning_rev -> Adjacent_reasoning (List.rev pending_reasoning_rev)
;;

let tool_call_of_block
      ?(order_index = 0)
      ?provider_kind
      ?(adjacent_reasoning = No_adjacent_reasoning)
      (block : Types.content_block)
  : provider_tool_call option
  =
  match block with
  | Types.ToolUse { id; name; input } ->
    Some { call_id = id; name; input; order_index; provider_kind; adjacent_reasoning }
  | Types.Text _
  | Types.Thinking _
  | Types.ReasoningDetails _
  | Types.RedactedThinking _
  | Types.ToolResult _
  | Types.Image _
  | Types.Document _
  | Types.Audio _ -> None
;;

let scan_tool_call state (block : Types.content_block) =
  let provider_kind = state.provider_kind in
  let adjacent_reasoning = adjacent_reasoning_of_pending state.pending_reasoning_rev in
  match
    tool_call_of_block
      ~order_index:state.tool_index
      ?provider_kind
      ~adjacent_reasoning
      block
  with
  | Some tool_call ->
    { state with
      block_index = state.block_index + 1
    ; tool_index = state.tool_index + 1
    ; pending_reasoning_rev = []
    ; tool_calls_rev = tool_call :: state.tool_calls_rev
    }
  | None ->
    (match block with
     | Types.Thinking _ | Types.ReasoningDetails _ | Types.RedactedThinking _ ->
       let pending_reasoning_rev =
         match reasoning_of_block ~order_index:state.block_index block with
         | Some reasoning -> reasoning :: state.pending_reasoning_rev
         | None -> state.pending_reasoning_rev
       in
       { state with block_index = state.block_index + 1; pending_reasoning_rev }
     | Types.Text _
     | Types.ToolUse _
     | Types.ToolResult _
     | Types.Image _
     | Types.Document _
     | Types.Audio _ ->
       { state with block_index = state.block_index + 1; pending_reasoning_rev = [] })
;;

let tool_calls_of_response (response : Types.api_response) : provider_tool_call list =
  let initial =
    { block_index = 0
    ; tool_index = 0
    ; provider_kind = provider_kind_of_response response
    ; pending_reasoning_rev = []
    ; tool_calls_rev = []
    }
  in
  let final_state = List.fold_left scan_tool_call initial response.content in
  List.rev final_state.tool_calls_rev
;;

let tool_result_of_block (block : Types.content_block) : provider_tool_result option =
  match block with
  | Types.ToolResult { tool_use_id; content; outcome; json; content_blocks; _ } ->
    Some
      { call_id = tool_use_id
      ; content
      ; content_blocks
      ; structured_content = json
      ; outcome
      }
  | Types.Text _
  | Types.Thinking _
  | Types.ReasoningDetails _
  | Types.RedactedThinking _
  | Types.ToolUse _
  | Types.Image _
  | Types.Document _
  | Types.Audio _ -> None
;;
