type decision =
  | Idle
  | Wait_until of int64
  | Render

type request =
  | Input
  | Background
  | Force

type t

val create : min_interval_ns:int64 -> unit -> t
val request : t -> request -> unit
val take : t -> now_ns:int64 -> decision
val input_timeout_seconds : t -> now_ns:int64 -> maximum:float -> float
val nonnegative_width : int -> int
val keeper_context_bar_width : inner_width:int -> int
val normalize_keeper_detail_scroll :
  line_count:int -> content_height:int -> int -> int

module Input_wait : sig
  type 'a poll_result =
    | Ready of 'a
    | Timed_out
    | Interrupted

  val await :
    now_ns:(unit -> int64) ->
    timeout_ns:int64 ->
    poll:(float -> 'a poll_result) ->
    'a option
end

module Input_shortcut : sig
  val is_quit : message_mode:bool -> string -> bool
  val opens_keepers : message_mode:bool -> string -> bool
end

module Viewport : sig
  val minimum_fixed_chrome_rows : int
  val requires_compact_frame : rows:int -> bool
end

type overview_allocation = {
  attention_rows : int;
  task_error_rows : int;
  task_rows : int;
}

val allocate_overview :
  terminal_rows:int ->
  has_cluster:bool ->
  attention_count:int ->
  event_count:int ->
  task_count:int ->
  has_task_error:bool ->
  overview_allocation

type board_read_allocation = {
  body_rows : int;
  comment_rows : int;
}

val allocate_board_read :
  terminal_rows:int ->
  body_line_count:int ->
  comment_count:int ->
  board_read_allocation

type board_read_scroll = {
  normalized_scroll : int;
  body_offset : int;
  comment_offset : int;
}

val project_board_read_scroll :
  body_line_count:int ->
  body_rows:int ->
  comment_count:int ->
  comment_rows:int ->
  int ->
  board_read_scroll

module Terminal_size_cache : sig
  type t

  val create : fallback:int * int -> t
  val invalidate : t -> unit
  val get : t -> probe:(unit -> (int * int) option) -> int * int
end
