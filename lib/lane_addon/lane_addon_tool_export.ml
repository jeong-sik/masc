(* The opaque cell is identity only, never written. Unlike an immutable box,
   each call has a generative identity even for equal constant instance ids. *)
type owner = { owner_instance_id : string; generation : unit ref }
let create_owner ~instance_id = { owner_instance_id = instance_id; generation = ref () }
let equal_owner left right = left.generation == right.generation

type t = { owner : owner; instance_id : string; tool : Mcp_protocol.Mcp_types.tool }

module Owner_key = struct
  type t = owner
  let equal = equal_owner
  let hash owner = Hashtbl.hash owner.owner_instance_id
end

module Tool_key = struct
  type t = Mcp_protocol.Mcp_types.tool
  let equal left right = left == right
  let hash (tool : t) = Hashtbl.hash tool.Mcp_protocol.Mcp_types.name
end

module Exports = Ephemeron.K2.Make (Owner_key) (Tool_key)
let exports : t Exports.t = Exports.create 0
let exports_mutex = Stdlib.Mutex.create ()

let create ~owner ~tool =
  Stdlib.Mutex.protect exports_mutex (fun () ->
    match Exports.find_opt exports (owner,tool) with
    | Some export -> export
    | None ->
      Exports.clean exports;
      let export = {owner;instance_id=owner.owner_instance_id;tool} in
      Exports.add exports (owner,tool) export;
      export)
;;

type conflict_reason = Reserved_host_name | Multiple_installations
type conflict = { name : string; instances : string list; reason : conflict_reason }
type snapshot = { exports : t list; conflicts : conflict list }
let isolate ~reserved exports =
  let names = List.map (fun (export : t) -> export.tool.name) exports
    |> List.sort_uniq String.compare in
  let conflicts = List.filter_map (fun name ->
    let same = List.filter (fun (export : t) -> String.equal export.tool.name name) exports in
    let instances = List.map (fun (export : t) -> export.instance_id) same in
    if List.mem name reserved then Some {name;instances;reason=Reserved_host_name}
    else if List.length same > 1 then Some {name;instances;reason=Multiple_installations}
    else None) names in
  {exports=List.filter (fun (export : t) ->
     not (List.exists (fun conflict -> String.equal conflict.name export.tool.name) conflicts)) exports;
   conflicts}
let conflict_to_string conflict =
  Printf.sprintf "%s: %s (instances: %s)" conflict.name
    (match conflict.reason with Reserved_host_name -> "reserved host tool name"
      | Multiple_installations -> "multiple visible installations")
    (String.concat ", " conflict.instances)
