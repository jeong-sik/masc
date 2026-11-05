open Result.Syntax

type target = Workspace_default | Installation_space of Browser_configuration.ego_space
let target = function
  | `Assoc fields ->
      (match List.filter (fun (name, _) -> name = "space") fields with
       | [] -> Ok Workspace_default
       | [_, value] ->
           let* space = match value with
             | `String name -> Ok (Browser_configuration.Named_space name)
             | `Int id -> Ok (Browser_configuration.Existing_space id)
             | `Null | `Bool _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
                 Error "binding.space requires a task Space name or an exact numeric Space ID" in
           let* () = Browser_configuration.validate_ego_space space in
           Ok (Installation_space space)
       | _ :: _ :: _ -> Error "binding.space is duplicated")
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error "Ego installation binding requires an object"
let validate service binding = match service with
  | Lane_addon_types.Browser_service Browser_lane.Backend.Ego -> target binding |> Result.map (fun _ -> ())
  | Mcp_tools | Browser_service (Automation | Owned_firefox | External_host) -> Ok ()
let resolve ~(default : Browser_configuration.live_ego) = function
  | Workspace_default -> default
  | Installation_space space -> {default with space}
