type t =
  | Eio_fiber
  | Non_eio

let current () =
  match Eio.Fiber.is_cancelled () with
  | true | false -> Eio_fiber
  | exception Effect.Unhandled _ -> Non_eio
;;
