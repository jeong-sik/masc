(** Explicit workspace-wide human confirmation of one immutable report revision.
    Fetching, listing and rendering never construct confirmation records. *)
type state = Checked | Unchecked
type target = private { id : string; revision : int; body_sha256 : string }
type request = private
  { target : target; state : state; expected_change_id : string option }
type t = private
  { target : target; state : state; change_id : string
  ; changed_by : string; changed_at : string }

val request_of_json : Yojson.Safe.t -> (request, string) result
val of_json : Yojson.Safe.t -> (t, string) result
val to_json : t -> Yojson.Safe.t
val create : actor:string -> at:string -> change_id:string -> request ->
  (t, string) result
(** Actor and timestamp come from the authenticated server boundary. Each write,
    including unchecking, gets a fresh opaque change ID to prevent stale writes. *)
val same_target : target -> target -> bool
