(* A Stagehand session against a fake Chromium and a fake extension.

   The fake browser answers the CDP commands a session sends; the fake
   extension answers the JSON-RPC it receives through [Runtime.evaluate] and
   talks back through [Runtime.bindingCalled]. Frames go back to the
   connection from a separate fiber, as a socket reader would deliver them. *)
open Alcotest
module Cdp = Masc.Browser_cdp
module Wire = Masc.Browser_stagehand_wire
module Session = Masc.Browser_stagehand_session

let obj fields = `Assoc fields
let str value = `String value
let to_s = Yojson.Safe.to_string
let worker = "W"
let deadline_s = 5.0
let marker version = obj [ "protocolVersion", str version; "serverInfo", obj [ "name", str "stagehand"; "version", str "1.0.2" ] ]

type act_behaviour = Ask_the_model | Hold

type fake =
  { inbox : string Eio.Stream.t
  ; mutable loaded_id : string option
  ; mutable marker : Yojson.Safe.t
  ; mutable act : act_behaviour
  ; mutable held_act : Yojson.Safe.t option
  ; mutable waiting_on_model : (Yojson.Safe.t * Yojson.Safe.t) option
  ; mutable answers_from_host : Yojson.Safe.t list
  }

let to_host fake message =
  Eio.Stream.add fake.inbox
    (to_s
       (obj
          [ "method", str "Runtime.bindingCalled"
          ; "sessionId", str worker
          ; "params", obj [ "name", str Wire.send_to_host_binding; "payload", str (to_s message); "executionContextId", `Int 1 ]
          ]))
;;

let rpc_result id result = obj [ "jsonrpc", str "2.0"; "id", id; "result", result ]
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
       to_host fake (rpc_result act_id (obj [ "success", `Bool true; "model", member "result" message ]))
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

let browser_receives fake frame =
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string frame in
  let id = member "id" json |> to_int and params = member "params" json in
  let answer result = Eio.Stream.add fake.inbox (to_s (obj [ "id", `Int id; "result", result ])) in
  match member "method" json |> to_string with
  | "Target.setDiscoverTargets" | "Runtime.enable" | "Runtime.addBinding" -> answer (obj [])
  | "Extensions.loadUnpacked" ->
    let loaded = Option.value fake.loaded_id ~default:(Wire.extension_id_of_real_path (member "path" params |> to_string)) in
    answer (obj [ "id", str loaded ]);
    Eio.Stream.add fake.inbox
      (to_s
         (obj
            [ "method", str "Target.targetCreated"
            ; "params", obj [ "targetInfo", obj [ "targetId", str "SW"; "type", str "service_worker"; "url", str ("chrome-extension://" ^ loaded ^ "/service-worker.js") ] ]
            ]))
  | "Target.attachToTarget" -> answer (obj [ "sessionId", str worker ])
  | "Runtime.evaluate" ->
    let expression = member "expression" params |> to_string in
    if String.equal expression Wire.readiness_expression then answer (obj [ "result", obj [ "type", str "object"; "value", fake.marker ] ])
    else (
      match delivered expression with
      | Some message ->
        answer (obj [ "result", obj [ "type", str "boolean"; "value", `Bool true ] ]);
        extension_receives fake message
      | None -> failf "unexpected expression %s" expression)
  | other -> failf "the fake browser got %s" other
;;

