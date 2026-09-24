module Wire = Browser_stagehand_wire

type attach_error =
  | Extension_path of string
  | Load_rejected of Browser_cdp.failure
  | Extension_id_mismatch of { expected : string; loaded : string }
  | Service_worker_absent
  | Malformed_reply of { method_ : string; detail : string }
  | Runtime_marker of string
  | Runtime_incompatible of { found : string; supported : int }
  | Init_failed of call_failure
  | Cdp of Browser_cdp.failure

and call_failure =
  | Not_attached
  | Detached
  | Connection_gone of string
  | Abandoned_call_pending
  | Not_delivered of string
  | Rejected of Wire.rpc_error
  | Lost of string

type event =
  | Model_request_refused of { reason : string }
  | Model_failed of string
  | Unsupported_request of { method_ : string }
  | Unsupported_notification of { method_ : string }
  | Extension_log of Yojson.Safe.t option
  | Malformed_message of string
  | Unexpected_response of { id : int }
  | Abandoned_call_ended of { method_ : string; rejected : bool }
  | Reply_not_delivered of string
  | Malformed_cdp_event of { method_ : string; detail : string }
  | Worker_detached
  | Connection_ended of string

type model = Yojson.Safe.t -> (Yojson.Safe.t, Wire.rpc_error) result
type link = { cdp : Browser_cdp.t; worker : Browser_cdp.session_id }

(* [Initialising] admits only [stagehand.init]; the runtime is not ready for
   anything else until init answers. *)
type link_state = Unattached | Initialising of link | Attached of link | Worker_gone | Ended of string

type call_state =
  | Idle
  | In_flight of { id : int; call : Wire.call; ended : unit Eio.Promise.t }
      (* [ended] resolves when the call finishes or is abandoned, which
         cancels a model answer still being computed for it. *)
  | Abandoned of { id : int; call : Wire.call }

type t =
  { sw : Eio.Switch.t
  ; sleep : float -> unit
  ; worker_wait_s : float
  ; model : model
  ; log : event -> unit
  ; slot : Eio.Semaphore.t
  ; pending : (int, (Yojson.Safe.t, call_failure) result Eio.Promise.u) Hashtbl.t
  ; mutable next_id : int
  ; mutable link : link_state
  ; mutable calls : call_state
  }

(* The service worker is looked for this often after the extension loads; it
   appeared within half a second in the runs of 2026-09-24. *)
let worker_poll_s = 0.1

let create ~sw ~clock ~worker_wait_s ~model ~log =
  { sw
  ; sleep = Eio.Time.sleep clock
  ; worker_wait_s
  ; model
  ; log
  ; slot = Eio.Semaphore.make 1
  ; pending = Hashtbl.create 4
  ; next_id = 0
  ; link = Unattached
  ; calls = Idle
  }
;;

let live_link = function
  | Initialising link | Attached link -> Some link
  | Unattached | Worker_gone | Ended _ -> None
;;

let fail_pending t failure =
  let waiting = Hashtbl.fold (fun _ resolver acc -> resolver :: acc) t.pending [] in
  Hashtbl.reset t.pending;
  List.iter (fun resolver -> Eio.Promise.resolve resolver (Error failure)) waiting
;;

let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None

type delivery_failure =
  | Refused_delivery of string  (* the message did not reach the receiver *)
  | Delivery_unknown of string  (* the connection ended with the message out *)

(* Hands one message to the extension. It waits for a CDP reply, so it never
   runs on the fiber that delivers CDP frames. *)
let deliver link message =
  match
    Browser_cdp.command link.cdp ~session:link.worker "Runtime.evaluate"
      (`Assoc
         [ "expression", `String (Wire.deliver_expression message)
         ; "awaitPromise", `Bool false
         ; "returnByValue", `Bool true
         ])
  with
  | Error (Browser_cdp.Command_rejected { message; _ }) -> Error (Refused_delivery ("Runtime.evaluate rejected: " ^ message))
  | Error (Browser_cdp.Connection_lost reason) -> Error (Delivery_unknown reason)
  | Ok evaluated ->
    (match field "exceptionDetails" evaluated with
     | None -> Ok ()
     | Some _ -> Error (Refused_delivery "the extension's receiver threw"))
;;

