module Wire = Browser_stagehand_wire

type attach_error =
  | Extension_path of string
  | Load_rejected of Browser_cdp.failure
  | Extension_id_mismatch of { expected : string; loaded : string }
  | Service_worker_absent
  | Malformed_reply of { method_ : string; detail : string }
  | Runtime_not_ready
  | Runtime_marker of string
  | Runtime_incompatible of { found : string; supported : int }
  | Init_unanswered of float
  | Init_failed of call_failure
  | Cdp of Browser_cdp.failure
  | Already_attached

and call_failure =
  | Not_attached
  | Detached
  | Connection_gone of string
  | Abandoned_call_pending
  | Not_delivered of string
  | Rejected of Wire.rpc_error
  | Lost of string

type event =
  | Runtime_ready of Wire.marker
  | Model_request_refused of { reason : string }
  | Model_failed of string
  | Unsupported_request of { method_ : string }
  | Unsupported_notification of { method_ : string }
  | Extension_log of Yojson.Safe.t option
  | Malformed_message of string
  | Unexpected_response of { id : int }
  | Cancelled_call_answered of { method_ : string; rejected : bool }
  | Abandoned_call_ended of { method_ : string; rejected : bool }
  | Abandoned_call_unanswered of { method_ : string; waited_s : float }
  | Reply_not_delivered of string
  | Malformed_cdp_event of { method_ : string; detail : string }
  | Worker_detached
  | Connection_ended of string

type model = Yojson.Safe.t -> (Yojson.Safe.t, Wire.rpc_error) result
type link = { cdp : Browser_cdp.t; worker : Browser_cdp.session_id }

(* [Attaching] is set when attach starts, so a second attach is refused.
   [Initialising] carries only [stagehand.init], which attach sends itself;
   the runtime is not ready for anything else until init answers. *)
type link_state =
  | Unattached
  | Attaching
  | Initialising of link
  | Attached of link
  | Worker_gone
  | Ended of string

type outgoing = Init of Wire.init | Operation of Wire.call

let method_name = function Init _ -> Wire.init_method | Operation call -> Wire.method_name call
let uses_model = function Init _ -> false | Operation call -> Wire.uses_model call

let encode ~id = function
  | Init init -> Wire.encode_init ~id init
  | Operation call -> Wire.encode_call ~id call
;;

type call_state =
  | Idle
  | In_flight of { id : int; outgoing : outgoing; ended : unit Eio.Promise.t; deadline_s : float option }
      (* [ended] resolves when the call finishes or is abandoned, which
         cancels a model answer still being computed for it. *)
  | Abandoned of { id : int; outgoing : outgoing; since : float }
      (* [since] is when the caller left, the start of [abandoned_answer_s]. *)

