let changed_event = "keeper_turn_preview_changed"

let observer : (base_path:string -> keeper_name:string -> unit) Atomic.t =
  Atomic.make (fun ~base_path:_ ~keeper_name:_ -> ())

let install observer_fn = Atomic.set observer observer_fn
let changed ~base_path ~keeper_name = (Atomic.get observer) ~base_path ~keeper_name
