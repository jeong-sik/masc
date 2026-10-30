(* Created once at module init: the key's identity is what [with_binding] and
   [get] look each other up by, and a key made per call would bind a value no
   read could find. *)
let registry_key : Spawn_registry.t Eio.Fiber.key = Eio.Fiber.create_key ()

let with_turn_registry registry f =
  match registry with
  | Some registry -> Eio.Fiber.with_binding registry_key registry f
  | None -> f ()
;;

let get_opt () = Eio.Fiber.get registry_key
