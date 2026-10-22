module B = Browser_lane
module W = Browser_addon_wire
module R = Lane_addon_runtime
let ( let* ) = Result.bind
type unavailable =
  | No_addon
  | Ambiguous_addons
  | Observation_unavailable
  | Addon_unavailable
  | Registration_unconfirmed of string
  | Worker_unavailable of string
  | Worker_refused of string
let unavailable_to_wire = function
  | No_addon -> "no_browser_addon"
  | Ambiguous_addons -> "ambiguous_browser_addons"
  | Observation_unavailable -> "browser_addon_observation_unavailable"
  | Addon_unavailable -> "browser_addon_unavailable"
  | Registration_unconfirmed _ -> "browser_registration_unconfirmed"
  | Worker_unavailable _ -> "browser_addon_worker_unavailable"
  | Worker_refused _ -> "browser_addon_worker_refused"
let unavailable_message = function
  | No_addon -> "no browser Add-on is attached"
  | Ambiguous_addons -> "multiple browser Add-ons are attached; native host selection is ambiguous"
  | Observation_unavailable -> "original browser Add-on observation is unavailable"
  | Addon_unavailable -> "original browser Add-on is temporarily unavailable"
  | Registration_unconfirmed detail -> "browser registration unconfirmed: " ^ detail
  | Worker_unavailable detail | Worker_refused detail -> detail
type error = Registration_refused of B.registration_refusal
  | Unavailable of unavailable | Outcome_unknown of string
let access=Lane_addon_sources.Operator_configuration
let root config = Filename.concat
  (Filename.concat (Workspace.masc_dir config) Common.browser_lane_dirname) "registrations"
let registration_error = function
  | Browser_addon_registration.Identity_changed -> Registration_refused B.Client_identity_changed
  | Unconfirmed detail -> Unavailable (Registration_unconfirmed detail)
let find ~config ~client = Eio_unix.run_in_systhread (fun () ->
  Browser_addon_registration.find ~root:(root config) ~client) |> Result.map_error registration_error
type purpose = Polling | Settlement
let service ~config ~purpose instance_id =
  match R.browser_service_status ~config ~access ~instance_id with
  | R.Browser_ready service -> Ok service
  | Browser_refresh_needed service when purpose=Settlement -> Ok service
  | Browser_refresh_needed _ ->
      (* Demand for this original host connection reuses its normal observation
         wake. It never restarts the worker or reissues a browser command. *)
      ignore (R.dispatch ~caller:"native-browser-host" ~access ~config ~operation:R.Observe
        (`Assoc ["instance_id",`String instance_id]));
      Error (Unavailable Observation_unavailable)
  | Browser_unavailable -> Error (Unavailable Addon_unavailable)
  | Browser_retired -> Error (Registration_refused B.Client_retired)
let existing ~config ~client =
  let* instance=find ~config ~client in
  match instance with
  | Some instance -> service ~config ~purpose:Settlement instance
  | None -> Error (Registration_refused B.Client_retired)
let for_poll ~config ~client =
  let* instance=find ~config ~client in
  match instance with
  | Some instance -> service ~config ~purpose:Polling instance
  | None ->
      let* selected=match R.browser_services ~config ~access with
        | [selected] -> Ok selected
        | [] -> Error (Unavailable No_addon)
        | _::_::_ -> Error (Unavailable Ambiguous_addons) in
      let* original=Eio_unix.run_in_systhread (fun () -> Browser_addon_registration.claim
        ~root:(root config) ~client ~instance_id:selected.instance_id) |> Result.map_error registration_error in
      service ~config ~purpose:Polling original
let call ~config ~service command =
  R.call_browser_service ~config ~access ~service ~command
    |> Result.map_error (function Browser_addon_client.Unavailable detail -> Unavailable (Worker_unavailable detail)
      | Outcome_unknown detail -> Outcome_unknown detail)
let refusal disposition message = match B.registration_refusal_of_wire message with
  | Some refusal -> Registration_refused refusal
  | None -> (match disposition with W.Not_started -> Unavailable (Worker_refused message) | Outcome_unknown -> Outcome_unknown message)
let poll ~config ~client ~window_sec =
  let* service=for_poll ~config ~client in
  let* reply=call ~config ~service (W.Poll {client;window_sec}) in
  match reply with
  | W.Poll_result {command;_} -> Ok command
  | Service_refusal {message;disposition} -> Error (refusal disposition message)
  | Snapshot_result _|Model_reply _|Download_reply _|Receipt|Issue_result _ -> Error (Outcome_unknown "unexpected browser poll receipt")
let receipt = function
  | W.Receipt -> Ok ()
  | Service_refusal {message;disposition} -> Error (refusal disposition message)
  | Snapshot_result _|Model_reply _|Download_reply _|Poll_result _|Issue_result _ -> Error (Outcome_unknown "unexpected browser host receipt")
let deliver ~config ~client ~id ~payload =
  let* service=existing ~config ~client in
  let* reply=call ~config ~service (W.Deliver {client_id=client.B.client_id;id;payload}) in
  receipt reply
let disconnect ~config ~client =
  let* service=existing ~config ~client in
  let* reply=call ~config ~service (W.Disconnect client.B.client_id) in
  receipt reply
