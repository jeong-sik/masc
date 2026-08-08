(** Canonical tool projections (RFC-OAS-024, WP8 — Increments 1-2).

    Typed read-projections of the tool-call/tool-result dimensions of
    {!Types.content_block}. These are {b not} a second in-memory SSOT:
    [content_block] remains the canonical representation and every value here is
    derived from it at the provider boundary.

    Scope (RFC-OAS-024 §7): Increment 1 shipped [tool_result_of_block].
    Increment 2 adds [provider_tool_call] and [tool_calls_of_response] as a
    structural projection for downstream renderers/executors. Reasoning metadata
    is only linked when it is immediately adjacent in the canonical content
    order; this module never infers semantic ownership across Text/media/result
    boundaries and never exposes raw provider reasoning payloads.

    Boundary (RFC-OAS-024 §1): OAS-owned provider canonicalization only. Depends
    solely on provider-boundary types and references no execution, policy, or
    coordinator concept. The downstream consumer is named only as an unnamed
    external role.

    @stability Evolving *)

(** Reasoning block kind preserved from the canonical content block. *)
type provider_reasoning_kind =
  | Visible_thinking
  | Redacted_thinking

(** Public metadata for a provider reasoning block observed in a response.

    [order_index] is the zero-based position in {!Types.api_response.content}.
    Raw provider reasoning payloads are intentionally not exposed by this
    renderer/executor projection; provider replay paths must use
    {!Types.content_block} directly. [signature] is present only for signed
    visible thinking blocks. *)
type provider_reasoning_block =
  { order_index : int
  ; kind : provider_reasoning_kind
  ; signature : string option
  }

(** Reasoning blocks immediately adjacent to a tool call.

    [Adjacent_reasoning blocks] means the blocks are contiguous immediately
    before the [ToolUse] in canonical content order. It does {b not} mean OAS
    inferred provider intent. *)
type adjacent_reasoning =
  | No_adjacent_reasoning
  | Adjacent_reasoning of provider_reasoning_block list

(** A single tool call projected at the provider boundary.

    [call_id], [name], and [input] are mirrors of [ToolUse]. [order_index] is
    the zero-based position in the ToolUse-only subsequence, so reasoning/text
    interleaving does not make downstream call ordering depend on non-tool
    blocks. [provider_kind] is copied from response telemetry when present; it
    is never guessed. *)
type provider_tool_call =
  { call_id : string
  ; name : string
  ; input : Yojson.Safe.t
  ; order_index : int
  ; provider_kind : Provider_kind.t option
  ; adjacent_reasoning : adjacent_reasoning
  }

(** Project a single content block into a tool call. Returns [None] for any
    block that is not a [ToolUse]. The optional structural fields are caller
    supplied; this function never infers provider kind or reasoning adjacency
    outside the supplied block context. Defaults are [order_index = 0],
    [provider_kind = None], and [No_adjacent_reasoning]. Pure and total. *)
val tool_call_of_block
  :  ?order_index:int
  -> ?provider_kind:Provider_kind.t
  -> ?adjacent_reasoning:adjacent_reasoning
  -> Types.content_block
  -> provider_tool_call option

(** Project tool calls from a response while preserving response order.

    The projection is pure and total. Non-[ToolUse] blocks are ignored as tool
    calls but still affect adjacency: any non-reasoning block clears pending
    adjacent reasoning. [provider_tool_call.order_index] counts ToolUse blocks
    only; [provider_reasoning_block.order_index] remains the content-block
    position of the reasoning block. *)
val tool_calls_of_response : Types.api_response -> provider_tool_call list

(** A single tool result projected at the provider boundary. Lane A: [call_id]
    is the originating tool-use id verbatim (native or synthesized upstream),
    never re-synthesized here. *)
type provider_tool_result =
  { call_id : string (** Correlates with {!provider_tool_call.call_id} (Increment 2). *)
  ; content : string (** Canonical string payload (mirror of [ToolResult.content]). *)
  ; content_blocks : Types.content_block list option
    (** Mirror of [ToolResult.content_blocks] (multi-block result). *)
  ; structured_content : Yojson.Safe.t option
    (** Projection of [ToolResult.json] (WP4 parsed payload), verbatim. Not a
          fresh parse, and {b not} the request-level structured-output contract
          (RFC-OAS-024 D7). *)
  ; outcome : Types.tool_result_outcome
  }

(** Project a single content block into a tool result. Returns [None] for any
    block that is not a [ToolResult]. Pure and total. *)
val tool_result_of_block : Types.content_block -> provider_tool_result option
