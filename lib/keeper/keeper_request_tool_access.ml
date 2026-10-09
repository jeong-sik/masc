type t =
  { offered : Agent_core.Tool.t list
  ; loadable_names : string list
  }

type route = Direct | Discoverable | Unavailable

let contains tools name =
  List.exists (fun (tool : Agent_core.Tool.t) -> String.equal tool.schema.name name) tools

let create ~offered ~deferred_names ~loader_alive =
  let loadable_names =
    if loader_alive && contains offered Tool_schemas_identity_tool_search.schema.name
    then deferred_names else [] in
  { offered; loadable_names }

let offered access = access.offered

let route access ~name =
  if contains access.offered name then Direct
  else if List.mem name access.loadable_names then Discoverable
  else Unavailable
