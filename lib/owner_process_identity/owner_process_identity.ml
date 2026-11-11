type raw
type t = { raw : raw; pid : int; lock : Mutex.t; mutable closed : bool }
type error = No_owner | Owner_changed | Unsupported | Unavailable | Closed
type held_byte = { holder : int; byte : int }
external capture_raw : Unix.file_descr -> int * raw = "masc_owner_identity_capture"
external terminate_raw : raw -> int = "masc_owner_identity_terminate"
external close_raw : raw -> unit = "masc_owner_identity_close"
external pid_raw : raw -> int = "masc_owner_identity_pid"
external held_byte_raw : Unix.file_descr -> int * int * int = "masc_owner_identity_held_byte"
let error = function 1 -> No_owner | 2 -> Owner_changed | 3 -> Unsupported | _ -> Unavailable
let capture ~lease_fd =
  match capture_raw lease_fd with
  | 0, raw -> Ok {raw;pid=pid_raw raw;lock=Mutex.create ();closed=false}
  | code, _ -> Error (error code)
let pid owner = owner.pid
let held_byte fd =
  match held_byte_raw fd with
  | 0, holder, byte -> Ok (Some {holder;byte})
  | 1, _, _ -> Ok None
  | code, _, _ -> Error (error code)
let request_termination owner = Mutex.protect owner.lock (fun () ->
  if owner.closed then Error Closed else
    match terminate_raw owner.raw with 0 -> Ok () | code -> Error (error code))
let close owner = Mutex.protect owner.lock (fun () ->
  if not owner.closed then (close_raw owner.raw; owner.closed <- true))
