(* The destination walk of [Typesafeai_client]: which refusals move the
   request to the next server, and what the answer and the failure record
   about the servers asked. Two loopback fixtures stand in for TypeSafe's own
   endpoint and OpenRouter's System One endpoint. *)

module Client = Masc.Typesafeai_client
module T = Masc.Typesafeai_types

let questions =
  [ ( "q"
    , T.Choice
        { instructions = "Is the post for this keeper?"
        ; criteria = [ "yes", None; "no", None ]
        } )
  ]
;;

let state = `Assoc [ "text", `String "fixture state" ]

(* OpenRouter adds [id], [provider] and [usage.cost] to TypeSafe's response;
   the decoder reads past them. *)
let answer_body ~model =
  Printf.sprintf
    {|{"id":"or-fixture","provider":"TypeSafe","model":%S,"answers":{"q":{"type":"choice","choice":"yes","probabilities":{"yes":0.9,"no":0.1},"confidence":0.9}},"usage":{"input_tokens":3,"output_tokens":0,"cost":0.0}}|}
    model
;;

type fixture =
  { uri : string
  ; received : (string * string option) list ref
    (* request body and authorization header, newest first *)
  }

let serve ~sw ~net ~respond =
  let received = ref [] in
  let handler _conn request body =
    let raw = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    received
    := (raw, Cohttp.Header.get (Cohttp.Request.headers request) "authorization")
       :: !received;
    let status, body = respond raw in
    Cohttp_eio.Server.respond_string ~status ~body ()
  in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:8
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix _ -> Alcotest.fail "fixture has no TCP address"
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run
      socket
      (Cohttp_eio.Server.make ~callback:handler ())
      ~on_error:(fun exn -> Alcotest.fail (Printexc.to_string exn)));
  { uri = Printf.sprintf "http://127.0.0.1:%d/systemone" port; received }
;;

let with_env f =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
  @@ fun () ->
  (* The client posts through the shared outbound pool, which a test has to
     open for itself: no server bootstrap runs here. *)
  Masc_http_client.with_scoped_pool ~sw ~env @@ fun () -> f ~sw ~net ~clock
;;

(* The fixture answers with the model id it was asked for, as both servers do. *)
let answers ~model _raw = `OK, answer_body ~model
let refuses status _raw = status, "fixture refusal"

let model_sent raw =
  Yojson.Safe.from_string raw
  |> Yojson.Safe.Util.member "model"
  |> Yojson.Safe.Util.to_string
;;

let contains haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.equal (String.sub haystack i n) needle || go (i + 1)) in
  n = 0 || go 0
;;

let evaluate ~clock destinations = Client.evaluate ~clock ~destinations ~state ~questions ()

let test_second_destination_answers_after_a_capacity_refusal () =
  with_env
  @@ fun ~sw ~net ~clock ->
  let typesafe = serve ~sw ~net ~respond:(refuses `Service_unavailable) in
  let openrouter = serve ~sw ~net ~respond:(answers ~model:"typesafe/jev-1.13") in
  let first =
    { Client.endpoint = typesafe.uri; model = "jev-latest"; api_key = "typesafe-key" }
  in
  let second =
    { Client.endpoint = openrouter.uri
    ; model = "~typesafe/jev-latest"
    ; api_key = "openrouter-key"
    }
  in
  match evaluate ~clock (first, [ second ]) with
  | Error failure -> Alcotest.fail (Client.failure_to_string failure)
  | Ok evaluated ->
    Alcotest.(check string)
      "the answer names the server that gave it"
      openrouter.uri
      evaluated.destination.destination_uri;
    Alcotest.(check string)
      "and the model id that server was asked for"
      "~typesafe/jev-latest"
      evaluated.destination.model;
    Alcotest.(check string)
      "the answer carries that server's model id"
      "typesafe/jev-1.13"
      evaluated.response.model;
    (match !(openrouter.received) with
     | [ raw, authorization ] ->
       Alcotest.(check string)
         "the second server was asked for its own model"
         "~typesafe/jev-latest"
         (model_sent raw);
       Alcotest.(check (option string))
         "with its own key"
         (Some "Bearer openrouter-key")
         authorization
     | received -> Alcotest.failf "second server saw %d requests" (List.length received));
    Alcotest.(check int) "the first server was asked once" 1 (List.length !(typesafe.received));
    (match evaluated.passed_over with
     | [ { destination_uri; model; refusal = Client.Http_response_failure { status; _ } } ] ->
       Alcotest.(check string) "passed-over destination" typesafe.uri destination_uri;
       Alcotest.(check string) "passed-over model" "jev-latest" model;
       Alcotest.(check int) "passed-over status" 503 status
     | _ -> Alcotest.fail "exactly one passed-over attempt with an HTTP refusal")
;;

(* A server that calls the request wrong says nothing about the next one: each
   destination is asked for its own model id and keeps its own limits. *)
