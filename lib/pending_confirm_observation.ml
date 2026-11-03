type t =
  | Not_managed
  | Initializing
  | Observed
  | Source_unavailable
  | Deadline_unavailable
  | Workspace_unobserved
  | Scope_unavailable

type stamp =
  | Unmanaged
  | Managed of { epoch : string; generation : int }

type sample = { status : t; stamp : stamp }
type reading = { sample : sample; registration : unit ref }
type provider = Workspace.config -> sample
type registration = { observe : provider; identity : unit ref }

let unmanaged = { status = Not_managed; stamp = Unmanaged }
let managed ~epoch ~generation status =
  { status; stamp = Managed { epoch; generation } }

let status reading = reading.sample.status

let same_revision first second =
  first.registration == second.registration &&
  match first.sample.stamp, second.sample.stamp with
  | Unmanaged, Unmanaged -> true
  | Managed first, Managed second ->
      String.equal first.epoch second.epoch
      && Int.equal first.generation second.generation
  | Unmanaged, Managed _ | Managed _, Unmanaged -> false

let provider : registration Atomic.t =
  Atomic.make { observe = (fun _ -> unmanaged); identity = ref () }

let read config =
  let registration = Atomic.get provider in
  { sample = registration.observe config; registration = registration.identity }

let get config = status (read config)
let install observer =
  (Atomic.exchange provider { observe = observer; identity = ref () }).observe

let rec restore_if_current ~current ~previous =
  let installed = Atomic.get provider in
  if installed.observe != current then false
  else if Atomic.compare_and_set provider installed { observe = previous; identity = ref () }
  then true
  else restore_if_current ~current ~previous
