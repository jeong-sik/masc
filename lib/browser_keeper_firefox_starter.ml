type started = Firefox_and_host | Host_only | Nothing

type not_attached =
  | Operator_needed of string
  | Start_failed of string
  | Not_listed_in_time of string

type outcome =
  | Attached of { client : Browser_lane.client_info; started : started }
  | Not_attached of not_attached
  | Not_asked_for

let installed : (unit -> outcome) option Atomic.t = Atomic.make None
let install start = Atomic.set installed start

let bring_up () =
  match Atomic.get installed with
  | None -> Not_asked_for
  | Some start -> start ()
