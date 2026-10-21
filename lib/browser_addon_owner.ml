module B = Browser_lane
module W = Browser_addon_wire

type phase = Serving | Retired
type cleanup = (unit, string) result Eio.Lazy.t
type t = {
  incarnation : string;
  gate : Eio.Mutex.t;
  mutable phase : phase;
  mutable clients : B.client_id list;
  mutable automation : cleanup option;
  mutable stagehand : cleanup option;
  mutable live : cleanup option;
  mutable models : Browser_addon_models.t option;
  mutable uploads : Browser_addon_uploads.t option;
  mutable downloads : Browser_addon_downloads.t option;
  retired : unit Eio.Promise.t;
  retire : unit Eio.Promise.u;
}
let process_claimed = Atomic.make false
let incarnation t = t.incarnation
let is_retired t = match t.phase with Serving -> false | Retired -> true
let create ~incarnation =
  match B.client_id_of_string incarnation with
  | Error message -> Error message
  | Ok _ ->
    if not (Atomic.compare_and_set process_claimed false true) then
      Error "a browser owner already exists in this process"
    else
      let retired, retire = Eio.Promise.create () in
      let t = {incarnation;gate=Eio.Mutex.create ();phase=Serving;clients=[];automation=None;stagehand=None;live=None;models=None;uploads=None;downloads=None;retired;retire} in
      B.install_activity_observer (Some (fun lane -> match t.phase,lane with
        | Serving,B.Lane_name.Live -> B.Enabled
        | Serving,B.Lane_name.Automation -> if Option.is_some t.automation then B.Enabled else B.Disabled
        | Serving,B.Lane_name.Stagehand -> if Option.is_some t.stagehand then B.Enabled else B.Disabled
        | Retired,(B.Lane_name.Live|Automation|Stagehand) -> B.Disabled));
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
let attach_uploads t uploads =
  Eio.Mutex.use_rw ~protect:true t.gate (fun () -> match t.phase,t.uploads with
    | Retired,_ -> Error "browser owner is retired"
    | Serving,Some _ -> Error "browser upload broker is already attached"
    | Serving,None -> t.uploads<-Some uploads;Ok ())
let admitted_uploads t incarnation = with_admission t incarnation (fun () ->
  match t.uploads with Some uploads -> Ok uploads
    | None -> Error (refusal "browser upload broker is unavailable"))
let cleanup_uploads t = match t.uploads with
  | None -> Ok ()
  | Some uploads -> Eio_unix.run_in_systhread (fun () -> Browser_addon_uploads.cleanup uploads)
let attach_downloads t downloads =
  Eio.Mutex.use_rw ~protect:true t.gate (fun () -> match t.phase,t.downloads with
    | Retired,_ -> Error "browser owner is retired"
    | Serving,Some _ -> Error "browser download broker is already attached"
    | Serving,None -> t.downloads<-Some downloads;Ok ())
let publish_download t path = match t.phase,t.downloads with
  | Retired,_ -> Error "browser download broker is retired"
  | Serving,None -> Error "browser download broker is unavailable"
  | Serving,Some downloads -> Browser_addon_downloads.publish downloads path
let cleanup_downloads t = match t.downloads with
  | None -> Ok ()
  | Some downloads -> Eio_unix.run_in_systhread (fun () -> Browser_addon_downloads.cleanup downloads)
let admitted_models t =
  Eio.Mutex.use_rw ~protect:true t.gate (fun () -> match t.phase,t.models with
    | Retired,_ -> Error Browser_addon_models.Retired
    | Serving,None -> Error (Browser_addon_models.Output_disabled "model broker")
    | Serving,Some models -> Ok models)
let generate t request = Result.bind (admitted_models t) (fun models -> Browser_addon_models.request models request)
let model_output t ~name = match admitted_models t with
  | Error _ -> None
  | Ok models -> Browser_addon_models.output models ~name
