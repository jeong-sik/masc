type phase =
  | Dispatch_started
  | Response_received of int

let observer_key : (phase -> unit) Eio.Fiber.key = Eio.Fiber.create_key ()
let with_observer observer run = Eio.Fiber.with_binding observer_key observer run

let observe phase =
  match Eio.Fiber.get observer_key with
  | None -> ()
  | Some observer -> observer phase
;;