let send_reply t id result =
  match t.link with
  | Initialising link | Attached link ->
    (match deliver link (Wire.encode_reply ~id result) with
     | Ok () -> ()
     | Error (Refused_delivery detail | Delivery_unknown detail) -> t.log (Reply_not_delivered detail))
  | Unattached | Worker_gone -> t.log (Reply_not_delivered "no service worker to answer")
  | Ended reason -> t.log (Reply_not_delivered reason)
;;

(* Replies are sent from their own fibers: the fiber delivering CDP frames
   must not wait for a CDP reply. A finished switch means the session is
   over, so the reply is only logged. *)
let fork t work =
  match Eio.Fiber.fork ~sw:t.sw work with
  | () -> ()
  | exception Invalid_argument detail -> t.log (Reply_not_delivered ("the session is over: " ^ detail))
;;

let refusal reason = Error { Wire.code = Wire.host_refused; message = reason }

let refuse_model t id reason =
  t.log (Model_request_refused { reason });
  fork t (fun () -> send_reply t id (refusal reason))
;;

(* The model function is the host's own code at a fault boundary: an
   exception from it refuses this request instead of failing the session's
   switch. Cancellation passes through. *)
let ask_model t params =
  match t.model params with
  | result -> result
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    let detail = Printexc.to_string exn in
    t.log (Model_failed detail);
    refusal ("the model failed: " ^ detail)
;;

