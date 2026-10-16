(* In-memory container engines for lifecycle tests. An engine holds named
   containers with labels and a run state. The world has one ambient target,
   like the Docker CLI's current context: pointing it at another engine is
   what [colima start] does to the next command. The fake models only what a
   lifecycle decision depends on; classification and engine proofs run in the
   real [Lane_addon_slot] over [port]. *)
module Lifecycle = Masc.Lane_addon_lifecycle
module Slot = Masc.Lane_addon_slot

type run_state = Running | Exited
type container = {
  id : string;
  name : string;
  labels : (string * string) list;
  run_state : run_state;
}
type engine = {
  identity : Lifecycle.engine;
  mutable up : bool;
  containers : (string, container) Hashtbl.t;
}
type t = { mutable current : engine }

let engine ?(up = true) identity = { identity; up; containers = Hashtbl.create 4 }
let docker name = engine (Lifecycle.Docker_engine name)
let create engine = { current = engine }
let point_at world engine = world.current <- engine
let current world = world.current
let set_up engine up = engine.up <- up

let port world : Slot.port = {
  read_engine = (fun () ->
    if world.current.up then Ok world.current.identity
    else Error (Lifecycle.Unreachable "fixture engine is down"))
}

let containers engine =
  Hashtbl.to_seq_values engine.containers |> List.of_seq
  |> List.sort (fun a b -> String.compare a.id b.id)
let find engine id = Hashtbl.find_opt engine.containers id
let find_by_name engine name = List.find_opt (fun c -> String.equal c.name name) (containers engine)
let holds engine id = Hashtbl.mem engine.containers id

(* The engine refuses a second container under one name, like Docker. *)
let add engine ?(run_state = Running) ~id ~name ~labels () =
  if find_by_name engine name <> None then Error ("container name is already in use: " ^ name)
  else (Hashtbl.replace engine.containers id { id; name; labels; run_state }; Ok id)

(* `docker rm` on whichever engine the CLI reaches. A missing container is
   not an error to the caller that only wants it gone, which is exactly why an
   absence needs the engine proof. *)
let remove world id = Hashtbl.remove world.current.containers id
let exists world id = Hashtbl.mem world.current.containers id