let with_session ?(configure = ignore) ?(answer = fun _ -> Ok (obj [ "structured_content", obj [ "pick", str "0-18" ] ])) f =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run
  @@ fun sw ->
  let fake =
    { inbox = Eio.Stream.create max_int
    ; loaded_id = None
    ; marker = marker "2.0.0"
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
  f ~fake ~session ~cdp ~events ~model_calls
;;

let attach session cdp = Session.attach session cdp ~extension_dir:(Sys.getcwd ()) ~browser_cdp_url:"ws://127.0.0.1:9/devtools/browser/b"

let attached session cdp =
  match attach session cdp with
  | Ok _ -> ()
  | Error _ -> fail "attach failed"
;;

(* Let the reader and reply fibers run until [ready] holds. *)
let yields_allowed = 1000

let run_until ready =
  let rec go remaining =
    if ready () then ()
    else if remaining = 0 then fail "the fake never reached the expected state"
    else (
      Eio.Fiber.yield ();
      go (remaining - 1))
  in
  go yields_allowed
;;

(* The extension holds an act only after masc's [Runtime.evaluate] carrying
   it was answered; until the reader has taken that answer, a cancelled
   caller would still have a CDP command out, which ends the connection. *)
let act_held fake () = Option.is_some fake.held_act && Eio.Stream.is_empty fake.inbox

(* After the answer is read, the caller's fiber still has to reach its wait
   for the JSON-RPC reply. *)
let passes_to_reach_the_wait = 10

let let_callers_reach_their_waits () =
  for _ = 1 to passes_to_reach_the_wait do
    Eio.Fiber.yield ()
  done
;;

let error_code message = Yojson.Safe.Util.(message |> member "error" |> member "code" |> to_int)
let act = Wire.Act { page_id = "P"; instruction = "click the Submit order button" }
let goto = Wire.Page_goto { page_id = "P"; url = "http://127.0.0.1:1/" }

let test_attach () =
  with_session
  @@ fun ~fake:_ ~session ~cdp ~events:_ ~model_calls:_ ->
  match attach session cdp with
  | Ok init -> check bool "init reports its pages" true (Yojson.Safe.Util.member "pages" init <> `Null)
  | Error _ -> fail "attach against a matching extension"
;;

let test_attach_refusals () =
  (with_session ~configure:(fun fake -> fake.loaded_id <- Some (String.make 32 'a'))
   @@ fun ~fake:_ ~session ~cdp ~events:_ ~model_calls:_ ->
   match attach session cdp with
   | Error (Session.Extension_id_mismatch { loaded; _ }) -> check string "loaded id" (String.make 32 'a') loaded
   | _ -> fail "an extension loaded under another id is refused");
  with_session ~configure:(fun fake -> fake.marker <- marker "3.1.0")
  @@ fun ~fake:_ ~session ~cdp ~events:_ ~model_calls:_ ->
  match attach session cdp with
  | Error (Session.Runtime_incompatible { found = "3.1.0"; supported = 2 }) -> ()
  | _ -> fail "another protocol major is refused"
;;

let test_act_uses_the_model () =
  with_session
  @@ fun ~fake ~session ~cdp ~events:_ ~model_calls ->
  attached session cdp;
  (match Session.call session act with
   | Ok result ->
     check string "the extension received the model's answer" {|{"structured_content":{"pick":"0-18"}}|}
       (to_s (Yojson.Safe.Util.member "model" result))
   | Error _ -> fail "act");
  check int "one model call" 1 !model_calls;
  check int "one answer went back" 1 (List.length fake.answers_from_host)
;;

let test_model_request_without_a_call () =
  with_session
  @@ fun ~fake ~session ~cdp ~events ~model_calls ->
  attached session cdp;
  to_host fake (rpc_request "g9" "llm.generate" (obj []));
  run_until (fun () -> fake.answers_from_host <> []);
  check int "refused with the host code" Wire.host_refused (error_code (List.hd fake.answers_from_host));
  check int "the model was not asked" 0 !model_calls;
  check bool "the refusal is logged" true
    (List.exists (function Session.Model_request_refused _ -> true | _ -> false) !events)
;;

let test_abandoned_call () =
  with_session ~configure:(fun fake -> fake.act <- Hold)
  @@ fun ~fake ~session ~cdp ~events:_ ~model_calls ->
  attached session cdp;
  (try
     Eio.Switch.run (fun caller ->
       Eio.Fiber.fork ~sw:caller (fun () -> ignore (Session.call session act));
       run_until (act_held fake);
       let_callers_reach_their_waits ();
       Eio.Switch.fail caller Exit)
   with
   | Exit -> ());
  (match Session.call session goto with
   | Error Session.Abandoned_call_pending -> ()
   | _ -> fail "a new call waits for the abandoned one");
  to_host fake (rpc_request "g2" "llm.generate" (obj []));
  run_until (fun () -> fake.answers_from_host <> []);
  check int "the abandoned call gets no model answer" Wire.host_refused (error_code (List.hd fake.answers_from_host));
  check int "the model was not asked" 0 !model_calls;
  to_host fake (rpc_result (Option.get fake.held_act) (obj [ "success", `Bool true ]));
  run_until (fun () -> Result.is_ok (Session.call session goto))
;;

let test_worker_detached () =
  with_session ~configure:(fun fake -> fake.act <- Hold)
  @@ fun ~fake ~session ~cdp ~events:_ ~model_calls:_ ->
  attached session cdp;
  Eio.Switch.run
  @@ fun sw ->
  let waiting = Eio.Fiber.fork_promise ~sw (fun () -> Session.call session act) in
  run_until (act_held fake);
  Eio.Stream.add fake.inbox (to_s (obj [ "method", str "Target.detachedFromTarget"; "params", obj [ "sessionId", str worker ] ]));
  (match Eio.Promise.await_exn waiting with
   | Error (Session.Lost _) -> ()
   | _ -> fail "the call out when the worker left is lost");
  match Session.call session goto with
  | Error Session.Detached -> ()
  | _ -> fail "later calls are refused"
;;

let test_unsupported_request () =
  with_session
  @@ fun ~fake ~session ~cdp ~events ~model_calls:_ ->
  attached session cdp;
  to_host fake (rpc_request "u1" "context.clipboard_read_text" (obj []));
  run_until (fun () -> fake.answers_from_host <> []);
  check int "method not found" Wire.method_not_found (error_code (List.hd fake.answers_from_host));
  check bool "logged by name" true
    (List.exists
       (function Session.Unsupported_request { method_ = "context.clipboard_read_text" } -> true | _ -> false)
       !events)
;;

let () =
  run "browser_stagehand_session" [
    "attach", [
      test_case "a matching extension attaches" `Quick test_attach;
      test_case "a wrong id or major is refused" `Quick test_attach_refusals;
    ];
    "calls", [
      test_case "act asks the model" `Quick test_act_uses_the_model;
      test_case "a model request with no call is refused" `Quick test_model_request_without_a_call;
      test_case "an abandoned call blocks until its reply" `Quick test_abandoned_call;
      test_case "a detached worker loses the call" `Quick test_worker_detached;
      test_case "an unsupported request is refused by name" `Quick test_unsupported_request;
    ];
  ]
;;
