type raw
type t = { raw : raw; lock : Mutex.t; mutable closed : bool }
type error = No_owner | Owner_changed | Unsupported | Unavailable | Closed
external capture_raw : Unix.file_descr -> int * raw = "masc_owner_identity_capture"
external terminate_raw : raw -> int = "masc_owner_identity_terminate"
external close_raw : raw -> unit = "masc_owner_identity_close"
let error = function 1 -> No_owner | 2 -> Owner_changed | 3 -> Unsupported | _ -> Unavailable
let capture ~lease_fd =
  match capture_raw lease_fd with
  | 0, raw -> Ok {raw;lock=Mutex.create ();closed=false}
  | code, _ -> Error (error code)
let request_termination owner = Mutex.protect owner.lock (fun () ->
  if owner.closed then Error Closed else
    match terminate_raw owner.raw with 0 -> Ok () | code -> Error (error code))
let close owner = Mutex.protect owner.lock (fun () ->
  if not owner.closed then (close_raw owner.raw; owner.closed <- true))
