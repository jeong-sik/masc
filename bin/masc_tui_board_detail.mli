type request
type 'a t

type 'a view =
  | Absent
  | Loading
  | Ready of 'a
  | Failed of string

type 'a start_result =
  | Already_loading
  | Started of 'a t * request

val initial : 'a t
val start : 'a t -> post_id:string -> 'a start_result
val clear : 'a t -> 'a t
val request_post_id : request -> string
val same_request : request -> request -> bool
val is_current : 'a t -> request -> bool
val complete : 'a t -> request -> ('a, string) result -> 'a t
val view_for : 'a t -> post_id:string -> 'a view