let answer_model t id params =
  match t.calls with
  | In_flight { id = owner; call; ended } when Wire.uses_model call ->
    fork t (fun () ->
      (* The answer is sent only while the call that asked for it is still
         out; the call ending cancels the model. *)
      let outcome =
        Watched_work.run
          ~watcher:(fun () ->
            Eio.Promise.await ended;
            `Call_over)
          (fun () -> `Answered (ask_model t params))
      in
      match outcome, t.calls with
      | `Answered result, In_flight { id = current; _ } when current = owner -> send_reply t id result
      | `Answered _, (Idle | In_flight _ | Abandoned _) | `Call_over, (Idle | In_flight _ | Abandoned _) ->
        refuse_model t id "the call that asked for the model is over")
  | In_flight _ -> refuse_model t id "the call in flight does not use the model"
  | Idle -> refuse_model t id "no call is in flight"
  | Abandoned _ -> refuse_model t id "the call that asked for the model was abandoned"
;;

let settle t id result =
  match t.calls with
  | Abandoned { id = abandoned; call } when abandoned = id ->
    t.calls <- Idle;
    t.log (Abandoned_call_ended { method_ = Wire.method_name call; rejected = Result.is_error result })
  | Abandoned _ | Idle | In_flight _ ->
    (match Hashtbl.find_opt t.pending id with
     | Some resolver ->
       Hashtbl.remove t.pending id;
       Eio.Promise.resolve resolver result
     | None -> t.log (Unexpected_response { id }))
;;

let handle_message t payload =
  match Wire.decode payload with
  | Error detail -> t.log (Malformed_message detail)
  | Ok (Wire.Response { id = Wire.Int_id id; result }) ->
    settle t id (Result.map_error (fun error -> Rejected error) result)
  | Ok (Wire.Response { id = Wire.String_id id; _ }) ->
    t.log (Malformed_message ("a response to id " ^ id ^ ", which masc never sends"))
  | Ok (Wire.Request (Wire.Llm_generate { id; params })) -> answer_model t id params
  | Ok (Wire.Request (Wire.Unsupported_request { id; method_ })) ->
    t.log (Unsupported_request { method_ });
    fork t (fun () ->
      send_reply t id (Error { Wire.code = Wire.method_not_found; message = "masc does not serve " ^ method_ }))
  | Ok (Wire.Notification (Wire.Log params)) -> t.log (Extension_log params)
  | Ok (Wire.Notification (Wire.Page_event _)) -> ()
  | Ok (Wire.Notification (Wire.Unsupported_notification { method_ })) -> t.log (Unsupported_notification { method_ })
;;

let is_worker t session =
  match live_link t.link with
  | Some link -> String.equal link.worker session
  | None -> false
;;

let on_cdp_event t = function
  | Browser_cdp.Binding_called { session = Some session; name; payload }
    when is_worker t session && String.equal name Wire.send_to_host_binding -> handle_message t payload
  | Browser_cdp.Binding_called _ -> ()
  | Browser_cdp.Target_detached { session } when is_worker t session ->
    t.link <- Worker_gone;
    t.log Worker_detached;
    fail_pending t (Lost "the service worker went away")
  | Browser_cdp.Target_created _ | Browser_cdp.Target_detached _ | Browser_cdp.Target_destroyed _
  | Browser_cdp.Unobserved _ -> ()
  | Browser_cdp.Malformed_event { method_; detail } -> t.log (Malformed_cdp_event { method_; detail })
  | Browser_cdp.Connection_ended { reason } ->
    t.link <- Ended reason;
    t.log (Connection_ended reason);
    fail_pending t (Lost reason)
;;

let is_init = function
  | Wire.Init _ -> true
  | Wire.Close | Wire.Act _ | Wire.Observe _ | Wire.Extract _ | Wire.Context_pages | Wire.Context_active_page
  | Wire.Page_goto _ | Wire.Page_screenshot _ | Wire.Page_evaluate _ -> false
;;

let send_call t link call =
  (* A caller cancelled before its turn sends nothing. *)
  Eio.Fiber.check ();
  t.next_id <- t.next_id + 1;
  let id = t.next_id in
  let reply, resolver = Eio.Promise.create () in
  let ended, end_call = Eio.Promise.create () in
  Hashtbl.replace t.pending id resolver;
  t.calls <- In_flight { id; call; ended };
  let finish () =
    Hashtbl.remove t.pending id;
    t.calls <- Idle;
    Eio.Promise.resolve end_call ()
  in
  match
    (match deliver link (Wire.encode_call ~id call) with
     | Error (Refused_delivery detail) -> Error (Not_delivered detail)
     | Error (Delivery_unknown detail) -> Error (Lost detail)
     | Ok () -> Eio.Promise.await reply)
  with
  | result ->
    finish ();
    result
  | exception (Eio.Cancel.Cancelled _ as exn) ->
    (* A reply that arrived in the pass the caller was cancelled settled the
       call; only a call still without one is abandoned. *)
    (match Eio.Promise.peek reply with
     | Some _ -> finish ()
     | None ->
       Hashtbl.remove t.pending id;
       t.calls <- Abandoned { id; call };
       Eio.Promise.resolve end_call ());
    raise exn
  | exception exn ->
    finish ();
    raise exn
;;

let call t call =
  Eio.Semaphore.acquire t.slot;
  (* fun-protect-finally-ok: [Eio.Semaphore.release] does not suspend, and
     the slot must come back on return, exception and cancellation alike;
     the semaphore, unlike [Eio.Mutex], is not poisoned by an exception. *)
  Fun.protect ~finally:(fun () -> Eio.Semaphore.release t.slot) (fun () ->
    match t.link, t.calls with
    | Unattached, (Idle | In_flight _ | Abandoned _) -> Error Not_attached
    | Worker_gone, (Idle | In_flight _ | Abandoned _) -> Error Detached
    | Ended reason, (Idle | In_flight _ | Abandoned _) -> Error (Connection_gone reason)
    (* Behind the slot, a call still in flight is one whose caller left. *)
    | (Initialising _ | Attached _), (Abandoned _ | In_flight _) -> Error Abandoned_call_pending
    | Initialising link, Idle -> if is_init call then send_call t link call else Error Not_attached
    | Attached link, Idle -> send_call t link call)
;;

let ( let* ) = Result.bind

let cdp_step result = Result.map_error (fun failure -> Cdp failure) result

let string_in ~method_ key json =
  match field key json with
  | Some (`String value) -> Ok value
  | Some _ | None -> Error (Malformed_reply { method_; detail = key ^ " is not a string" })
;;

