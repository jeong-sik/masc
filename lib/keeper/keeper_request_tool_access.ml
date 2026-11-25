type t =
  { offered : Agent_core.Tool.t list
  ; loadable_names : string list
  ; supports_request_only_context : bool
  }

type route = Direct | Discoverable | Unavailable

let contains tools name =
  List.exists (fun (tool : Agent_core.Tool.t) -> String.equal tool.schema.name name) tools

let create ~offered ~deferred_names ~loader_alive =
  let loadable_names =
    if loader_alive && contains offered Tools.identity_tool_search_schema.name
    then deferred_names else [] in
  { offered; loadable_names; supports_request_only_context = false }

let offered access = access.offered
let with_request_only_context supports_request_only_context access =
  { access with supports_request_only_context }
let supports_request_only_context access = access.supports_request_only_context

let route access ~name =
  if contains access.offered name then Direct
  else if List.mem name access.loadable_names then Discoverable
  else Unavailable
