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

module Terminal_size_cache : sig
  type t

  val create : fallback:int * int -> t
  val invalidate : t -> unit
  val get : t -> probe:(unit -> (int * int) option) -> int * int
end
