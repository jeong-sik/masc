(** Formatting and JSON-boundary helpers for the board MCP adapter. *)

open Masc_board_handlers

type truncation_signal =
  | Odd_fence
  | Odd_inline_tick
  | Unfinished_link
  | Unfinished_image
  | Odd_double_asterisk

type sort_order = Board_dispatch.sort_order =
  | Hot
  | Trending
  | Recent
  | Updated
  | Discussed

val raw_agent_name_meta_key : field:string -> string
val author_raw_agent_name_meta_key : string
val format_timestamp_relative : float -> string
val board_error_to_string : Board.board_error -> string
val board_error_failure_class : Board.board_error -> Tool_result.tool_failure_class
val error_of_board_error : tool_name:string -> start_time:float -> Board.board_error -> Tool_result.result
val visibility_of_string : string -> Board.visibility option
val format_post : Board.post -> string
val format_post_compact : Board.post -> string
val format_comment_tree : ?max_depth:int -> Board.comment list -> string list
val sources_footer : Yojson.Safe.t list -> string
val truncation_signal_to_string : truncation_signal -> string
val detect_truncated_markdown_with_reason : string -> truncation_signal option
val parse_sort_order : string -> (sort_order, string) Result.t
val judgment_arg : Yojson.Safe.t -> Yojson.Safe.t option
val normalize_board_post_meta : Yojson.Safe.t -> Yojson.Safe.t option
val source_entries_arg : Yojson.Safe.t -> Yojson.Safe.t list option
val merge_sources_into_meta : Yojson.Safe.t option -> Yojson.Safe.t list -> Yojson.Safe.t option
val string_field : (string * Yojson.Safe.t) list -> string -> string -> string
val float_field : (string * Yojson.Safe.t) list -> string -> float -> float
val string_list_field : (string * Yojson.Safe.t) list -> string -> string list
val string_opt_arg : Yojson.Safe.t -> string -> string option
val string_list_arg : Yojson.Safe.t -> string -> string list
val object_list_arg : Yojson.Safe.t -> string -> (string * Yojson.Safe.t) list list
val provenance_arg : Yojson.Safe.t -> (Yojson.Safe.t, string) result
val with_yojson_boundary : tool_name:string -> start_time:float -> (unit -> Tool_result.result) -> Tool_result.result
