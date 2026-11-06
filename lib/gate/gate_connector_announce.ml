let discord = "discord"
let slack = "slack"

let observer : (connector_id:string -> unit) option Atomic.t = Atomic.make None

let install f = Atomic.set observer (Some f)

let changed ~connector_id =
  match Atomic.get observer with
  | Some f -> f ~connector_id
  | None -> ()
