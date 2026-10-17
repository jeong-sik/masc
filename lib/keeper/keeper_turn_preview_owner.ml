let key : Keeper_interrupt_token.t Eio.Fiber.key = Eio.Fiber.create_key ()
let with_owner ~interrupt_token operation = Eio.Fiber.with_binding key interrupt_token operation
let current () = match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> None
  | Eio_fiber -> Eio.Fiber.get key
