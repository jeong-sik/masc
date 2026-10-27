type unavailable =
  | Refused of Lane_addon_runtime.export_refusal
  | Observation_unreadable of string
  | Declarations_incomplete

type t =
  | Observed of Browser_addon_observation.published
  | Absent
  | Off
  | Not_running of Browser_lane_launcher.not_running
  | Unavailable of unavailable

(* How the maintenance pass last applied one declaration, when exactly one
   observation is of this declaration's file and revision, as the Lanes
   screen's package rows match them. *)
let application_of applications (d : Lane_addon_config.declaration) =
  match List.filter (fun (observed : Lane_addon_runtime.configuration_application) ->
      String.equal observed.owner.id d.id && String.equal observed.owner.source_path d.source_path
      && String.equal observed.source_revision d.source_revision
      && String.equal observed.owner.revision d.revision && Bool.equal observed.enabled d.enabled)
      applications with
  | [observed] -> Some observed.application
  | [] | _ :: _ :: _ -> None

let not_running_of = function
  | Some (Lane_addon_application.Starting_worker | Lane_addon_application.Cleaning_workers) ->
      Browser_lane_launcher.Attaching
  | Some (Lane_addon_application.Failed _) -> Browser_lane_launcher.Attach_failed
  | Some (Lane_addon_application.Applied _ | Lane_addon_application.Inactive
         | Lane_addon_application.Unknown _) | None -> Browser_lane_launcher.Not_known

(* A worker being started or replaced may still take the hosts. Only when
   every declaration was read and each browser one that is on failed to
   apply has the attach failed. *)
let not_running ~complete applications (first, rest) =
  let reasons = List.map (fun d -> not_running_of (application_of applications d)) (first :: rest) in
  let attaching = function
    | Browser_lane_launcher.Attaching -> true
    | Browser_lane_launcher.(Attach_failed | Not_known) -> false in
  let failed = function
    | Browser_lane_launcher.Attach_failed -> true
    | Browser_lane_launcher.(Attaching | Not_known) -> false in
  if List.exists attaching reasons then Browser_lane_launcher.Attaching
  else if complete && List.for_all failed reasons then Browser_lane_launcher.Attach_failed
  else Browser_lane_launcher.Not_known

(* A browser Add-on of a lane is a package whose worker serves one of that
   lane's sources. With no observation, the declarations say which absence it
   is: none declared, one switched off, or one switched on that the reader
   sees no installation of. *)
let absence ~applications ~lane (declarations : Lane_addon_config.snapshot) =
  let browsers = List.filter (fun d ->
    match Lane_addon_config.browser_source d with
    | Some backend -> Browser_lane.Backend.lane backend = lane
    | None -> false) declarations.declarations in
  match List.filter (fun (d : Lane_addon_config.declaration) -> d.enabled) browsers,
        browsers, declarations.complete with
  | first :: rest, _, complete -> Not_running (not_running ~complete (applications ()) (first, rest))
  | [], _ :: _, true -> Off
  | [], [], true -> Absent
  (* A declaration that could not be read may be a browser one switched on. *)
  | [], ([] | _ :: _), false -> Unavailable Declarations_incomplete

type reading = {
  observations : Lane_addon_runtime.browser_observation list;
  declarations : Lane_addon_config.snapshot;
  applications : unit -> Lane_addon_runtime.configuration_application list;
}

let of_observations ~declarations ~applications observations = {observations; declarations; applications}

let read ~config ~access ~declarations =
  (* How each declaration was applied is operator metadata; another reader
     cannot tell a failed attach from one not made yet. *)
  let applications () = match access with
    | Lane_addon_sources.Operator_configuration -> (Lane_addon_runtime.inventory ~config).applications
    | Lane_addon_sources.Keeper _ | Lane_addon_sources.Unauthenticated -> [] in
  of_observations ~declarations ~applications (Lane_addon_runtime.browser_observations ~config ~access)

type published_or_not = Published of Browser_addon_observation.published | Unpublished | Withheld of unavailable
let published_or_not = function
  | Error refusal -> Withheld (Refused refusal)
  | Ok None -> Unpublished
  | Ok (Some (snapshot : Lane_addon_runtime.export_observation)) ->
      (match Browser_addon_observation.read snapshot.output with
       | Ok published -> Published published
       | Error detail -> Withheld (Observation_unreadable detail))

(* One lane reads the installations of its sources, one observation per
   source: two installations of one source arrive as one ambiguous
   observation. A source whose observation is withheld leaves out only what
   it would publish, since the host cannot reach it either, and the lane
   reads the others. Only when none of them published is the lane
   unavailable, for the first withheld reason; the other lanes are read as
   usual. *)
let lane reading lane =
  let read = List.filter_map (fun (observed : Lane_addon_runtime.browser_observation) ->
    if Browser_lane.Backend.lane observed.backend = lane
    then Some (observed.backend, published_or_not observed.observation) else None)
    reading.observations in
  let workers = List.map (fun (backend, read) -> backend, match read with
    | Published published -> Some published | Unpublished | Withheld _ -> None) read in
  if List.exists (fun (_, published) -> Option.is_some published) workers
  then Observed (Browser_addon_observation.merge
                   ~among:(List.map (fun (observed : Lane_addon_runtime.browser_observation) ->
                     observed.backend) reading.observations) workers)
  else match List.find_map (fun (_, read) -> match read with
      | Withheld reason -> Some reason | Published _ | Unpublished -> None) read with
    | Some reason -> Unavailable reason
    | None -> absence ~applications:reading.applications ~lane reading.declarations

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
  | Not_running reason ->
      Browser_lane_launcher.Unlisted (Browser_lane_launcher.Browser_addon_not_running reason)
  | Unavailable reason ->
      Browser_lane_launcher.Unlisted
        (Browser_lane_launcher.Browser_addon_unreadable (unavailable_message reason))
