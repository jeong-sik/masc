(** Board tool list cache helpers. *)

type cached_payload =
  (string, Tool_result.tool_failure_class * string) result

type board_list_cache =
  { mutable key : string option
  ; mutable value : cached_payload option
  ; mutable expires_at : float
  }

val board_list_cache : board_list_cache
val board_list_cache_ttl_s : unit -> float
val invalidate_board_list_cache : unit -> unit

val cached_board_list :
  key:string ->
  tool_name:string ->
  start_time:float ->
  (unit -> Tool_result.result) ->
  Tool_result.result

val board_list_cache_key : Yojson.Safe.t -> string
