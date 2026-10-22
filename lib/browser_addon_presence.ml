type unavailable =
  | Refused of Lane_addon_runtime.export_refusal
  | Observation_unreadable of string
  | Declarations_incomplete

type t =
  | Observed of Browser_addon_observation.published
  | Absent
  | Off
  | Not_running
  | Unavailable of unavailable

(* A browser Add-on is a package whose worker serves the browser. With no
   observation, the declarations say which absence it is: none declared, one
   switched off, or one switched on that the runtime runs no installation of. *)
let absence (declarations : Lane_addon_config.snapshot) =
  let browsers = List.filter (fun (d : Lane_addon_config.declaration) ->
    match d.package.worker_service with
    | Lane_addon_types.Browser_service -> true
    | Lane_addon_types.Mcp_tools -> false) declarations.declarations in
  match List.exists (fun (d : Lane_addon_config.declaration) -> d.enabled) browsers,
        browsers, declarations.complete with
  | true, _, (true | false) -> Not_running
  | false, _ :: _, (true | false) -> Off
  | false, [], true -> Absent
  | false, [], false -> Unavailable Declarations_incomplete

let of_export ~declarations = function
  | Error (Lane_addon_runtime.(Unready_installations _ | Not_yet_observed _ | Ambiguous_installations _)
           as refusal) -> Unavailable (Refused refusal)
  | Ok None -> absence declarations
  | Ok (Some (snapshot : Lane_addon_runtime.export_observation)) ->
      (match Browser_addon_observation.read snapshot.output with
       | Ok published -> Observed published
       | Error detail -> Unavailable (Observation_unreadable detail))

let read ~config ~declarations =
  Lane_addon_runtime.observation_for_export ~config ~access:Lane_addon_sources.Operator_configuration
    ~name:Browser_addon_tool.definition.name
  |> of_export ~declarations

let render_unavailable refusal_text = function
  | Refused refusal -> refusal_text refusal
  | Observation_unreadable detail -> "its observation is unreadable: " ^ detail
  | Declarations_incomplete -> "the Lane Add-on declarations could not all be read"
let unavailable_message = render_unavailable Lane_addon_runtime.export_refusal_message
let unavailable_operator_message = render_unavailable Lane_addon_runtime.export_refusal_operator_message

let polling = function
  | Observed (published : Browser_addon_observation.published) ->
      Browser_lane_launcher.Polling published.clients
  | Absent -> Browser_lane_launcher.Unlisted Browser_lane_launcher.No_browser_addon
  | Off -> Browser_lane_launcher.Unlisted Browser_lane_launcher.Browser_addon_off
  | Not_running -> Browser_lane_launcher.Unlisted Browser_lane_launcher.Browser_addon_not_running
  | Unavailable reason ->
      Browser_lane_launcher.Unlisted
        (Browser_lane_launcher.Browser_addon_unreadable (unavailable_message reason))