type t =
  { sw : Eio.Switch.t
  ; sleep : float -> unit
  ; now : unit -> float
  ; worker_wait_s : float
  ; init_answer_s : float
  ; abandoned_answer_s : float
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

let create ~sw ~clock ~worker_wait_s ~init_answer_s ~abandoned_answer_s ~model ~log =
  { sw
  ; sleep = Eio.Time.sleep clock
  ; now = (fun () -> Eio.Time.now clock)
  ; worker_wait_s
  ; init_answer_s
  ; abandoned_answer_s
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
  | Unattached | Attaching | Worker_gone | Ended _ -> None
;;

let fail_pending t failure =
  let waiting = Hashtbl.fold (fun _ resolver acc -> resolver :: acc) t.pending [] in
  Hashtbl.reset t.pending;
  List.iter (fun resolver -> Eio.Promise.resolve resolver (Error failure)) waiting
;;

let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None

let exception_text details =
  match Option.bind (field "exception" details) (field "description"), field "text" details with
  | Some (`String description), _ -> description
  | (Some _ | None), Some (`String text) -> text
  | (Some _ | None), (Some _ | None) -> "without a description"
;;

type delivery_failure =
  | Refused_delivery of string  (* the message did not reach the receiver *)
  | Delivery_unknown of string  (* the message may have reached it *)

(* Hands one message to the extension. It waits for a CDP reply, so it never
   runs on the fiber that delivers CDP frames. A receiver that threw may have
   acted on the message before throwing. *)
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
     | Some details -> Error (Delivery_unknown ("the extension's receiver threw: " ^ exception_text details)))
;;

(* The extension waits for every answer to its requests, and the call that
   made it ask waits on the extension, so an answer that did not arrive ends
   the session: the call fails now instead of waiting for good. *)
let send_reply t id result =
  match t.link with
  | Initialising link | Attached link ->
    (match deliver link (Wire.encode_reply ~id result) with
     | Ok () -> ()
     | Error (Refused_delivery detail | Delivery_unknown detail) ->
       t.log (Reply_not_delivered detail);
       let reason = "an answer to the extension was not delivered: " ^ detail in
       t.link <- Ended reason;
       fail_pending t (Lost reason))
  | Unattached | Attaching | Worker_gone -> t.log (Reply_not_delivered "no service worker to answer")
  | Ended reason -> t.log (Reply_not_delivered reason)
;;

(* Replies are sent from their own fibers: the fiber delivering CDP frames
   must not wait for a CDP reply. A cancelled or finished switch means the
   session is over: a fiber forked there would never send, so the reply is
   logged instead. *)
let fork t work =
  match Eio.Switch.get_error t.sw with
  | Some error -> t.log (Reply_not_delivered ("the session is over: " ^ Printexc.to_string error))
  | None -> Eio.Fiber.fork ~sw:t.sw work
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
  | In_flight { id = owner; outgoing; ended; deadline_s } when uses_model outgoing ->
    fork t (fun () ->
      (* The answer is sent only while the call that asked for it is still
         out; the call ending cancels the model. *)
      let outcome =
        Watched_work.run
          ~watcher:(fun () ->
            match deadline_s with
            | None ->
              Eio.Promise.await ended;
              `Call_over
            | Some deadline_s ->
              Eio.Fiber.first
                (fun () ->
                   Eio.Promise.await ended;
                   `Call_over)
                (fun () ->
                   t.sleep (max 0. (deadline_s -. t.now ()));
                   `Timed_out))
          (fun () -> `Answered (ask_model t params))
      in
      match outcome, t.calls with
      | `Answered result, In_flight { id = current; _ } when current = owner -> send_reply t id result
      | `Answered _, (Idle | In_flight _ | Abandoned _) | `Call_over, (Idle | In_flight _ | Abandoned _) ->
        refuse_model t id "the call that asked for the model is over"
      | `Timed_out, (Idle | In_flight _ | Abandoned _) ->
        refuse_model t id "the call that asked for the model reached its deadline")
  | In_flight _ -> refuse_model t id "the call in flight does not use the model"
  | Idle -> refuse_model t id "no call is in flight"
  | Abandoned _ -> refuse_model t id "the call that asked for the model was abandoned"
;;

let settle t id result =
  match t.calls with
  | Abandoned { id = abandoned; outgoing; since = _ } when abandoned = id ->
    t.calls <- Idle;
    t.log (Abandoned_call_ended { method_ = method_name outgoing; rejected = Result.is_error result })
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
  | Ok (Wire.Malformed_response { id = Wire.Int_id id; detail }) ->
    t.log (Malformed_message detail);
    settle t id (Error (Lost ("the extension answered malformed: " ^ detail)))
  | Ok (Wire.Response { id = Wire.String_id id; _ } | Wire.Malformed_response { id = Wire.String_id id; _ }) ->
    t.log (Malformed_message ("a response to id " ^ id ^ ", which masc never sends"))
  | Ok (Wire.Request (Wire.Llm_generate { id; params })) -> answer_model t id params
  | Ok (Wire.Request (Wire.Invalid_params { id; detail })) ->
    t.log (Malformed_message detail);
    fork t (fun () -> send_reply t id (Error { Wire.code = Wire.invalid_params; message = detail }))
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

let send t link outgoing =
  (* A caller cancelled before its turn sends nothing. *)
  Eio.Fiber.check ();
  t.next_id <- t.next_id + 1;
  let id = t.next_id in
  let reply, resolver = Eio.Promise.create () in
  let ended, end_call = Eio.Promise.create () in
  Hashtbl.replace t.pending id resolver;
  let deadline_s =
    match outgoing with
    | Init _ -> None
    | Operation call ->
      Option.map
        (fun timeout -> t.now () +. (float_of_int (Wire.timeout_ms timeout) /. 1000.))
        (Wire.sentence_timeout_of_call call)
  in
  t.calls <- In_flight { id; outgoing; ended; deadline_s };
  let over next =
    Hashtbl.remove t.pending id;
    t.calls <- next;
    Eio.Promise.resolve end_call ()
  in
  (* Delivery is not cancelled: a CDP command whose caller leaves ends the
     connection, and a cancelled delivery could not tell whether the
     extension has the call. A caller cancelled meanwhile leaves at the wait
     for the reply. *)
  match Eio.Cancel.protect (fun () -> deliver link (encode ~id outgoing)) with
  | exception exn ->
    over Idle;
    raise exn
  | Error (Refused_delivery detail) ->
    over Idle;
    Error (Not_delivered detail)
  | Error (Delivery_unknown detail) ->
    over Idle;
    Error (Lost detail)
  | Ok () ->
    (match Eio.Promise.await reply with
     | result ->
       over Idle;
       result
     | exception (Eio.Cancel.Cancelled _ as exn) ->
       (* A reply that arrived in the pass the caller was cancelled settled the
          call; only a call still without one is abandoned. *)
       (match Eio.Promise.peek reply with
        | Some result ->
          over Idle;
          t.log (Cancelled_call_answered
            { method_ = method_name outgoing; rejected = Result.is_error result })
        | None -> over (Abandoned { id; outgoing; since = t.now () }));
       raise exn)
;;

let with_slot t work =
  Eio.Semaphore.acquire t.slot;
  (* fun-protect-finally-ok: [Eio.Semaphore.release] does not suspend, and
     the slot must come back on return, exception and cancellation alike;
     the semaphore, unlike [Eio.Mutex], is not poisoned by an exception. *)
  Fun.protect ~finally:(fun () -> Eio.Semaphore.release t.slot) work
;;

(* The extension may be stuck on a call whose caller left, and the protocol
   cannot cancel it, so after [abandoned_answer_s] the session is given up
   on: this call and every later one are told it is gone, and a new session
   can start. *)
let give_up_on_abandoned t outgoing ~since =
  let method_ = method_name outgoing in
  let reason = Printf.sprintf "the abandoned %s call did not answer within %g s" method_ t.abandoned_answer_s in
  t.link <- Ended reason;
  t.log (Abandoned_call_unanswered { method_; waited_s = t.now () -. since });
  fail_pending t (Lost reason);
  Error (Connection_gone reason)
;;

let call t call =
  with_slot t (fun () ->
    match t.link, t.calls with
    | (Unattached | Attaching | Initialising _), (Idle | In_flight _ | Abandoned _) -> Error Not_attached
    | Worker_gone, (Idle | In_flight _ | Abandoned _) -> Error Detached
    | Ended reason, (Idle | In_flight _ | Abandoned _) -> Error (Connection_gone reason)
    | Attached _, Abandoned { outgoing; since; id = _ } when t.now () -. since >= t.abandoned_answer_s ->
      give_up_on_abandoned t outgoing ~since
    (* Behind the slot, a call still in flight is one whose caller left. *)
    | Attached _, (Abandoned _ | In_flight _) -> Error Abandoned_call_pending
    | Attached link, Idle -> send t link (Operation call))
;;

let send_init t link init =
  with_slot t (fun () ->
    match t.calls with
    | Idle -> send t link (Init init)
    | In_flight _ | Abandoned _ -> Error Abandoned_call_pending)
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

(* Runs [step] every [worker_poll_s] until it finds what it looks for, for at
   most [worker_wait_s]; [absent] is the answer when the wait runs out. The
   wait is checked between steps, never by cancelling one: a CDP command
   whose caller is cancelled ends the connection. *)
let poll_within_wait t ~absent step =
  let deadline = t.now () +. t.worker_wait_s in
  let rec poll () =
    match step () with
    | Ok (Some found) -> Ok found
    | Error _ as error -> error
    | Ok None ->
      let remaining = deadline -. t.now () in
      if remaining <= 0. then Error absent
      else (
        t.sleep (Float.min worker_poll_s remaining);
        poll ())
  in
  poll ()
;;

(* Looked for after the extension loaded, so a worker of an earlier load that
   the new one replaces is gone by the time one is found, unless it restarts
   in between, which then fails attach instead of attaching to it. *)
let await_worker t cdp ~extension_id =
  poll_within_wait t ~absent:Service_worker_absent (fun () -> find_worker cdp ~extension_id)
;;

(* One look at the runtime. A check that threw is reported as such: its
   result is then an empty object, which read as a marker would name a
   missing field instead of the cause. *)
let runtime_readiness link () =
  let* evaluated =
    cdp_step
      (Browser_cdp.command link.cdp ~session:link.worker "Runtime.evaluate"
         (`Assoc [ "expression", `String Wire.readiness_expression; "returnByValue", `Bool true ]))
  in
  match field "exceptionDetails" evaluated, Option.bind (field "result" evaluated) (field "value") with
  | Some details, (Some _ | None) -> Error (Runtime_marker ("the readiness check threw: " ^ exception_text details))
  | None, None -> Error (Runtime_marker "the readiness check returned no value")
  | None, Some value ->
    (match Wire.readiness_of_json value with
     | Ok (Wire.Ready marker) -> Ok (Some marker)
     | Ok Wire.Not_ready -> Ok None
     | Error detail -> Error (Runtime_marker detail))
;;

let initialise t link ~browser_cdp_url =
  let* marker = poll_within_wait t ~absent:Runtime_not_ready (runtime_readiness link) in
  let* major = Result.map_error (fun detail -> Runtime_marker detail) (Wire.protocol_major marker) in
  let* () =
    if major = Wire.supported_protocol_major then Ok ()
    else Error (Runtime_incompatible { found = marker.protocol_version; supported = Wire.supported_protocol_major })
  in
  t.log (Runtime_ready marker);
  (* The init reply has no deadline of its own. When this one runs out, the
     init is abandoned, and attach ends the session. *)
  Watched_work.run
    ~watcher:(fun () ->
      t.sleep t.init_answer_s;
      Error (Init_unanswered t.init_answer_s))
    (fun () ->
      Result.map_error (fun failure -> Init_failed failure)
        (send_init t link { Wire.client_version = Build_version.current; browser_cdp_url }))
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

let attach_incomplete = "attach did not complete"

(* A session attaches once: a failed attach may have loaded the extension or
   sent init. A worker or connection that went away during attach keeps the
   state that says so. *)
let attach t cdp ~extension_dir ~browser_cdp_url =
  match t.link with
  | Attaching | Initialising _ | Attached _ | Worker_gone | Ended _ -> Error Already_attached
  | Unattached ->
    t.link <- Attaching;
    (match attach_steps t cdp ~extension_dir ~browser_cdp_url with
     | exception exn ->
       (match t.link with
        | Unattached | Attaching | Initialising _ -> t.link <- Ended attach_incomplete
        | Attached _ | Worker_gone | Ended _ -> ());
       raise exn
     | attached ->
       (match attached, t.link with
        | Ok _, Initialising link -> t.link <- Attached link
        (* [Ok] comes from init, which runs only once the link is set. *)
        | Error _, (Unattached | Attaching | Initialising _) | Ok _, (Unattached | Attaching) ->
          t.link <- Ended attach_incomplete
        | (Ok _ | Error _), (Attached _ | Worker_gone | Ended _) -> ());
       attached)
;;
