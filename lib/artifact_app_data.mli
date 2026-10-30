(** Personal application inputs for one immutable published HTML revision.
    Actors come from the authenticated caller, never from an input payload. *)
type target = { artifact_id : string; revision : int }
type request = private
  { target : target; id : string; expected_version : int; data : Yojson.Safe.t }
type receipt = private
  { id : string; expected_version : int; data_sha256 : string; at : string }
type t = private
  { target : target; actor : string; version : int; data : Yojson.Safe.t
  ; receipts : receipt list }
type error = Invalid of string | Conflict | Request_collision

val valid_target : target -> (unit, string) result
val target_to_json : target -> Yojson.Safe.t
val request_of_json : Yojson.Safe.t -> (request, string) result
val empty : target:target -> actor:string -> (t, string) result
val apply : t -> at:string -> request -> (t, error) result
(** A known request returns the current state without another write, even after
    later requests. Reusing its ID for different inputs is a conflict. *)
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
