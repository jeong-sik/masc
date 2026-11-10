type refusal = Capacity_exhausted | Request_closed
exception Unbound_request

type t = { capacity : int; mutable used : int; mutex : Stdlib.Mutex.t }
type lease_state = Reserved | Released
type request = { budget : t; mutable closed : bool; leases : (int,lease) Hashtbl.t;
  mutable next_id : int }
and lease = { owner : request; id : int; bytes : int; mutable state : lease_state }

let create ~max_pending_bytes =
  if max_pending_bytes < 1 then invalid_arg "H2 pending byte capacity must be positive";
  {capacity=max_pending_bytes; used=0; mutex=Stdlib.Mutex.create ()}

let locked t f =
  Stdlib.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock t.mutex) f

let pending_bytes t = locked t (fun () -> t.used)

let release_locked lease =
  match lease.state with
  | Released -> ()
  | Reserved ->
    lease.state <- Released;
    lease.owner.budget.used <- lease.owner.budget.used - lease.bytes;
    Hashtbl.remove lease.owner.leases lease.id

let release lease = locked lease.owner.budget (fun () -> release_locked lease)

let reserve_locked owner bytes =
  if owner.closed then Error Request_closed
  else if bytes > owner.budget.capacity - owner.budget.used then Error Capacity_exhausted
  else (
    let id=owner.next_id in owner.next_id <- id+1;
    let lease = {owner;id;bytes;state=Reserved} in
    owner.budget.used <- owner.budget.used + bytes;
    Hashtbl.add owner.leases id lease;
    Ok lease)

let reserve owner ~bytes =
  if bytes < 0 then invalid_arg "negative H2 response reservation";
  locked owner.budget (fun () -> reserve_locked owner bytes)

let current_key : request Eio.Fiber.key = Eio.Fiber.create_key ()
let current () = Eio.Fiber.get current_key
let current_exn () = match Eio.Fiber.get current_key with
  | Some request -> request | None -> raise Unbound_request
let with_current request f = Eio.Fiber.with_binding current_key request f

let with_request budget ~sw f =
  let request = {budget;closed=false;leases=Hashtbl.create 4;next_id=0} in
  Eio.Switch.on_release sw (fun () -> locked budget (fun () ->
    request.closed <- true;
    Hashtbl.iter (fun _ lease -> match lease.state with
      | Released -> ()
      | Reserved -> lease.state <- Released; budget.used <- budget.used - lease.bytes)
      request.leases;
    Hashtbl.clear request.leases));
  with_current request f

let write_reserved lease writer payload =
  if String.length payload <> lease.bytes then (
    release lease;
    invalid_arg "H2 response reservation does not match payload");
  try
    H2.Body.Writer.write_string writer payload;
    H2.Body.Writer.flush writer (function `Written | `Closed -> release lease)
  with exn -> release lease; raise exn
