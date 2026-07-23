type t =
  | Dashboard
  | Discord of { workspace_id : string option; channel_id : string option }
  | Slack of { workspace_id : string option; channel_id : string option }
  | Gate of { channel : string; channel_id : string option }

let dashboard_label = "dashboard"
let discord_label = "discord"
let slack_label = "slack"

let label = function
  | Dashboard -> dashboard_label
  | Discord _ -> discord_label
  | Slack _ -> slack_label
  | Gate { channel; _ } -> channel

let of_source ~source ~workspace_id ~channel_id =
  if String.equal source dashboard_label then Dashboard
  else if String.equal source discord_label then
    Discord { workspace_id; channel_id }
  else if String.equal source slack_label then
    Slack { workspace_id; channel_id }
  else Gate { channel = source; channel_id }

type surface_presence = { surface : t; alive : bool }

type presence_failure =
  { connector_id : string
  ; error : Channel_gate_binding_store.binding_store_error
  }

type presence_snapshot =
  { surfaces : surface_presence list
  ; failures : presence_failure list
  }

let surface_of_connector ~channel ~channel_id =
  of_source ~source:channel ~workspace_id:None ~channel_id:(Some channel_id)

let connected_surfaces_for_keeper ~keeper_name =
  let connector_surfaces, failures =
    Channel_gate_connector.all ()
    |> List.fold_left
         (fun (surfaces, failures) (module C : Channel_gate_connector.S) ->
           match C.bound_channels ~keeper_name with
           | Error error ->
             surfaces, { connector_id = C.connector_id; error } :: failures
           | Ok channel_ids ->
             let alive = C.connected () in
             let connector_surfaces =
               List.map
                 (fun channel_id ->
                   { surface =
                       surface_of_connector ~channel:C.channel ~channel_id
                   ; alive
                   })
                 channel_ids
             in
             List.rev_append connector_surfaces surfaces, failures)
         ([], [])
  in
  let surfaces =
    connector_surfaces
    (* Registry iteration order is a Hashtbl fold; sort for stable
       prompt rendering. *)
    |> List.sort compare
  in
  { surfaces = { surface = Dashboard; alive = true } :: surfaces
  ; failures = List.sort compare failures
  }
