type state =
  | Awaiting_validator
  | Active of (unit -> (unit, string) result)
  | Closed

type token = state Atomic.t

let run f =
  let token = Atomic.make Awaiting_validator in
  let invalidate () = Atomic.set token Closed in
  match f token with
  | value ->
    invalidate ();
    value
  | exception exn ->
    invalidate ();
    raise exn
;;

let rec install token validator =
  match Atomic.get token with
  | Closed -> Error "keeper turn dispatch authority is no longer active"
  | Active _ -> Error "keeper turn dispatch authority is already installed"
  | Awaiting_validator ->
    if Atomic.compare_and_set token Awaiting_validator (Active validator)
    then Ok ()
    else install token validator
;;

let validate token =
  match Atomic.get token with
  | Closed -> Error "keeper turn dispatch authority is no longer active"
  | Awaiting_validator -> Error "keeper turn dispatch authority is not installed"
  | Active validator -> validator ()
;;
