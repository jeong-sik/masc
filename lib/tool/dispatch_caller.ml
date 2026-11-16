let key : string Eio.Fiber.key = Eio.Fiber.create_key ()
let with_keeper name f = Eio.Fiber.with_binding key name f
let current_keeper () = Eio.Fiber.get key
