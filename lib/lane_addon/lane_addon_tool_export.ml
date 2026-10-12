type t = { instance_id : string; tool : Mcp_protocol.Mcp_types.tool }

let create ~instance_id ~tool = { instance_id; tool }

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
