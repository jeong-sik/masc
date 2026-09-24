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
  | Unsupported_request of { method_ : string }
  | Unsupported_notification of { method_ : string }
  | Extension_log of Yojson.Safe.t
  | Malformed_message of string
  | Reply_not_delivered of string
  | Malformed_cdp_event of { method_ : string; detail : string }
  | Worker_detached
  | Connection_ended of string

type model = Yojson.Safe.t -> (Yojson.Safe.t, Wire.rpc_error) result
type link = { cdp : Browser_cdp.t; worker : Browser_cdp.session_id }
type link_state = Unattached | Attached of link | Worker_gone | Ended of string

type call_state =
  | Idle
  | In_flight of { id : int; call : Wire.call }
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
  ; mutable expecting_worker : (string * string Eio.Promise.u) option
      (* The extension id whose service worker attach waits for, and where
         its target id goes. *)
  }

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
  ; expecting_worker = None
  }
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
  | Attached link ->
    (match deliver link (Wire.encode_reply ~id result) with
     | Ok () -> ()
     | Error (Refused_delivery detail | Delivery_unknown detail) -> t.log (Reply_not_delivered detail))
  | Unattached | Worker_gone -> t.log (Reply_not_delivered "no service worker to answer")
  | Ended reason -> t.log (Reply_not_delivered reason)
;;

let reply_later t id result = Eio.Fiber.fork ~sw:t.sw (fun () -> send_reply t id result)

let refuse_model t id reason =
  t.log (Model_request_refused { reason });
  reply_later t id (Error { Wire.code = Wire.host_refused; message = reason })
;;

let answer_model t id params =
  match t.calls with
  | In_flight { call; _ } when Wire.uses_model call ->
    Eio.Fiber.fork ~sw:t.sw (fun () -> send_reply t id (t.model params))
  | In_flight _ -> refuse_model t id "the call in flight does not use the model"
  | Idle -> refuse_model t id "no call is in flight"
  | Abandoned _ -> refuse_model t id "the call that asked for the model was abandoned"
;;

let settle t id result =
  match t.calls with
  | Abandoned { id = abandoned; _ } when abandoned = id -> t.calls <- Idle
  | Abandoned _ | Idle | In_flight _ ->
    (match Hashtbl.find_opt t.pending id with
     | Some resolver ->
       Hashtbl.remove t.pending id;
       Eio.Promise.resolve resolver result
     | None -> t.log (Malformed_message (Printf.sprintf "a response to call %d, which nobody waits for" id)))
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
    reply_later t id (Error { Wire.code = Wire.method_not_found; message = "masc does not serve " ^ method_ })
  | Ok (Wire.Notification (Wire.Log json)) -> t.log (Extension_log json)
  | Ok (Wire.Notification (Wire.Page_event _)) -> ()
  | Ok (Wire.Notification (Wire.Unsupported_notification { method_ })) -> t.log (Unsupported_notification { method_ })
;;

let is_worker t session =
  match t.link with
  | Attached link -> String.equal link.worker session
  | Unattached | Worker_gone | Ended _ -> false
;;

let on_cdp_event t = function
  | Browser_cdp.Target_created { target_id; kind = Browser_cdp.Service_worker; url } ->
    (match t.expecting_worker with
     (* The extension id is the origin of its own pages, so the URL names
        which extension a worker belongs to. *)
     | Some (extension_id, found) when String.starts_with ~prefix:("chrome-extension://" ^ extension_id ^ "/") url ->
       t.expecting_worker <- None;
       Eio.Promise.resolve found target_id
     | Some _ | None -> ())
  | Browser_cdp.Target_created { kind = Browser_cdp.Page | Browser_cdp.Other_kind _; _ } -> ()
  | Browser_cdp.Binding_called { session = Some session; name; payload }
    when is_worker t session && String.equal name Wire.send_to_host_binding -> handle_message t payload
  | Browser_cdp.Binding_called _ -> ()
  | Browser_cdp.Target_detached { session } when is_worker t session ->
    t.link <- Worker_gone;
    t.log Worker_detached;
    fail_pending t (Lost "the service worker went away")
  | Browser_cdp.Target_detached _ | Browser_cdp.Target_destroyed _ | Browser_cdp.Unobserved _ -> ()
  | Browser_cdp.Malformed_event { method_; detail } -> t.log (Malformed_cdp_event { method_; detail })
  | Browser_cdp.Connection_ended { reason } ->
    t.link <- Ended reason;
    t.log (Connection_ended reason);
    fail_pending t (Lost reason)
