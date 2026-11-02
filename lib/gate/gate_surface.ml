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
  if String.equal channel dashboard_label then Dashboard
  else if String.equal channel discord_label then
    Discord { workspace_id = None; channel_id = Some channel_id }
  else if String.equal channel slack_label then
    Slack { workspace_id = None; channel_id = Some channel_id }
  else Gate { channel; channel_id = Some channel_id }

let compare_surface (a : t) (b : t) =
  match a, b with
  | Dashboard, Dashboard -> 0
  | Dashboard, (Discord _ | Slack _ | Gate _) -> -1
  | (Discord _ | Slack _ | Gate _), Dashboard -> 1
  | Discord a, Discord b ->
    let c = Option.compare String.compare a.workspace_id b.workspace_id in
    if c <> 0 then c else Option.compare String.compare a.channel_id b.channel_id
  | Discord _, (Slack _ | Gate _) -> -1
  | (Slack _ | Gate _), Discord _ -> 1
  | Slack a, Slack b ->
    let c = Option.compare String.compare a.workspace_id b.workspace_id in
    if c <> 0 then c else Option.compare String.compare a.channel_id b.channel_id
  | Slack _, Gate _ -> -1
  | Gate _, Slack _ -> 1
  | Gate a, Gate b ->
    let c = String.compare a.channel b.channel in
    if c <> 0 then c else Option.compare String.compare a.channel_id b.channel_id

let compare_surface_presence (a : surface_presence) (b : surface_presence) =
  let c = compare_surface a.surface b.surface in
  if c <> 0 then c else Bool.compare a.alive b.alive

let compare_binding_decode_error
      (a : Channel_gate_binding_store.binding_decode_error)
      (b : Channel_gate_binding_store.binding_decode_error)
  =
  match a, b with
  | Expected_object, Expected_object -> 0
  | Expected_object, (Blank_channel_id | Non_canonical_channel_id _ | Keeper_name_not_string _ | Blank_keeper_name _ | Non_canonical_keeper_name _ | Duplicate_channel_id _) -> -1
  | (Blank_channel_id | Non_canonical_channel_id _ | Keeper_name_not_string _ | Blank_keeper_name _ | Non_canonical_keeper_name _ | Duplicate_channel_id _), Expected_object -> 1
  | Blank_channel_id, Blank_channel_id -> 0
  | Blank_channel_id, (Non_canonical_channel_id _ | Keeper_name_not_string _ | Blank_keeper_name _ | Non_canonical_keeper_name _ | Duplicate_channel_id _) -> -1
  | (Non_canonical_channel_id _ | Keeper_name_not_string _ | Blank_keeper_name _ | Non_canonical_keeper_name _ | Duplicate_channel_id _), Blank_channel_id -> 1
  | Non_canonical_channel_id a, Non_canonical_channel_id b -> String.compare a b
  | Non_canonical_channel_id _, (Keeper_name_not_string _ | Blank_keeper_name _ | Non_canonical_keeper_name _ | Duplicate_channel_id _) -> -1
  | (Keeper_name_not_string _ | Blank_keeper_name _ | Non_canonical_keeper_name _ | Duplicate_channel_id _), Non_canonical_channel_id _ -> 1
  | Keeper_name_not_string a, Keeper_name_not_string b -> String.compare a b
  | Keeper_name_not_string _, (Blank_keeper_name _ | Non_canonical_keeper_name _ | Duplicate_channel_id _) -> -1
  | (Blank_keeper_name _ | Non_canonical_keeper_name _ | Duplicate_channel_id _), Keeper_name_not_string _ -> 1
  | Blank_keeper_name a, Blank_keeper_name b -> String.compare a b
  | Blank_keeper_name _, (Non_canonical_keeper_name _ | Duplicate_channel_id _) -> -1
  | (Non_canonical_keeper_name _ | Duplicate_channel_id _), Blank_keeper_name _ -> 1
  | Non_canonical_keeper_name a, Non_canonical_keeper_name b ->
    let c = String.compare a.channel_id b.channel_id in
    if c <> 0 then c else String.compare a.keeper_name b.keeper_name
  | Non_canonical_keeper_name _, Duplicate_channel_id _ -> -1
  | Duplicate_channel_id _, Non_canonical_keeper_name _ -> 1
  | Duplicate_channel_id a, Duplicate_channel_id b -> String.compare a b

let compare_binding_store_error
      (a : Channel_gate_binding_store.binding_store_error)
      (b : Channel_gate_binding_store.binding_store_error)
  =
  match a, b with
  | Binding_store_io_failed a, Binding_store_io_failed b -> String.compare a b
  | Binding_store_io_failed _, Binding_store_decode_failed _ -> -1
  | Binding_store_decode_failed _, Binding_store_io_failed _ -> 1
  | Binding_store_decode_failed a, Binding_store_decode_failed b ->
    let c = String.compare a.path b.path in
    if c <> 0 then c else compare_binding_decode_error a.error b.error

let compare_presence_failure (a : presence_failure) (b : presence_failure) =
  let c = String.compare a.connector_id b.connector_id in
  if c <> 0 then c else compare_binding_store_error a.error b.error

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
    |> List.sort compare_surface_presence
  in
  { surfaces = { surface = Dashboard; alive = true } :: surfaces
  ; failures = List.sort compare_presence_failure failures
  }
