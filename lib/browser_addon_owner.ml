module B = Browser_lane
module W = Browser_addon_wire

type phase = Serving | Retired
type t = {
  incarnation : string;
  gate : Eio.Mutex.t;
  mutable phase : phase;
  mutable clients : B.client_id list;
  mutable automation : bool;
  mutable cleanup : (unit -> (unit, string) result) option;
  mutable models : Browser_addon_models.t option;
  retired : unit Eio.Promise.t;
  retire : unit Eio.Promise.u;
}
let process_claimed = Atomic.make false
let incarnation t = t.incarnation
let create ~incarnation =
  match B.client_id_of_string incarnation with
  | Error message -> Error message
  | Ok _ ->
    if not (Atomic.compare_and_set process_claimed false true) then
      Error "a browser owner already exists in this process"
    else
      let retired, retire = Eio.Promise.create () in
      let t = {incarnation;gate=Eio.Mutex.create ();phase=Serving;clients=[];automation=false;cleanup=None;models=None;retired;retire} in
      B.install_activity_observer (Some (fun lane -> match t.phase,lane with
        | Serving,B.Lane_name.Live -> B.Enabled
        | Serving,B.Lane_name.Automation -> if t.automation then B.Enabled else B.Disabled
        | Serving,B.Lane_name.Stagehand | Retired,(B.Lane_name.Live|Automation|Stagehand) -> B.Disabled));
      Ok t
let refusal ?(disposition=W.Not_started) message = W.Service_refusal {message;disposition}
let admission t incarnation =
  if not (String.equal t.incarnation incarnation) then Error (refusal "wrong browser worker incarnation")
  else match t.phase with Serving -> Ok () | Retired -> Error (refusal "browser worker is retired")
let with_admission t incarnation run =
  Eio.Mutex.use_rw ~protect:true t.gate (fun () ->
    Result.bind (admission t incarnation) (fun () -> run ()))
