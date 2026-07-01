(** Backend mirror of the dashboard's [parseTextToChatBlocks].

    Turns assistant reply text into a list of rich chat blocks so the
    server can own the parsing and the dashboard can render server-provided
    blocks verbatim.

    Supported shapes:
    - Explicit server-provided dashboard blocks round-trip through the
      codec: p, h4, ul, callout, table, code, mermaid, svg, voice, attach,
      image, link, and fusion. Thinking (RFC-0302) carries assistant
      reasoning content (empty string for a signature-only [RedactedThinking]) so
      reload replays the trace; not produced by [parse_text_to_blocks].
    - Matched fenced code blocks become code blocks with escaped HTML and raw source.
    - Mermaid fenced code blocks become mermaid blocks with raw source.
    - Markdown images [![alt](url)] become image blocks.
    - Bare image URLs (png/jpg/gif/webp/svg) on their own line become image blocks.
    - Other standalone URLs become link blocks with a hostname-derived title.
    - Remaining text becomes escaped HTML text blocks. *)

type image_block = {
  src : string;
  cap : string option;
}

type link_block = {
  url : string;
  title : string;
  meta : string;
}

type text_block = { html : string }

type list_block = { items : string list }

type callout_block = {
  severity : string option;
  html : string;
}

type table_cell =
  | Cell_text of string
  | Cell_value of {
      v : string;
      num : bool option;
      muted : bool option;
    }

type table_block = {
  head : table_cell list;
  rows : table_cell list list;
}

type code_block = {
  cap : string option;
  html : string;
  source : string option;
}

type mermaid_block = {
  source : string;
  caption : string option;
}

type svg_block = {
  svg : string;
  cap : string option;
}

type voice_block = {
  secs : float option;
  wave : float list option;
  via : string option;
  size : string option;
  transcript : string option;
  src : string option;
}

type attach_block = {
  name : string;
  dims : string option;
  src : string option;
  svg : string option;
  ph : string option;
  via : string option;
  size : string option;
  data : string option;
  mime_type : string option;
  size_bytes : int option;
  kind : string option;
}

(** A reference from a keeper chat message to a fusion deliberation's board
    post (RFC-0252). Carries only ids — the dashboard lazy-fetches the board
    post by [board_post_id] and renders the panel answers + judge synthesis
    from its [meta_json]. Kept out of [content] so the keeper observation
    projection (which reads role/content only) is not polluted. *)
type fusion_block = {
  board_post_id : string;
  run_id : string;
}

type trace_tool_status =
  | Trace_tool_pending
  | Trace_tool_ok
  | Trace_tool_err

type trace_step =
  | Trace_think of {
      text : string;
      ts : string option;
      oas_block_index : int option;
    }
  | Trace_reason of {
      text : string;
      detail : string option;
      ts : string option;
    }
  | Trace_tool of {
      name : string;
      tool_call_id : string option;
      status : trace_tool_status option;
      dur : string option;
      args : Yojson.Safe.t option;
      result : Yojson.Safe.t option;
      ts : string option;
      oas_block_index : int option;
    }

type trace_block = { trace : trace_step list }

(** A block of keeper/assistant reasoning persisted so the dashboard can
    replay the thinking trace on reload (RFC-0302). [content] is the
    thinking/reasoning text (empty string for a signature-only [RedactedThinking]);
    [redacted] marks that case so the dashboard renders a placeholder rather
    than an empty card. Not produced by [parse_text_to_blocks] — text-only
    input — and kept out of [content] so the role/content observation
    projection is not polluted, mirroring [fusion_block]. *)
type thinking_block = {
  content : string;
  redacted : bool;
}

type chat_block =
  | Text of text_block
  | Heading of text_block
  | Unordered_list of list_block
  | Callout of callout_block
  | Table of table_block
  | Code of code_block
  | Mermaid of mermaid_block
  | Svg of svg_block
  | Voice of voice_block
  | Attach of attach_block
  | Image of image_block
  | Link of link_block
  | Fusion of fusion_block
  | Trace of trace_block
  | Thinking of thinking_block

type dropped_http_url_reason =
  | Missing_scheme
  | Unsupported_scheme of string
  | Invalid_url

val dropped_http_url_reason_to_string : dropped_http_url_reason -> string

val redacted_http_url_opt :
  ?on_drop:(dropped_http_url_reason -> unit) -> string -> string option

val parse_text_to_blocks : string -> chat_block list
val block_to_yojson : chat_block -> Yojson.Safe.t
val blocks_to_yojson : chat_block list -> Yojson.Safe.t
val blocks_of_yojson : Yojson.Safe.t -> chat_block list option
