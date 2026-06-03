(** Status-rollup classification and target search for board automation posts. *)

include module type of struct
  include Board_types
end

val status_rollup_window_sec : float
val max_status_rollup_body_length : int

val status_rollup_task_id :
  title:string -> body:string -> meta_json:Yojson.Safe.t option -> string option

val is_status_rollup_candidate :
  post_kind:post_kind ->
  title:string ->
  body:string ->
  meta_json:Yojson.Safe.t option ->
  bool

val find_status_rollup_target_unlocked :
  store ->
  author_id:Agent_id.t ->
  hearth:string option ->
  visibility:visibility ->
  task_id:string ->
  now:float ->
  post option