let snapshot t = `Assoc [
  "state",`String (match t.phase with Serving -> "serving" | Retired -> "retired");
  "clients",`List (List.map B.client_json (B.connected_clients ()));
  "owned_backends",Browser_addon_inventory.owned_to_json (Browser_selection.snapshot ())]
let models_enabled t = Option.is_some t.models
let attach_models t models =
  Eio.Mutex.use_rw ~protect:true t.gate (fun () ->
    if Browser_addon_models.incarnation models<>t.incarnation then Error "wrong browser model incarnation" else
    match t.phase,t.models with
    | Retired,_ -> Error "browser owner is retired"
    | Serving,Some _ -> Error "browser model broker is already attached"
    | Serving,None -> t.models<-Some models;Ok ())
let admitted_models t =
  Eio.Mutex.use_rw ~protect:true t.gate (fun () -> match t.phase,t.models with
    | Retired,_ -> Error Browser_addon_models.Retired
    | Serving,None -> Error (Browser_addon_models.Output_disabled "model broker")
    | Serving,Some models -> Ok models)
let generate t request = Result.bind (admitted_models t) (fun models -> Browser_addon_models.request models request)
let model_output t ~name = match admitted_models t with
  | Error _ -> None
  | Ok models -> Browser_addon_models.output models ~name
let attach_automation t ~locate ~execute ~session ~document ~cleanup =
  Eio.Mutex.use_rw ~protect:true t.gate (fun () -> match t.phase,t.automation with
    | Retired,_ -> Error "browser owner is retired"
    | Serving,true -> Error "automation backend is already attached"
    | Serving,false ->
      B.install_automation_executor ~locate (Some execute);
      B.install_server_session_observer B.Server_automation (Some session);
      B.install_automation_document_observer (Some document);
      t.automation <- true;t.cleanup <- Some cleanup;Ok ())
let revoke t =
  Eio.Mutex.use_rw ~protect:true t.gate (fun () ->
    match t.phase with
    | Retired -> ()
    | Serving ->
      t.phase <- Retired;
      Option.iter Browser_addon_models.retire t.models;
      t.automation <- false;
      B.install_automation_executor None;
      B.install_server_session_observer B.Server_automation None;
      B.install_automation_document_observer None;
      Eio.Promise.resolve t.retire ();
      List.iter (fun client_id -> ignore (B.disconnect_client ~client_id)) t.clients;
      t.clients <- [])
let waiting t ~disposition run =
  Watched_work.run run ~watcher:(fun () ->
    Eio.Promise.await t.retired;
    refusal ~disposition "browser worker retired during the request")
let model_port t incarnation run =
  let models=with_admission t incarnation (fun () -> match t.models with
    | Some models -> Ok models | None -> Error (refusal "browser model broker is disabled")) in
  match models with
  | Error reply -> reply
  | Ok models -> (match run models with
      | Ok value -> W.Model_reply value
      | Error error -> refusal (Browser_addon_models.error_to_string error))
let dispatch t (request : W.request) =
  match request.command with
  | W.Retire ->
    if request.incarnation<>t.incarnation then refusal "wrong browser worker incarnation"
    else (revoke t;match t.cleanup with
      | None -> W.Receipt
      | Some cleanup -> match cleanup () with Ok () -> W.Receipt
          | Error message -> refusal ~disposition:W.Outcome_unknown message)
  | W.Snapshot ->
    (match with_admission t request.incarnation (fun () -> Ok (snapshot t)) with
     | Error reply -> reply | Ok value -> W.Snapshot_result value)
  | W.Model_requests -> model_port t request.incarnation Browser_addon_models.listing
  | W.Model_result arguments -> model_port t request.incarnation (fun models ->
      Browser_addon_models.deliver models ~arguments
      |> Result.map (fun accepted -> `Assoc ["accepted",`Bool accepted]))
  | W.Model_wait {after} -> model_port t request.incarnation (fun models ->
      Browser_addon_models.wait models ~after |> Result.map Lane_addon_host_request.availability_to_json)
  | W.Poll {client;window_sec} ->
    (match with_admission t request.incarnation (fun () ->
      match B.register client with
      | Error error -> Error (refusal (B.registration_refusal_to_wire error))
      | Ok connected ->
        if not (List.exists (fun id -> Uuidm.equal id client.client_id) t.clients) then
          t.clients <- client.client_id :: t.clients;
        Ok connected) with
     | Error reply -> reply
     | Ok client -> waiting t ~disposition:W.Not_started (fun () ->
         match B.take_registered_command ~client ~window_sec with
         | Ok command ->
           let state_id=Digestif.SHA256.(to_hex (digest_string (Yojson.Safe.to_string (snapshot t)))) in
           W.Poll_result {command;state_id}
         | Error error -> refusal (B.registration_refusal_to_wire error)))
  | W.Deliver {client_id;id;payload} ->
    (match with_admission t request.incarnation (fun () -> B.deliver_result ~client_id ~id ~payload
      |> Result.map_error refusal) with
     | Error reply -> reply | Ok () -> W.Receipt)
  | W.Disconnect client_id ->
    (match with_admission t request.incarnation (fun () -> B.disconnect_client ~client_id
      |> Result.map_error refusal) with
     | Error reply -> reply | Ok () -> W.Receipt)
  | W.Issue {route;verb;actor;timeout_sec;only_if_idle} ->
    (match with_admission t request.incarnation (fun () ->
      match route with
      | B.Stagehand_route -> Error (refusal "Stagehand is not attached to this worker")
      | B.Automation_route when not t.automation -> Error (refusal "automation is not attached to this worker")
      | B.Live_route None -> Error (refusal "worker execution requires a selected clientId")
      | B.Live_route (Some _) | B.Automation_route ->
        B.resolve_target ~verb route |> Result.map_error (fun error -> W.Issue_result (Error error))) with
     | Error reply -> reply
     | Ok target -> waiting t ~disposition:W.Outcome_unknown (fun () ->
         W.Issue_result (if only_if_idle then
           match verb with
           | B.Page_document {tab_id} -> B.issue_document_if_idle ~target ~tab_id ~timeout_sec
           | B.Tabs_list|Page_read _|Page_downloads _|Page_capture _|Page_scene _|Page_interact _
           | Session_open _|Session_close|Session_status|Page_goto _|Page_elements _|Page_act _
           | Page_context _|Page_instruct _|Page_locate _|Page_extract _ ->
             Ok (B.Rejected_before_effect "idle admission supports document reads only")
         else B.issue_for_actor ~actor ~target ~verb ~timeout_sec)))
