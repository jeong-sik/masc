(* A Stagehand session against a fake Chromium and a fake extension.

   The fake browser answers the CDP commands a session sends; the fake
   extension answers the JSON-RPC it receives through [Runtime.evaluate] and
   talks back through [Runtime.bindingCalled]. Frames go back to the
   connection from a separate fiber, as a socket reader would deliver them.

   The mock clock advances only when every fiber is blocked, so [settle]
   returns once the session, the reader and the fake have all run as far as
   they can. *)
open Alcotest
module Cdp = Masc.Browser_cdp
module Wire = Masc.Browser_stagehand_wire
module Session = Masc.Browser_stagehand_session

let obj fields = `Assoc fields
let str value = `String value
let to_s = Yojson.Safe.to_string
let worker = "W"
let deadline_s = 5.0

(* Shorter than every timer the session and the connection start (the 0.1 s
   worker poll, the deadlines above), so the clock reaches it only after all
   other fibers have blocked. *)
let settle_s = 0.001
let marker version = obj [ "protocolVersion", str version; "serverInfo", obj [ "name", str "stagehand"; "version", str "1.0.2" ] ]

(* An llm.generate answer in the protocol's LLMStructuredGenerateResult shape. *)
let model_answer =
  obj
    [ "role", str "assistant"
    ; "content", obj [ "type", str "text"; "text", str {|{"pick":"0-18"}|} ]
    ; "output_format", str "json_schema"
    ; "structured_content", obj [ "pick", str "0-18" ]
    ]
;;

type act_behaviour = Ask_the_model | Hold

type fake =
  { inbox : string Eio.Stream.t
  ; mutable loaded : string option
  ; mutable loaded_id : string option
  ; mutable listings_without_worker : int
  ; mutable marker : Yojson.Safe.t
  ; mutable looks_before_ready : int
  ; mutable readiness_throws : bool
  ; mutable act : act_behaviour
  ; mutable held_act : Yojson.Safe.t option
  ; mutable waiting_on_model : (Yojson.Safe.t * Yojson.Safe.t) option
  ; mutable answers_from_host : Yojson.Safe.t list
  }

let to_masc fake frame = Eio.Stream.add fake.inbox frame

let to_host fake message =
  to_masc fake
    (to_s
       (obj
          [ "method", str "Runtime.bindingCalled"
          ; "sessionId", str worker
          ; "params", obj [ "name", str Wire.send_to_host_binding; "payload", str (to_s message); "executionContextId", `Int 1 ]
          ]))
;;

let rpc_result id result = obj [ "jsonrpc", str "2.0"; "id", id; "result", result ]
let rpc_error id message = obj [ "jsonrpc", str "2.0"; "id", id; "error", obj [ "code", `Int (-32603); "message", str message ] ]
let rpc_request id method_ params = obj [ "jsonrpc", str "2.0"; "id", str id; "method", str method_; "params", params ]

let extension_receives fake message =
  let member = Yojson.Safe.Util.member in
  match member "method" message, member "id" message with
  | `String "stagehand.init", id ->
    to_host fake (rpc_result id (obj [ "initialized", `Bool true; "pages", `List [ obj [ "page_id", str "P"; "url", str "about:blank" ] ] ]))
  | `String "stagehand.act", id ->
    (match fake.act with
     | Hold -> fake.held_act <- Some id
     | Ask_the_model ->
       fake.waiting_on_model <- Some (str "g1", id);
       to_host fake (rpc_request "g1" "llm.generate" (obj [ "messages", `List [] ])))
  | `String "page.goto", id -> to_host fake (rpc_result id (obj [ "page", obj [ "page_id", str "P" ] ]))
  | `Null, id ->
    fake.answers_from_host <- message :: fake.answers_from_host;
    (match fake.waiting_on_model with
     | Some (model_id, act_id) when id = model_id ->
       fake.waiting_on_model <- None;
       (match member "result" message with
        | `Null -> to_host fake (rpc_error act_id "the model request was refused")
        | result -> to_host fake (rpc_result act_id (obj [ "success", `Bool true; "model", result ])))
     | Some _ | None -> ())
  | _ -> failf "the fake extension got %s" (to_s message)
;;

(* The delivered message sits where [deliver_expression] puts its argument:
   cut a probe expression around a known argument and read what is between. *)
let delivered expression =
  let placeholder = "MARK" in
  let probe = Wire.deliver_expression placeholder and quoted = to_s (str placeholder) in
  let rec find i =
    if i + String.length quoted > String.length probe then None
    else if String.equal (String.sub probe i (String.length quoted)) quoted then Some i
    else find (i + 1)
  in
  match find 0 with
  | None -> None
  | Some cut ->
    let prefix = String.sub probe 0 cut in
    let suffix = String.sub probe (cut + String.length quoted) (String.length probe - cut - String.length quoted) in
    if String.starts_with ~prefix expression && String.ends_with ~suffix expression then (
      let literal =
        String.sub expression (String.length prefix) (String.length expression - String.length prefix - String.length suffix)
      in
      match Yojson.Safe.from_string literal with
      | `String message -> Some (Yojson.Safe.from_string message)
      | _ -> None)
    else None
;;

let targets fake =
  let page = obj [ "targetId", str "P"; "type", str "page"; "url", str "about:blank" ] in
  match fake.loaded with
  | Some loaded when fake.listings_without_worker = 0 ->
    [ page; obj [ "targetId", str "SW"; "type", str "service_worker"; "url", str ("chrome-extension://" ^ loaded ^ "/service-worker.js") ] ]
  | Some _ | None ->
    fake.listings_without_worker <- max 0 (fake.listings_without_worker - 1);
    [ page ]
;;

(* What the readiness check reads: the runtime installs its receiver before
   its marker, and where CDP evaluates in the worker the check can throw. *)
let readiness fake =
  if fake.readiness_throws then
    obj
      [ "result", obj [ "type", str "object"; "value", obj [] ]
      ; "exceptionDetails", obj [ "text", str "Uncaught"; "exception", obj [ "description", str "ReferenceError: setTimeout is not defined" ] ]
      ]
  else if fake.looks_before_ready > 0 then (
    fake.looks_before_ready <- fake.looks_before_ready - 1;
    obj [ "result", obj [ "type", str "object"; "value", obj [ "receiver", `Bool true; "marker", `Null ] ] ])
  else obj [ "result", obj [ "type", str "object"; "value", obj [ "receiver", `Bool true; "marker", fake.marker ] ] ]
;;

let browser_receives fake frame =
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string frame in
  let id = member "id" json |> to_int and params = member "params" json in
  let answer result = to_masc fake (to_s (obj [ "id", `Int id; "result", result ])) in
  match member "method" json |> to_string with
  | "Runtime.enable" | "Runtime.addBinding" -> answer (obj [])
  | "Extensions.loadUnpacked" ->
    let loaded = Option.value fake.loaded_id ~default:(Wire.extension_id_of_real_path (member "path" params |> to_string)) in
    fake.loaded <- Some loaded;
    answer (obj [ "id", str loaded ])
  | "Target.getTargets" -> answer (obj [ "targetInfos", `List (targets fake) ])
  | "Target.attachToTarget" -> answer (obj [ "sessionId", str worker ])
  | "Runtime.evaluate" ->
    let expression = member "expression" params |> to_string in
    if String.equal expression Wire.readiness_expression then answer (readiness fake)
    else (
      match delivered expression with
      | Some message ->
        answer (obj [ "result", obj [ "type", str "boolean"; "value", `Bool true ] ]);
        extension_receives fake message
      | None -> failf "unexpected expression %s" expression)
  | other -> failf "the fake browser got %s" other
;;

type harness =
  { fake : fake
  ; session : Session.t
  ; cdp : Cdp.t
  ; events : Session.event list ref
  ; model_calls : int ref
  ; settle : unit -> unit
  }

let with_session ?(configure = ignore) ?(answer = fun _ -> Ok model_answer) f =
  Eio_mock.Backend.run_full
  @@ fun env ->
  let clock = env#clock in
  Eio.Switch.run
  @@ fun sw ->
  let fake =
    { inbox = Eio.Stream.create max_int
    ; loaded = None
    ; loaded_id = None
    ; listings_without_worker = 0
    ; marker = marker "2.0.0"
    ; looks_before_ready = 0
    ; readiness_throws = false
    ; act = Ask_the_model
    ; held_act = None
    ; waiting_on_model = None
    ; answers_from_host = []
    }
  in
  configure fake;
  let events = ref [] and model_calls = ref 0 in
  let model params =
    incr model_calls;
    answer params
  in
  let session = Session.create ~sw ~clock ~worker_wait_s:deadline_s ~model ~log:(fun event -> events := event :: !events) in
  let cdp =
    Cdp.create ~send:(browser_receives fake) ~close:ignore ~clock ~command_deadline_s:deadline_s
      ~on_event:(Session.on_cdp_event session)
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec read () =
      Cdp.receive cdp (Eio.Stream.take fake.inbox);
      read ()
    in
    read ());
  f { fake; session; cdp; events; model_calls; settle = (fun () -> Eio.Time.sleep clock settle_s) }
;;

let attach h = Session.attach h.session h.cdp ~extension_dir:(Sys.getcwd ()) ~browser_cdp_url:"ws://127.0.0.1:9/devtools/browser/b"

let attached h =
  match attach h with
  | Ok _ -> ()
  | Error _ -> fail "attach failed"
;;

let error_code message = Yojson.Safe.Util.(message |> member "error" |> member "code" |> to_int)
let has_result message = Yojson.Safe.Util.member "result" message <> `Null
let act = Wire.Act { page_id = "P"; instruction = "click the Submit order button" }
let goto = Wire.Page_goto { page_id = "P"; url = "http://127.0.0.1:1/" }
let logged h wanted = List.exists wanted !(h.events)

let only_answer h =
  match h.fake.answers_from_host with
  | [ answer ] -> answer
  | answers -> failf "expected one answer to the extension, got %d" (List.length answers)
;;

let goto_succeeds h =
  match Session.call h.session goto with
  | Ok _ -> ()
  | Error Session.Abandoned_call_pending -> fail "goto was refused behind an abandoned call"
  | Error _ -> fail "goto"
;;

(* Starts [call] on a fiber of its own, lets it reach its wait, and cancels
   it there, as the lane deadline does. *)
let cancel_waiting_caller h call =
  try
    Eio.Switch.run (fun caller ->
      Eio.Fiber.fork ~sw:caller (fun () -> ignore (Session.call h.session call));
      h.settle ();
      Eio.Switch.fail caller Exit)
  with
  | Exit -> ()
;;

exception Model_bug

let test_attach () =
  with_session
  @@ fun h ->
  match attach h with
  | Ok init -> check bool "init reports its pages" true (Yojson.Safe.Util.member "pages" init <> `Null)
  | Error _ -> fail "attach against a matching extension"
;;

let test_worker_found_after_loading () =
  with_session ~configure:(fun fake -> fake.listings_without_worker <- 3)
  @@ fun h ->
  match attach h with
  | Ok _ -> check int "every empty listing was read" 0 h.fake.listings_without_worker
  | Error _ -> fail "a worker listed a few polls after loading is found"
;;

let test_runtime_ready_after_a_few_looks () =
  with_session ~configure:(fun fake -> fake.looks_before_ready <- 3)
  @@ fun h ->
  match attach h with
  | Ok _ -> check int "every early look was answered" 0 h.fake.looks_before_ready
  | Error _ -> fail "a runtime whose marker comes after its receiver is waited for"
;;

let calls_refused_after_failed_attach h =
  match Session.call h.session goto with
  | Error (Session.Connection_gone _) -> ()
  | _ -> fail "a session whose attach failed takes no calls"
;;

let test_attach_refusals () =
  (with_session ~configure:(fun fake -> fake.loaded_id <- Some (String.make 32 'a'))
   @@ fun h ->
   (match attach h with
    | Error (Session.Extension_id_mismatch { loaded; _ }) -> check string "loaded id" (String.make 32 'a') loaded
    | _ -> fail "an extension loaded under another id is refused");
   calls_refused_after_failed_attach h);
  (with_session ~configure:(fun fake -> fake.listings_without_worker <- max_int)
   @@ fun h ->
   (match attach h with
    | Error Session.Service_worker_absent -> ()
    | _ -> fail "no worker within the wait is refused");
   calls_refused_after_failed_attach h);
  (with_session ~configure:(fun fake -> fake.readiness_throws <- true)
   @@ fun h ->
   (match attach h with
    | Error (Session.Runtime_marker detail) ->
      check string "the thrown cause is reported" "the readiness check threw: ReferenceError: setTimeout is not defined" detail
    | _ -> fail "a readiness check that threw is refused with its cause");
   calls_refused_after_failed_attach h);
  (with_session ~configure:(fun fake -> fake.looks_before_ready <- max_int)
   @@ fun h ->
   (match attach h with
    | Error Session.Runtime_not_ready -> ()
    | _ -> fail "a runtime never ready within the wait is refused");
   calls_refused_after_failed_attach h);
  with_session ~configure:(fun fake -> fake.marker <- marker "3.1.0")
  @@ fun h ->
  (match attach h with
   | Error (Session.Runtime_incompatible { found = "3.1.0"; supported = 2 }) -> ()
   | _ -> fail "another protocol major is refused");
  calls_refused_after_failed_attach h
;;

let test_act_uses_the_model () =
  with_session
  @@ fun h ->
  attached h;
  (match Session.call h.session act with
   | Ok result -> check string "the extension received the model's answer" (to_s model_answer) (to_s (Yojson.Safe.Util.member "model" result))
   | Error _ -> fail "act");
  check int "one model call" 1 !(h.model_calls);
  check bool "one answer went back" true (has_result (only_answer h))
;;

let test_model_request_without_a_call () =
  with_session
  @@ fun h ->
  attached h;
  to_host h.fake (rpc_request "g9" "llm.generate" (obj []));
  h.settle ();
  check int "refused with the host code" Wire.host_refused (error_code (only_answer h));
  check int "the model was not asked" 0 !(h.model_calls);
  check bool "the refusal is logged" true (logged h (function Session.Model_request_refused _ -> true | _ -> false))
;;

let test_abandoned_call () =
  with_session ~configure:(fun fake -> fake.act <- Hold)
  @@ fun h ->
  attached h;
  cancel_waiting_caller h act;
  (match Session.call h.session goto with
   | Error Session.Abandoned_call_pending -> ()
   | _ -> fail "a new call waits for the abandoned one");
  to_host h.fake (rpc_request "g2" "llm.generate" (obj []));
  h.settle ();
  check int "the abandoned call gets no model answer" Wire.host_refused (error_code (only_answer h));
  check int "the model was not asked" 0 !(h.model_calls);
  to_host h.fake (rpc_result (Option.get h.fake.held_act) (obj [ "success", `Bool true ]));
  h.settle ();
  check bool "the abandoned call's reply is logged" true
    (logged h (function Session.Abandoned_call_ended { method_ = "stagehand.act"; rejected = false } -> true | _ -> false));
  goto_succeeds h
;;

(* The reply is read before the cancelled caller resumes: the call is settled,
   not left abandoned waiting for a reply that already came. *)
let test_reply_read_before_the_cancelled_caller_resumes () =
  with_session ~configure:(fun fake -> fake.act <- Hold)
  @@ fun h ->
  attached h;
  (try
     Eio.Switch.run (fun caller ->
       Eio.Fiber.fork ~sw:caller (fun () -> ignore (Session.call h.session act));
       h.settle ();
       (* Wakes the reader first; the cancellation queues the caller after it. *)
       to_host h.fake (rpc_result (Option.get h.fake.held_act) (obj [ "success", `Bool true ]));
       Eio.Switch.fail caller Exit)
   with
   | Exit -> ());
  h.settle ();
  check bool "nothing was abandoned" false (logged h (function Session.Abandoned_call_ended _ -> true | _ -> false));
  goto_succeeds h
;;

(* The caller leaves while the model is still answering: the answer is not
   delivered and the extension is refused instead. *)
let test_model_answer_after_the_caller_left () =
  let never, _ = Eio.Promise.create () in
  with_session ~answer:(fun _ -> Eio.Promise.await never)
  @@ fun h ->
  attached h;
  cancel_waiting_caller h act;
  h.settle ();
  check int "the model was asked" 1 !(h.model_calls);
  check int "the extension is refused" Wire.host_refused (error_code (only_answer h));
  check bool "the refused act's reply is logged" true
    (logged h (function Session.Abandoned_call_ended { rejected = true; _ } -> true | _ -> false));
  goto_succeeds h
;;

let test_model_that_raises () =
  with_session ~answer:(fun _ -> raise Model_bug)
  @@ fun h ->
  attached h;
  (match Session.call h.session act with
   | Error (Session.Rejected _) -> ()
   | _ -> fail "the act fails when its model request is refused");
  check int "the extension is refused" Wire.host_refused (error_code (only_answer h));
  check bool "the failure is logged" true (logged h (function Session.Model_failed _ -> true | _ -> false));
  goto_succeeds h
;;

let test_worker_detached () =
  with_session ~configure:(fun fake -> fake.act <- Hold)
  @@ fun h ->
  attached h;
  Eio.Switch.run
  @@ fun sw ->
  let waiting = Eio.Fiber.fork_promise ~sw (fun () -> Session.call h.session act) in
  h.settle ();
  to_masc h.fake (to_s (obj [ "method", str "Target.detachedFromTarget"; "params", obj [ "sessionId", str worker ] ]));
  (match Eio.Promise.await_exn waiting with
   | Error (Session.Lost _) -> ()
   | _ -> fail "the call out when the worker left is lost");
  match Session.call h.session goto with
  | Error Session.Detached -> ()
  | _ -> fail "later calls are refused"
;;

let test_unsupported_request () =
  with_session
  @@ fun h ->
  attached h;
  to_host h.fake (rpc_request "u1" "context.clipboard_read_text" (obj []));
  h.settle ();
  check int "method not found" Wire.method_not_found (error_code (only_answer h));
  check bool "logged by name" true
    (logged h (function Session.Unsupported_request { method_ = "context.clipboard_read_text" } -> true | _ -> false))
;;

let test_protocol_major () =
  let major version = Wire.protocol_major { Wire.protocol_version = version; runtime_version = "1" } in
  check (result int string) "2.0.0" (Ok 2) (major "2.0.0");
  List.iter (fun version -> check bool version true (Result.is_error (major version))) [ "0x2.0.0"; "+2.0.0"; "2_0.0"; ""; "v2" ];
  check string "the version masc sends" "2.0.0" Wire.protocol_version
;;

let test_readiness_of_json () =
  let read receiver marker_json = Wire.readiness_of_json (obj [ "receiver", receiver; "marker", marker_json ]) in
  let is_ready = function Ok (Wire.Ready _) -> true | Ok Wire.Not_ready | Error _ -> false in
  let not_ready = function Ok Wire.Not_ready -> true | Ok (Wire.Ready _) | Error _ -> false in
  check bool "receiver and marker" true (is_ready (read (`Bool true) (marker "2.0.0")));
  check bool "receiver before its marker" true (not_ready (read (`Bool true) `Null));
  check bool "marker before its receiver" true (not_ready (read (`Bool false) (marker "2.0.0")));
  check bool "neither" true (not_ready (read (`Bool false) `Null));
  check bool "an answer of another shape" true (Result.is_error (Wire.readiness_of_json (obj [])))
;;

let () =
  run "browser_stagehand_session" [
    "wire", [
      test_case "protocol major is digits only" `Quick test_protocol_major;
      test_case "readiness needs the receiver and the marker" `Quick test_readiness_of_json;
    ];
    "attach", [
      test_case "a matching extension attaches" `Quick test_attach;
      test_case "a worker listed after loading is found" `Quick test_worker_found_after_loading;
      test_case "a runtime ready a few looks later is waited for" `Quick test_runtime_ready_after_a_few_looks;
      test_case "a failed attach ends the session" `Quick test_attach_refusals;
    ];
    "calls", [
      test_case "act asks the model" `Quick test_act_uses_the_model;
      test_case "a model request with no call is refused" `Quick test_model_request_without_a_call;
      test_case "an abandoned call blocks until its reply" `Quick test_abandoned_call;
      test_case "a reply read before the cancelled caller resumes settles the call" `Quick
        test_reply_read_before_the_cancelled_caller_resumes;
      test_case "a model answer after the caller left is not delivered" `Quick test_model_answer_after_the_caller_left;
      test_case "a model that raises refuses only its request" `Quick test_model_that_raises;
      test_case "a detached worker loses the call" `Quick test_worker_detached;
      test_case "an unsupported request is refused by name" `Quick test_unsupported_request;
    ];
  ]
;;
