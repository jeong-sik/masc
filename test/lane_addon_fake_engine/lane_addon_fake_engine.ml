(* In-memory container engines for lifecycle tests. An engine holds named
   containers with labels. The world has one ambient target,
   like the Docker CLI's current context: pointing it at another engine is
   what [colima start] does to the next command. The fake models only what a
   lifecycle decision depends on; classification, claims and engine proofs run
   in the real [Lane_addon_slot] over [port]. *)
module Lifecycle = Masc.Lane_addon_lifecycle
module Slot = Masc.Lane_addon_slot
module Engine = Masc.Lane_addon_engine

type container = {
  id : string;
  name : string;
  labels : (string * string) list;
}
type engine = {
  identity : Lifecycle.engine;
  mutable up : bool;
  containers : (string, container) Hashtbl.t;
  refusing_removal : (string, unit) Hashtbl.t;
}
(* [scope] is the base-path label the fake servers put on their containers. *)
type t = { mutable current : engine; scope : string }

let engine ?(up = true) identity =
  { identity; up; containers = Hashtbl.create 4; refusing_removal = Hashtbl.create 1 }
let docker name = engine (Lifecycle.Docker_engine name)
let scope_of_world = "fixture-scope"
let create engine = { current = engine; scope = scope_of_world }
let point_at world engine = world.current <- engine
let current world = world.current
let set_up engine up = engine.up <- up
let refuse_removal engine id = Hashtbl.replace engine.refusing_removal id ()
let allow_removal engine id = Hashtbl.remove engine.refusing_removal id

let containers engine =
  Hashtbl.to_seq_values engine.containers |> List.of_seq
  |> List.sort (fun a b -> String.compare a.id b.id)
let find engine id = Hashtbl.find_opt engine.containers id
let find_by_name engine name = List.find_opt (fun c -> String.equal c.name name) (containers engine)
let holds engine id = Hashtbl.mem engine.containers id

(* The engine refuses a second container under one name, like Docker. *)
let add engine ~id ~name ~labels () =
  if find_by_name engine name <> None then Error ("container name is already in use: " ^ name)
  else (Hashtbl.replace engine.containers id { id; name; labels }; Ok id)

(* `docker rm` on whichever engine the CLI reaches. A missing container is
   not an error to the caller that only wants it gone, which is exactly why an
   absence needs the engine proof. *)
let remove world id = Hashtbl.remove world.current.containers id
let exists world id = Hashtbl.mem world.current.containers id

let down = "fixture engine is down"
let engine_command world work =
  if world.current.up then work world.current else Error down

let port world : Slot.port = {
  read_engine = (fun () ->
    if world.current.up then Ok world.current.identity
    else Error (Lifecycle.Unreachable down));
  find = (fun lookup -> engine_command world (fun engine ->
    match lookup with
    | Engine.Name name -> Ok (Option.map (fun c -> c.id) (find_by_name engine name))
    | Engine.Id id -> Ok (if holds engine id then Some id else None)));
  inspect = (fun id -> engine_command world (fun engine ->
    match find engine id with
    | None -> Error ("no such container: " ^ id)
    | Some c ->
        Ok { Engine.container_id = c.id; name = c.name;
             instance = List.assoc_opt Engine.instance_label c.labels;
             state_owner = List.assoc_opt Engine.state_owner_label c.labels }));
  remove = (fun id -> engine_command world (fun engine ->
    if Hashtbl.mem engine.refusing_removal id then Error ("removal refused: " ^ id)
    else (Hashtbl.remove engine.containers id; Ok ())));
  scoped = (fun () -> engine_command world (fun engine ->
    Ok (containers engine
        |> List.filter (fun c -> List.assoc_opt Engine.scope_label c.labels = Some world.scope)
        |> List.map (fun c -> c.id))));
}

(* The runtime's one cheap read of a waiting failure's condition. *)
let condition_met world = function
  | Lifecycle.Engine_reachable -> Result.is_ok ((port world).read_engine ())
  | Lifecycle.Engine_is expected ->
      (match (port world).read_engine () with
       | Ok actual -> Lifecycle.engine_equal actual expected
       | Error _ -> false)
  | Lifecycle.Holder_changes holder -> Slot.holder_changed (port world) holder
