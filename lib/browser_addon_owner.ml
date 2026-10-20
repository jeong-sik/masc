module B = Browser_lane
module W = Browser_addon_wire

type phase = Serving | Retired
type t = {
  incarnation : string;
  gate : Eio.Mutex.t;
  mutable phase : phase;
  mutable clients : B.client_id list;
  retired : unit Eio.Promise.t;
  retire : unit Eio.Promise.u;
}
let process_claimed = Atomic.make false
let create ~incarnation =
  match B.client_id_of_string incarnation with
  | Error message -> Error message
  | Ok _ ->
    if not (Atomic.compare_and_set process_claimed false true) then
      Error "a browser owner already exists in this process"
    else
      let retired, retire = Eio.Promise.create () in
      let t = {incarnation;gate=Eio.Mutex.create ();phase=Serving;clients=[];retired;retire} in
      B.install_activity_observer (Some (fun lane -> match t.phase,lane with
        | Serving,B.Lane_name.Live -> B.Enabled
        | (Serving,(B.Lane_name.Automation|B.Lane_name.Stagehand)) | Retired,_ -> B.Disabled));
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
  "owned_backends",`String "unavailable"]
let revoke t =
  Eio.Mutex.use_rw ~protect:true t.gate (fun () ->
    match t.phase with
    | Retired -> ()
    | Serving ->
      t.phase <- Retired;
      Eio.Promise.resolve t.retire ();
      List.iter (fun client_id -> ignore (B.disconnect_client ~client_id)) t.clients;
      t.clients <- [])
let waiting t ~disposition run =
  Watched_work.run run ~watcher:(fun () ->
    Eio.Promise.await t.retired;
    refusal ~disposition "browser worker retired during the request")
let dispatch t (request : W.request) =
  match request.command with
  | W.Snapshot ->
    (match with_admission t request.incarnation (fun () -> Ok (snapshot t)) with
     | Error reply -> reply | Ok value -> W.Snapshot_result value)
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
         | Ok command -> W.Poll_result command
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
      | B.Automation_route | B.Stagehand_route ->
        Error (refusal "owned browser backends are not attached to this worker")
      | B.Live_route None -> Error (refusal "worker execution requires a selected clientId")
      | B.Live_route (Some _) ->
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