let owned_cleanup backend cleanup =
  Eio.Lazy.from_fun ~cancel:`Protect (fun () -> match cleanup () with
    | result -> result
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception _ -> Error (backend ^ " backend cleanup raised; settlement is unconfirmed"))
let attach_automation t ~locate ~execute ~session ~document ~cleanup =
  Eio.Mutex.use_rw ~protect:true t.gate (fun () -> match t.phase,t.automation with
    | Retired,_ -> Error "browser owner is retired"
    | Serving,Some _ -> Error "automation backend is already attached"
    | Serving,None ->
      B.install_automation_executor ~locate (Some execute);
      B.install_server_session_observer B.Server_automation (Some session);
      B.install_automation_document_observer (Some document);
      t.automation <- Some (owned_cleanup "automation" cleanup);Ok ())
let attach_stagehand t ~models ~execute ~session ~cleanup =
  Eio.Mutex.use_rw ~protect:true t.gate (fun () -> match t.phase,t.stagehand with
    | Retired,_ -> Error "browser owner is retired"
    | Serving,Some _ -> Error "Stagehand backend is already attached"
    | Serving,None ->
      B.install_stagehand_executor ~models (Some execute);
      B.install_server_session_observer B.Server_stagehand (Some session);
      t.stagehand <- Some (owned_cleanup "Stagehand" cleanup);Ok ())
let attach_live t ~client_id ~cleanup =
  Eio.Mutex.use_rw ~protect:true t.gate (fun () -> match t.phase,t.live with
    | Retired,_ -> Error "browser owner is retired"
    | Serving,Some _ -> Error "owned live BiDi backend is already attached"
    | Serving,None ->
      if not (List.mem client_id t.clients) then Error "live BiDi client was not registered by this owner"
      else match List.find_opt (fun (client:B.client_info) -> client.client_id=client_id) (B.active_clients ()) with
        | Some {transport=B.Webdriver_bidi;_} -> t.live<-Some (owned_cleanup "live BiDi" cleanup);Ok ()
        | None | Some {transport=B.Web_extension;_} -> Error "owned live client is not an active BiDi connection")
let revoke t =
  Eio.Mutex.use_rw ~protect:true t.gate (fun () ->
    match t.phase with
    | Retired -> ()
    | Serving ->
      t.phase <- Retired;
      Option.iter Browser_addon_models.retire t.models;
      Option.iter Browser_addon_uploads.revoke t.uploads;
      Option.iter Browser_addon_downloads.revoke t.downloads;
      B.install_automation_executor None;
      B.install_server_session_observer B.Server_automation None;
      B.install_automation_document_observer None;
      B.install_stagehand_executor None;
      B.install_server_session_observer B.Server_stagehand None;
      Eio.Promise.resolve t.retire ();
      List.iter (fun client_id -> ignore (B.disconnect_client ~client_id)) t.clients;
      t.clients <- [])
let cleanup t =
  (* Never hold admission while joining resources. A failing backend cannot skip
     stopping the other, and a cancelled Retire cannot abandon an owned cleanup.
     The lazy values retain the original result rather than replaying teardown. *)
  Eio.Cancel.protect (fun () ->
    let settle = function None -> Ok () | Some cleanup -> Eio.Lazy.force cleanup in
    let live,(automation,stagehand) = Eio.Fiber.pair
      (fun () -> settle t.live)
      (fun () -> Eio.Fiber.pair (fun () -> settle t.automation) (fun () -> settle t.stagehand)) in
    let uploads=cleanup_uploads t in
    let downloads=match t.downloads with
      | None -> Ok ()
      | Some downloads -> (match live,automation,stagehand with
          | Ok (),Ok (),Ok () -> cleanup_downloads t
          | Error _,_,_ | Ok (),Error _,_ | Ok (),Ok (),Error _ ->
              Eio_unix.run_in_systhread (fun () -> Browser_addon_downloads.abandon downloads)) in
    let errors=List.filter_map (function Ok () -> None | Error detail -> Some detail)
      [live;automation;stagehand;uploads;downloads] in
    match errors with [] -> W.Receipt
      | _::_ -> refusal ~disposition:W.Outcome_unknown (String.concat "; " errors))
let waiting t ~disposition run =
  Watched_work.run run ~watcher:(fun () ->
    Eio.Promise.await t.retired;
    refusal ~disposition "browser worker retired during the request")
let bind_downloads t ~actor ~route ~verb answer = match verb,answer with
  | B.Page_downloads _,Ok (B.Answered (`Assoc fields)) ->
      (match actor,t.downloads,List.assoc_opt "ok" fields,List.assoc_opt "data" fields with
       | Some actor,Some downloads,Some (`Bool true),Some data ->
           (match Eio_unix.run_in_systhread (fun () -> Browser_addon_downloads.bind downloads ~actor ~route ~verb data) with
            | Ok data -> Ok (B.Answered (`Assoc (List.map (fun (key,value) -> key,(if key="data" then data else value)) fields)))
            | Error detail -> Ok (B.Refused ("download transfer preparation failed: " ^ detail)))
       | (Some _|None),(Some _|None),(Some _|None),(Some _|None) -> answer)
  | (B.Tabs_list|Page_read _|Page_document _|Page_downloads _|Page_capture _|Page_scene _|Page_interact _
    |Session_open _|Session_close|Session_status|Page_goto _|Page_elements _|Page_act _
    |Page_context _|Page_instruct _|Page_locate _|Page_extract _),
    (Ok (B.Answered _|Lane_absent|Timed_out|Refused _|Rejected_before_effect _)|Error _) -> answer