(* An extension's pages, its service worker included, are served from the
   chrome-extension:// origin named by its id. *)
let belongs_to ~extension_id url =
  let uri = Uri.of_string url in
  Option.equal String.equal (Uri.scheme uri) (Some "chrome-extension")
  && Option.equal String.equal (Uri.host uri) (Some extension_id)
;;

let find_worker cdp ~extension_id =
  let* listed = cdp_step (Browser_cdp.command cdp "Target.getTargets" (`Assoc [])) in
  match field "targetInfos" listed with
  | Some (`List infos) ->
    Ok
      (List.find_map
         (fun info ->
           match Browser_cdp.target_info_of_json info with
           | Ok { Browser_cdp.target_id; kind = Browser_cdp.Service_worker; url } when belongs_to ~extension_id url ->
             Some target_id
           | Ok _ | Error _ -> None)
         infos)
  | Some _ | None -> Error (Malformed_reply { method_ = "Target.getTargets"; detail = "targetInfos is not a list" })
;;

(* Looked for after the extension loaded, so a worker of an earlier load that
   the new one replaces is gone by the time one is found, unless it restarts
   in between, which then fails attach instead of attaching to it. *)
let await_worker t cdp ~extension_id =
  Watched_work.run
    ~watcher:(fun () ->
      t.sleep t.worker_wait_s;
      Error Service_worker_absent)
    (fun () ->
      let rec poll () =
        match find_worker cdp ~extension_id with
        | Ok (Some target_id) -> Ok target_id
        | Ok None ->
          t.sleep worker_poll_s;
          poll ()
        | Error _ as error -> error
      in
      poll ())
;;

let initialise t link ~browser_cdp_url =
  let* evaluated =
    cdp_step
      (Browser_cdp.command link.cdp ~session:link.worker "Runtime.evaluate"
         (`Assoc [ "expression", `String Wire.readiness_expression; "awaitPromise", `Bool true; "returnByValue", `Bool true ]))
  in
  let* marker_json =
    match Option.bind (field "result" evaluated) (field "value") with
    | Some value -> Ok value
    | None -> Error (Runtime_marker "the readiness check returned no value")
  in
  let* marker = Result.map_error (fun detail -> Runtime_marker detail) (Wire.marker_of_json marker_json) in
  let* major = Result.map_error (fun detail -> Runtime_marker detail) (Wire.protocol_major marker) in
  let* () =
    if major = Wire.supported_protocol_major then Ok ()
    else Error (Runtime_incompatible { found = marker.protocol_version; supported = Wire.supported_protocol_major })
  in
  Result.map_error (fun failure -> Init_failed failure)
    (call t (Wire.Init { client_version = Build_version.current; browser_cdp_url }))
;;

let attach_steps t cdp ~extension_dir ~browser_cdp_url =
  let* real_path =
    match Unix.realpath extension_dir with
    | path -> Ok path
    | exception Unix.Unix_error (error, _, _) -> Error (Extension_path (Unix.error_message error))
  in
  let expected = Wire.extension_id_of_real_path real_path in
  let* loaded =
    Result.map_error (fun failure -> Load_rejected failure)
      (Browser_cdp.command cdp "Extensions.loadUnpacked" (`Assoc [ "path", `String real_path ]))
  in
  let* loaded_id = string_in ~method_:"Extensions.loadUnpacked" "id" loaded in
  let* () =
    if String.equal loaded_id expected then Ok () else Error (Extension_id_mismatch { expected; loaded = loaded_id })
  in
  let* target_id = await_worker t cdp ~extension_id:expected in
  let* attached =
    cdp_step (Browser_cdp.command cdp "Target.attachToTarget" (`Assoc [ "targetId", `String target_id; "flatten", `Bool true ]))
  in
  let* worker = string_in ~method_:"Target.attachToTarget" "sessionId" attached in
  let* _ = cdp_step (Browser_cdp.command cdp ~session:worker "Runtime.enable" (`Assoc [])) in
  let* _ =
    cdp_step
      (Browser_cdp.command cdp ~session:worker "Runtime.addBinding" (`Assoc [ "name", `String Wire.send_to_host_binding ]))
  in
  t.link <- Initialising { cdp; worker };
  initialise t { cdp; worker } ~browser_cdp_url
;;

(* A failed attach may have loaded the extension or sent init, so the session
   is not attached a second time. A worker or connection that went away
   during attach keeps the state that says so. *)
let attach t cdp ~extension_dir ~browser_cdp_url =
  let attached = attach_steps t cdp ~extension_dir ~browser_cdp_url in
  (match attached, t.link with
   | Ok _, Initialising link -> t.link <- Attached link
   | Error _, (Unattached | Initialising _) -> t.link <- Ended "attach did not complete"
   (* [Ok] comes from init, which runs only once the link is set. *)
   | Ok _, Unattached -> t.link <- Ended "attach did not complete"
   | (Ok _ | Error _), (Attached _ | Worker_gone | Ended _) -> ());
  attached
;;
