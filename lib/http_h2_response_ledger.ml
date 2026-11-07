type refusal = Capacity_exhausted | Request_closed
exception Unbound_request
exception Response_capacity_exhausted
exception Response_writer_closed

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

let write_and_flush writer payload =
  match reserve (current_exn ()) ~bytes:(String.length payload) with
  | Error Capacity_exhausted -> raise Response_capacity_exhausted
  | Error Request_closed -> raise Response_writer_closed
  | Ok lease ->
    let flushed, resolve = Eio.Promise.create () in
    (try
       let data = Bigstringaf.of_string payload ~off:0 ~len:(String.length payload) in
       H2.Body.Writer.schedule_bigstring writer data;
       H2.Body.Writer.flush writer (fun result -> release lease; Eio.Promise.resolve resolve result)
     with exn -> release lease; raise exn);
    match Eio.Promise.await flushed with
    | `Written -> () | `Closed -> raise Response_writer_closed

type frame = { data : Bigstringaf.t; lease : lease }
type stream = {
  owner : request;
  writer : H2.Body.Writer.t;
  queue : frame Queue.t;
  stopped : unit Eio.Promise.t;
  stop : unit Eio.Promise.u;
  mutable closed : bool;
  mutable waiter : unit Eio.Promise.u option;
}

let wake = function None -> () | Some resolve -> Eio.Promise.resolve resolve ()

let close_locked stream =
  if stream.closed then None else (
    stream.closed <- true;
    Queue.iter (fun frame -> release_locked frame.lease) stream.queue;
    Queue.clear stream.queue;
    let waiter = stream.waiter in stream.waiter <- None;
    Some waiter)

let close stream =
  match locked stream.owner.budget (fun () -> close_locked stream) with
  | None -> ()
  | Some waiter -> wake waiter; Eio.Promise.resolve stream.stop ()

let stream writer =
  let owner = current_exn () in
  let stopped, stop = Eio.Promise.create () in
  {owner;writer;queue=Queue.create ();stopped;stop;closed=false;waiter=None}

let is_closed stream = locked stream.owner.budget (fun () -> stream.closed || stream.owner.closed)

let offer stream payload =
  if String.length payload = 0 then not (is_closed stream) else
  match reserve stream.owner ~bytes:(String.length payload) with
  | Error (Capacity_exhausted | Request_closed) -> close stream; false
  | Ok lease ->
    let data =
      try Bigstringaf.of_string payload ~off:0 ~len:(String.length payload)
      with exn -> release lease; raise exn in
    let accepted, waiter = locked stream.owner.budget (fun () ->
      if stream.closed || stream.owner.closed then (release_locked lease; false,None)
      else (
        Queue.add {data;lease} stream.queue;
        let waiter=stream.waiter in stream.waiter <- None;
        true,waiter)) in
    wake waiter;
    accepted

type next = Frame of frame | Wait of unit Eio.Promise.t | Closed

let next stream = locked stream.owner.budget (fun () ->
  if stream.closed || stream.owner.closed then Closed
  else if not (Queue.is_empty stream.queue) then Frame (Queue.take stream.queue)
  else (
    let promise,resolve=Eio.Promise.create () in
    stream.waiter <- Some resolve;
    Wait promise))

let run stream =
  let in_flight = ref None in
  Fun.protect
    ~finally:(fun () ->
      Option.iter release !in_flight;
      close stream)
    (fun () -> Eio.Fiber.first
      (fun () -> Eio.Promise.await stream.stopped; raise Response_capacity_exhausted)
      (fun () ->
        let rec drain () = match next stream with
          | Closed -> raise Response_capacity_exhausted
          | Wait promise -> Eio.Promise.await promise; drain ()
          | Frame frame ->
            in_flight := Some frame.lease;
            let flushed,resolve=Eio.Promise.create () in
            H2.Body.Writer.schedule_bigstring stream.writer frame.data;
            H2.Body.Writer.flush stream.writer (fun result ->
              release frame.lease;
              Eio.Promise.resolve resolve result);
            (match Eio.Promise.await flushed with
             | `Closed -> raise Response_writer_closed
             | `Written -> in_flight := None; drain ()) in
        drain ()))
