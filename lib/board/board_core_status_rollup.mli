(** Status-rollup classification and target search for board automation posts. *)

include module type of struct
  include Board_types
end

val status_rollup_window_sec : float
val max_status_rollup_body_length : int

val status_rollup_task_id :
  ?typed_task_id:string -> title:string -> body:string -> meta_json:Yojson.Safe.t option -> unit -> string option

val is_status_rollup_candidate :
  post_kind:post_kind ->
  title:string ->
  body:string ->
  meta_json:Yojson.Safe.t option ->
  ?task_id:string ->
  unit ->
  bool

val find_status_rollup_target_unlocked :
  store ->
  author_id:Agent_id.t ->
  hearth:string option ->
  visibility:visibility ->
  task_id:string ->
  now:float ->
  post option

(** Goal-based rollup — stub for future use. *)
val status_rollup_goal_id :
  ?typed_goal_id:string -> title:string -> body:string -> meta_json:Yojson.Safe.t option -> unit -> string option
