type lane =
  | Read
  | Background

(* One HTTP read. Fibers forked while it is answered share this record, so
   ending the read once ends it for all of them. *)
type read = { answered : bool Atomic.t }

let key : read Eio.Fiber.key = Eio.Fiber.create_key ()

let current () =
  match Eio_guard.execution_context () with
  | Eio_guard.Non_eio -> Background
  | Eio_guard.Eio_fiber ->
    (match Eio.Fiber.get key with
     | Some read when not (Atomic.get read.answered) -> Read
     | Some _ | None -> Background)
;;

let with_read f =
  match Eio_guard.execution_context () with
  | Eio_guard.Non_eio -> f ()
  | Eio_guard.Eio_fiber ->
    let read = { answered = Atomic.make false } in
    Fun.protect
      ~finally:(fun () -> Atomic.set read.answered true)
      (fun () -> Eio.Fiber.with_binding key read f)
;;

let with_background f =
  match Eio_guard.execution_context () with
  | Eio_guard.Non_eio -> f ()
  | Eio_guard.Eio_fiber -> Eio.Fiber.without_binding key f
;;

let to_string = function
  | Read -> "read"
  | Background -> "background"
;;