let test_a_request_refusal_still_asks_the_next_destination () =
  with_env
  @@ fun ~sw ~net ~clock ->
  let unavailable = serve ~sw ~net ~respond:(refuses `Service_unavailable) in
  let refusing = serve ~sw ~net ~respond:(refuses `Unprocessable_entity) in
  let answering = serve ~sw ~net ~respond:(answers ~model:"m3") in
  let first = { Client.endpoint = unavailable.uri; model = "m1"; api_key = "k1" } in
  let second = { Client.endpoint = refusing.uri; model = "m2"; api_key = "k2" } in
  let third = { Client.endpoint = answering.uri; model = "m3"; api_key = "k3" } in
  match evaluate ~clock (first, [ second; third ]) with
  | Error failure -> Alcotest.fail (Client.failure_to_string failure)
  | Ok evaluated ->
    Alcotest.(check string)
      "the third destination answered"
      answering.uri
      evaluated.destination.destination_uri;
    Alcotest.(check (list int))
      "each server was asked once"
      [ 1; 1; 1 ]
      (List.map
         (fun server -> List.length !(server.received))
         [ unavailable; refusing; answering ]);
    let statuses =
      List.map
        (fun (attempt : Client.attempt) ->
           match attempt.refusal with
           | Client.Http_response_failure { status; _ } -> status
           | Client.Transport_failure detail -> Alcotest.fail detail)
        evaluated.passed_over
    in
    Alcotest.(check (list int)) "both refusals are kept, in the order asked" [ 503; 422 ] statuses;
    Alcotest.(check (list string))
      "with the model each was asked for"
      [ "m1"; "m2" ]
      (List.map (fun (attempt : Client.attempt) -> attempt.model) evaluated.passed_over)
;;

let test_one_destination_renders_as_its_refusal () =
  with_env
  @@ fun ~sw ~net ~clock ->
  let server = serve ~sw ~net ~respond:(refuses `Unprocessable_entity) in
  let only = { Client.endpoint = server.uri; model = "jev-latest"; api_key = "k1" } in
  match evaluate ~clock (only, []) with
  | Ok _ -> Alcotest.fail "the only destination refused"
  | Error failure ->
    Alcotest.(check int) "one attempt" 1 (List.length (Client.attempts failure));
    Alcotest.(check string)
      "one attempt renders as its refusal"
      (Printf.sprintf "typesafeai: HTTP 422 returned by %s: fixture refusal" server.uri)
      (Client.failure_to_string failure)
;;

let test_no_response_moves_to_the_next_destination () =
  with_env
  @@ fun ~sw ~net ~clock ->
  let closed_uri = "http://127.0.0.1:9/systemone" in
  let closed = { Client.endpoint = closed_uri; model = "jev-latest"; api_key = "k1" } in
  let server = serve ~sw ~net ~respond:(answers ~model:"jev-latest") in
  let second = { Client.endpoint = server.uri; model = "jev-latest"; api_key = "k2" } in
  match evaluate ~clock (closed, [ second ]) with
  | Error failure -> Alcotest.fail (Client.failure_to_string failure)
  | Ok evaluated ->
    Alcotest.(check string)
      "answered by the second"
      server.uri
      evaluated.destination.destination_uri;
    (match evaluated.passed_over with
     | [ { refusal = Client.Transport_failure _; destination_uri; _ } ] ->
       Alcotest.(check string) "the closed port is recorded" closed_uri destination_uri
     | _ -> Alcotest.fail "exactly one passed-over transport failure")
;;

let test_every_destination_refusing_is_recorded_in_order () =
  with_env
  @@ fun ~sw ~net ~clock ->
  let a = serve ~sw ~net ~respond:(refuses `Service_unavailable) in
  let b = serve ~sw ~net ~respond:(refuses `Too_many_requests) in
  let first = { Client.endpoint = a.uri; model = "jev-latest"; api_key = "ka" } in
  let second = { Client.endpoint = b.uri; model = "~typesafe/jev-latest"; api_key = "kb" } in
  match evaluate ~clock (first, [ second ]) with
  | Ok _ -> Alcotest.fail "both refused"
  | Error failure ->
    (match Client.attempts failure with
     | [ one; two ] ->
       Alcotest.(check string) "first asked first" a.uri one.destination_uri;
       Alcotest.(check string) "second asked second" b.uri two.destination_uri
     | asked -> Alcotest.failf "%d attempts" (List.length asked));
    let rendered = Client.failure_to_string failure in
    List.iter
      (fun needle ->
         Alcotest.(check bool) ("rendering mentions " ^ needle) true (contains rendered needle))
      [ a.uri; b.uri; "HTTP 503"; "HTTP 429" ];
    let json = Client.failure_to_yojson failure in
    Alcotest.(check string)
      "json kind"
      "every_destination_refused"
      Yojson.Safe.Util.(member "kind" json |> to_string);
    Alcotest.(check int)
      "json attempts"
      2
      Yojson.Safe.Util.(member "attempts" json |> to_list |> List.length)
;;

let () =
  Alcotest.run
    "typesafeai destinations"
    [ ( "walk"
      , [ Alcotest.test_case
            "the second destination answers after a capacity refusal"
            `Quick
            test_second_destination_answers_after_a_capacity_refusal
        ; Alcotest.test_case
            "a request refusal still asks the next destination"
            `Quick
            test_a_request_refusal_still_asks_the_next_destination
        ; Alcotest.test_case
            "one destination renders as its refusal"
            `Quick
            test_one_destination_renders_as_its_refusal
        ; Alcotest.test_case
            "no response moves to the next destination"
            `Quick
            test_no_response_moves_to_the_next_destination
        ; Alcotest.test_case
            "every destination refusing is recorded in order"
            `Quick
            test_every_destination_refusing_is_recorded_in_order
        ] )
    ]
;;