type upload_admission = Ordinary | Scoped_upload
let issue t ~incarnation ~upload_admission ~route ~verb ~actor ~timeout_sec ~only_if_idle =
  let allowed=match verb,upload_admission with
    | B.Page_downloads _,(Ordinary|Scoped_upload) when Option.is_none actor || Option.is_none t.downloads ->
        Error (refusal "downloads require the original host caller and attached artifact broker")
    | B.Page_act (B.Action.On_tab {interaction=B.Action.Upload _;_}),Ordinary ->
        Error (refusal "upload requires its private host snapshot grant")
    | (B.Tabs_list|Page_read _|Page_document _|Page_downloads _|Page_capture _|Page_scene _|Page_interact _
      |Session_open _|Session_close|Session_status|Page_goto _|Page_elements _
      |Page_act (Open_tab _|On_tab {interaction=Click _|Fill _|Press _|Scroll _|Select _|Close_tab|Back|Forward|Reload|Accept_dialog _|Dismiss_dialog;_})
      |Page_context _|Page_instruct _|Page_locate _|Page_extract _),(Ordinary|Scoped_upload)
    | Page_act (On_tab {interaction=Upload _;_}),Scoped_upload -> Ok () in
  match allowed with Error reply -> reply | Ok () ->
    (match with_admission t incarnation (fun () ->
      match route with
      | B.Stagehand_route when Option.is_none t.stagehand -> Error (refusal "Stagehand is not attached to this worker")
      | B.Automation_route when Option.is_none t.automation -> Error (refusal "automation is not attached to this worker")
      | B.Live_route None -> Error (refusal "worker execution requires a selected clientId")
      | B.Live_route (Some _) | B.Automation_route | B.Stagehand_route ->
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
         else B.issue_for_actor ~actor ~target ~verb ~timeout_sec
         |> bind_downloads t ~actor ~route ~verb)))

let dispatch_upload t ~id ~actor ~route ~verb =
  match admitted_uploads t t.incarnation with
  | Error reply -> reply
  | Ok uploads ->
    match Browser_addon_uploads.with_claim uploads ~id ~actor ~route ~verb (fun verb ->
      issue t ~incarnation:t.incarnation ~upload_admission:Scoped_upload ~route ~verb
        ~actor:(Some actor)
        ~timeout_sec:(B.reply_timeout_sec verb)
        ~only_if_idle:false) with
    | Ok reply -> reply | Error detail -> refusal detail

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
    else (revoke t;cleanup t)
  | W.Snapshot ->
    (match with_admission t request.incarnation (fun () -> Ok (snapshot t)) with
     | Error reply -> reply | Ok value -> W.Snapshot_result value)
  | W.Upload_stage {id;actor;route;verb} ->
    (match admitted_uploads t request.incarnation with
     | Error reply -> reply
     | Ok uploads ->
       match Eio_unix.run_in_systhread (fun () -> Browser_addon_uploads.stage uploads ~id ~actor ~route ~verb) with
       | Ok () -> W.Receipt | Error detail -> refusal detail)
  | W.Upload_discard id ->
    (match admitted_uploads t request.incarnation with
     | Error reply -> reply
     | Ok uploads -> Eio_unix.run_in_systhread (fun () -> Browser_addon_uploads.discard uploads ~id);W.Receipt)
  | W.Download_claim {id;actor;route;verb} ->
    (match with_admission t request.incarnation (fun () ->
      match t.downloads with Some downloads -> Ok downloads
      | None -> Error (refusal "browser download broker is unavailable")) with
     | Error reply -> reply
     | Ok downloads -> (match Eio_unix.run_in_systhread (fun () -> Browser_addon_downloads.claim downloads ~id ~actor ~route ~verb) with
         | Ok claim -> W.Download_reply claim | Error detail -> refusal detail))
  | W.Download_commit {id;actor;route;verb;receipt} ->
    if request.incarnation<>t.incarnation then refusal "wrong browser worker incarnation"
    else (match t.downloads with
      | None -> refusal "browser download broker is unavailable"
      | Some downloads -> (match Eio_unix.run_in_systhread (fun () ->
          Browser_addon_downloads.commit downloads ~id ~actor ~route ~verb ~receipt) with
          | Ok () -> W.Receipt | Error detail -> refusal ~disposition:W.Outcome_unknown detail))
  | W.Download_release {id;actor;route;verb} ->
    if request.incarnation<>t.incarnation then refusal "wrong browser worker incarnation"
    else (match t.downloads with
      | None -> refusal "browser download broker is unavailable"
      | Some downloads -> (match Eio_unix.run_in_systhread (fun () ->
          Browser_addon_downloads.release downloads ~id ~actor ~route ~verb) with
          | Ok () -> W.Receipt | Error detail -> refusal ~disposition:W.Outcome_unknown detail))
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
    issue t ~incarnation:request.incarnation ~upload_admission:Ordinary
      ~route ~verb ~actor ~timeout_sec ~only_if_idle
