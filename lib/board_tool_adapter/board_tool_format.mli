(** Formatting and JSON-boundary helpers for the board MCP adapter. *)

open Masc_board_handlers

type sort_order = Board_dispatch.sort_order =
  | Hot
  | Trending
  | Recent
  | Updated
  | Discussed

val raw_agent_name_meta_key : field:string -> string
val author_raw_agent_name_meta_key : string
val format_timestamp_absolute : float -> string
(** ISO8601 UTC rendering of the given instant. A function of its argument
    alone, so an unchanged board renders to unchanged bytes and a keeper does
    not read a drifting minute counter as a board change. Relative ("Nm ago")
    rendering belongs to the human-facing [Dashboard_labels] / [Tempo]
    renderers, which have a human reader and no such contract. *)

val format_expiry : float -> string
(** ["permanent"] for the [0.0] no-expiry sentinel, otherwise the ISO8601 UTC
    expiry instant. Reports the instant, not the remaining duration, so the
    clock is not a hidden input. *)
val board_error_to_string : Board.board_error -> string
val board_error_failure_class : Board.board_error -> Tool_result.tool_failure_class
val error_of_board_error : tool_name:string -> start_time:float -> Board.board_error -> Tool_result.result
val visibility_of_string : string -> Board.visibility option
val format_post : ?viewer_vote:Board.vote_direction -> Board.post -> string
(** [viewer_vote] is the reading agent's own vote on the post, rendered as a
    "내 투표" marker beside the tallies so the next turn's read carries what
    the vote tool's "Already voted" answer only said once (task-839). *)

val format_post_compact : Board.post -> string

val format_comment_tree
  :  ?max_depth:int
  -> ?viewer_vote_of:(Board.Comment_id.t -> Board.vote_direction option)
  -> Board.comment list
  -> string list
(** [viewer_vote_of] answers, per comment, the reading agent's own vote; the
    default answers [None] for every comment and renders no marker. *)
val sources_footer : Yojson.Safe.t list -> string
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