;;

let call t call =
  Eio.Semaphore.acquire t.slot;
  (* The slot is released on every exit, cancellation included; the
     semaphore is not poisoned by an exception the way [Eio.Mutex] is. *)
  Fun.protect ~finally:(fun () -> Eio.Semaphore.release t.slot) (fun () ->
    match t.link, t.calls with
    | Unattached, (Idle | In_flight _ | Abandoned _) -> Error Not_attached
    | Worker_gone, (Idle | In_flight _ | Abandoned _) -> Error Detached
    | Ended reason, (Idle | In_flight _ | Abandoned _) -> Error (Connection_gone reason)
    (* Behind the slot, a call still in flight is one whose caller left. *)
    | Attached _, (Abandoned _ | In_flight _) -> Error Abandoned_call_pending
    | Attached link, Idle ->
      t.next_id <- t.next_id + 1;
      let id = t.next_id in
      let reply, resolver = Eio.Promise.create () in
      Hashtbl.replace t.pending id resolver;
      t.calls <- In_flight { id; call };
      let finish () =
        Hashtbl.remove t.pending id;
        t.calls <- Idle
      in
      (match
         (match deliver link (Wire.encode_call ~id call) with
          | Error (Refused_delivery detail) -> Error (Not_delivered detail)
          | Error (Delivery_unknown detail) -> Error (Lost detail)
          | Ok () -> Eio.Promise.await reply)
       with
       | result ->
         finish ();
         result
       | exception (Eio.Cancel.Cancelled _ as exn) ->
         Hashtbl.remove t.pending id;
         t.calls <- Abandoned { id; call };
         raise exn))
;;

let ( let* ) = Result.bind

let cdp_step result = Result.map_error (fun failure -> Cdp failure) result

let string_in ~method_ key json =
  match field key json with
  | Some (`String value) -> Ok value
  | Some _ | None -> Error (Malformed_reply { method_; detail = key ^ " is not a string" })
;;

let await_worker t found =
  Watched_work.run
    ~watcher:(fun () ->
      t.sleep t.worker_wait_s;
      Error Service_worker_absent)
    (fun () -> Ok (Eio.Promise.await found))
;;

let attach t cdp ~extension_dir ~browser_cdp_url =
  let* real_path =
    match Unix.realpath extension_dir with
    | path -> Ok path
    | exception Unix.Unix_error (error, _, _) -> Error (Extension_path (Unix.error_message error))
  in
  let expected = Wire.extension_id_of_real_path real_path in
  let worker_target, found = Eio.Promise.create () in
  (* Set before discovery starts: Chrome reports existing targets as it
     starts discovering, and the extension's worker may be one of them. *)
  t.expecting_worker <- Some (expected, found);
  let located =
    let* _ = cdp_step (Browser_cdp.command cdp "Target.setDiscoverTargets" (`Assoc [ "discover", `Bool true ])) in
    let* loaded =
      Result.map_error (fun failure -> Load_rejected failure)
        (Browser_cdp.command cdp "Extensions.loadUnpacked" (`Assoc [ "path", `String real_path ]))
    in
    let* loaded_id = string_in ~method_:"Extensions.loadUnpacked" "id" loaded in
    let* () =
      if String.equal loaded_id expected then Ok () else Error (Extension_id_mismatch { expected; loaded = loaded_id })
    in
    await_worker t worker_target
  in
  t.expecting_worker <- None;
  let* target_id = located in
  let* attached =
    cdp_step (Browser_cdp.command cdp "Target.attachToTarget" (`Assoc [ "targetId", `String target_id; "flatten", `Bool true ]))
  in
  let* worker = string_in ~method_:"Target.attachToTarget" "sessionId" attached in
  let* _ = cdp_step (Browser_cdp.command cdp ~session:worker "Runtime.enable" (`Assoc [])) in
  let* _ =
    cdp_step
      (Browser_cdp.command cdp ~session:worker "Runtime.addBinding" (`Assoc [ "name", `String Wire.send_to_host_binding ]))
  in
  t.link <- Attached { cdp; worker };
  let* evaluated =
    cdp_step
      (Browser_cdp.command cdp ~session:worker "Runtime.evaluate"
         (`Assoc
            [ "expression", `String Wire.readiness_expression; "awaitPromise", `Bool true; "returnByValue", `Bool true ]))
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
    (call t
       (Wire.Init { protocol_version = marker.protocol_version; client_version = Build_version.current; browser_cdp_url }))
;;
