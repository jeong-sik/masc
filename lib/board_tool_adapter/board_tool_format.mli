(** Formatting and JSON-boundary helpers for the board MCP adapter. *)

open Masc_board_handlers

type sort_order = Board_dispatch.sort_order =
  | Hot
  | Trending
  | Recent
  | Updated
  | Discussed

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
val error_of_board_error : tool_name:string -> start_time:Tool_timing.started -> Board.board_error -> Tool_result.result
val error_of_post_publication_failure :
  tool_name:string ->
  start_time:Tool_timing.started ->
  Board.Post_publication_failure.t ->
  Tool_result.result
(** Project producer-owned effect evidence without deriving it from the error
    class or message. Proven commits carry [data.committed_post_id]. *)

val with_unresolved : Yojson.Safe.t -> string list -> Yojson.Safe.t
(** [with_unresolved written names] adds the [unresolved] list to the JSON of a
    post or comment a write just returned: the names in the text that look
    like addresses but no Keeper declares, as the author wrote them. *)

val post_of_write_data : Yojson.Safe.t -> Board.post option
(** The post that {!with_unresolved} wrapped, or [None] when the data is not a
    post.  Use it instead of {!Board.post_of_yojson} on a write response: the
    post decoder rejects the extra [unresolved] field. *)
val visibility_of_string : string -> Board.visibility option
val format_post : ?viewer_vote:Board.vote_direction -> replies:int -> Board.post -> string
(** [viewer_vote] is the reading agent's own vote on the post, rendered as a
    "내 투표" marker beside the tallies so the next turn's read carries what
    the vote tool's "Already voted" answer only said once (task-839).
    [replies] is the count the caller read: a thread read passes the length of
    the comment list it is paging, so the header and the page agree. *)

val format_post_compact : replies:int -> Board.post -> string

(** One search hit in the two shapes a result can carry it: the whole post, and the
    one line [format_post_compact] gives it. *)
type search_hit =
  { full : string
  ; one_line : string
  }

val join_search_hits : max_bytes:int -> header:string -> search_hit list -> string
(** [join_search_hits ~max_bytes ~header hits] is [header] followed by the first [k]
    hits in full, separated by a rule line, then a line saying how many were
    shortened, then the one-line shape of the remaining hits, one per line. [k] is the
    largest count for which the text is at most [max_bytes] bytes, and [0] when even
    that is over, so the rows alone may pass [max_bytes]: a result of rows is what
    a compact search returns. When every hit fits in full there is no note and the
    text is [header] followed by every full hit. The order of [hits] is kept, so the
    full ones are the earlier hits. *)

val format_comment_tree
  :  ?viewer_vote_of:(Board.Comment_id.t -> Board.vote_direction option)
  -> Board.comment list
  -> string list
(** One line per comment, every comment exactly once, replies under their
    parent. Indentation stops growing past a fixed depth; deeper replies are
    still drawn. A reply the indentation cannot place — deeper than that
    depth, or whose parent is not in [comments] — names its parent's id.
    [viewer_vote_of] answers, per comment, the reading agent's own
    vote; the default answers [None] for every comment and renders no
    marker. *)
val sources_footer : Yojson.Safe.t list -> string
val parse_sort_order : string -> (sort_order, string) Result.t
val judgment_arg : Yojson.Safe.t -> Yojson.Safe.t option
val normalize_board_post_meta :
  ?attachments:Board_tool_attachment.t list -> Yojson.Safe.t -> Yojson.Safe.t option
(** [attachments] contains entries parsed and validated by the post handler.
    Raw [meta.attachments] is never copied into the persisted carrier. *)
val source_entries_arg : Yojson.Safe.t -> Yojson.Safe.t list option
val merge_sources_into_meta : Yojson.Safe.t option -> Yojson.Safe.t list -> Yojson.Safe.t option
val string_field : (string * Yojson.Safe.t) list -> string -> string -> string
val float_field : (string * Yojson.Safe.t) list -> string -> float -> float
val string_list_field : (string * Yojson.Safe.t) list -> string -> string list
val string_opt_arg : Yojson.Safe.t -> string -> string option
val string_list_arg : Yojson.Safe.t -> string -> string list
val object_list_arg : Yojson.Safe.t -> string -> (string * Yojson.Safe.t) list list
val provenance_arg : Yojson.Safe.t -> (Yojson.Safe.t, string) result
val with_yojson_boundary : tool_name:string -> start_time:Tool_timing.started -> (unit -> Tool_result.result) -> Tool_result.result
