(** Current-only typed admission for dashboard runtime-parameter writes. *)

type set_request
type clear_request

type error

val decode_set : string -> (set_request, error) result
(** Parse one complete set request. [param_key] and [value] must each occur
    exactly once; the value may be any JSON value accepted by the registered
    runtime parameter. *)

val decode_clear : string -> (clear_request, error) result
(** Parse one complete clear request. [param_key] must occur exactly once. *)

val set_param_key : set_request -> string
val set_value : set_request -> Yojson.Safe.t
val clear_param_key : clear_request -> string
val error_message : error -> string
