(* What a peer reads when it sends HEAD, and when the answer is a 204
   (RFC 9110 §9.3.2, §8.6, §15.5.6).

   Every case sends its requests on one connection, through the router, and
   checks the bytes or frames that come back: a real httpun connection for
   HTTP/1.1 and a real h2 client pumped against an h2 server for HTTP/2. A
   response that carries content it must not have shifts what the next
   request on the connection reads, so each case asks for a second response
   and checks that one too. *)

open Alcotest
module Http = Masc.Http_server_eio
module Router = Http.Router

let page = "hello page"
let event = "data: one\n\n"

let stream_handler (_ : Httpun.Request.t) reqd =
  let response =
    Httpun.Response.create
      ~headers:
        (Httpun.Headers.of_list
           [ "content-type", "text/event-stream"; "transfer-encoding", "chunked" ])
      `OK
  in
  let body = Masc.Http_reqd.respond_with_streaming reqd response in
  Masc.Http_reqd.Body_writer.write_string body event;
  Masc.Http_reqd.Body_writer.close body
;;

let router () =
  Router.create ()
  |> Server_route.get Server_route.Always_public "/page" (fun _ -> Http.Response.text page)
  |> Server_route.get Server_route.Always_public "/stream" stream_handler
  |> Server_route.post Server_route.Always_public "/submit" (fun _ -> Http.Response.text "done")
  |> Server_route.add
       Server_route.Always_public
       ~path:"/item"
       ~methods:[ `DELETE ]
       (fun _ reqd -> Http.Response.empty reqd)
;;

(* ---- HTTP/1.1 ---- *)

let h1_request meth target =
  Printf.sprintf "%s %s HTTP/1.1\r\nHost: localhost\r\ncontent-length: 0\r\n\r\n" meth target
;;

(* Everything the server writes for [requests], sent on one connection. *)
let h1_exchange requests =
  let router = router () in
  let connection =
    Httpun.Server_connection.create (fun reqd ->
      Router.dispatch router (Httpun.Reqd.request reqd) (Masc.Http_reqd.of_httpun reqd))
  in
  let written = Buffer.create 512 in
  let rec drain progressed =
    match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let length =
        List.fold_left
          (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
             Buffer.add_string written (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
             total + iov.len)
          0
          iovecs
      in
      Httpun.Server_connection.report_write_result connection (`Ok length);
      drain true
    | `Yield | `Close (_ : int) -> progressed
  in
  let rec pump input =
    let wrote = drain false in
    match Httpun.Server_connection.next_read_operation connection with
    | `Read when String.length input > 0 ->
      let len = String.length input in
      let consumed =
        Httpun.Server_connection.read
          connection
          (Bigstringaf.of_string input ~off:0 ~len)
          ~off:0
          ~len
      in
      if consumed > 0 || wrote then pump (String.sub input consumed (len - consumed))
    | `Read | `Yield | `Close -> if wrote then pump input
  in
  pump (String.concat "" requests);
  Buffer.contents written
;;

let head_end = "\r\n\r\n"

let find_head_end text =
  let n = String.length head_end in
  let rec at i =
    if i + n > String.length text
    then fail (Printf.sprintf "no end of the header section in %S" text)
    else if String.equal (String.sub text i n) head_end
    then i + n
    else at (i + 1)
  in
  at 0
;;

(* The status line and fields of the first response in [text], with the
   empty line that ends them. *)
let h1_head text = String.sub text 0 (find_head_end text)

let h1_fields head =
  String.split_on_char '\n' head
  |> List.filter_map (fun line ->
    match String.index_opt line ':' with
    | Some colon ->
      Some
        ( String.lowercase_ascii (String.sub line 0 colon)
        , String.trim (String.sub line (colon + 1) (String.length line - colon - 1)) )
    | None -> None)
;;

let page_response () = h1_exchange [ h1_request "GET" "/page" ]

let test_h1_head_is_the_get_without_content () =
  let get = page_response () in
  check bool "the GET carries the page" true (String.ends_with ~suffix:page get);
  check
    string
    "HEAD gets the GET's header section and nothing after it; the next GET is whole"
    (h1_head get ^ get)
    (h1_exchange [ h1_request "HEAD" "/page"; h1_request "GET" "/page" ])
;;

let test_h1_head_of_a_streamed_response () =
  let streamed = h1_exchange [ h1_request "GET" "/stream" ] in
  check bool "the GET carries the event" true (find_head_end streamed < String.length streamed);
  check
    string
    "HEAD gets the stream's header section only; the next GET is whole"
    (h1_head streamed ^ page_response ())
    (h1_exchange [ h1_request "HEAD" "/stream"; h1_request "GET" "/page" ])
;;

let test_h1_no_content_has_no_content_length () =
  let get = page_response () in
  let written = h1_exchange [ h1_request "DELETE" "/item"; h1_request "GET" "/page" ] in
  let head = h1_head written in
  check bool "answered 204" true (String.starts_with ~prefix:"HTTP/1.1 204 " head);
  check (option string) "no content-length" None (List.assoc_opt "content-length" (h1_fields head));
  check string "the next GET is whole" (head ^ get) written
;;

let test_h1_method_not_allowed_names_the_methods () =
  let get = page_response () in
  let refused = h1_head (h1_exchange [ h1_request "POST" "/page" ]) in
  check bool "answered 405" true (String.starts_with ~prefix:"HTTP/1.1 405 " refused);
  check
    (option string)
    "a GET route allows GET and HEAD"
    (Some "GET, HEAD")
    (List.assoc_opt "allow" (h1_fields refused));
  let written = h1_exchange [ h1_request "HEAD" "/submit"; h1_request "GET" "/page" ] in
  let head = h1_head written in
  check bool "HEAD on a POST route is 405" true (String.starts_with ~prefix:"HTTP/1.1 405 " head);
  check (option string) "it allows POST" (Some "POST") (List.assoc_opt "allow" (h1_fields head));
  check string "the 405 to HEAD has no content; the next GET is whole" (head ^ get) written
;;

(* ---- HTTP/2 ---- *)

type reply =
  { status : int
  ; headers : H2.Headers.t
  ; body : string
  }

(* Bytes one side wrote that the other side's [read] has not taken yet. *)
type lane = { mutable pending : string }

let transfer lane next_write report_write read =
  let rec drain progressed =
    match next_write () with
    | `Write iovecs ->
      let chunk = Buffer.create 4096 in
      Buffer.add_string chunk lane.pending;
      let written =
        List.fold_left
          (fun total (iov : Bigstringaf.t H2.IOVec.t) ->
             Buffer.add_string chunk (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
             total + iov.len)
          0
          iovecs
      in
      report_write (`Ok written);
      let data = Buffer.contents chunk in
      let length = String.length data in
      let consumed = read (Bigstringaf.of_string data ~off:0 ~len:length) ~off:0 ~len:length in
      lane.pending <- String.sub data consumed (length - consumed);
      drain true
    | `Yield | `Close _ -> progressed
  in
  drain false
;;

(* One reply per request, each sent after the one before it completed, all on
   one connection. A stream the client refuses fails the case: that is what a
   response to HEAD with DATA frames gets. *)
let h2_exchange requests =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let router = router () in
  let resources =
    Masc.Http_h2_response_ledger.create
      ~max_pending_bytes:H2_response_limits.default_max_pending_bytes
  in
  Masc.Http_h2_response_ledger.with_request resources ~sw
  @@ fun () ->
  let client =
    H2.Client_connection.create ~error_handler:(fun _ -> fail "H2 connection error") ()
  in
  let server =
    H2.Server_connection.create (fun h2_reqd ->
      let stream_end =
        Masc.Http_h2_stream.Stream_end.create
          ~stream_sw:sw
          ~clock:(Eio.Stdenv.clock env)
          ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s
          ~request:(H2.Reqd.request h2_reqd)
          h2_reqd
      in
      let reqd =
        Masc.Http_reqd.of_h2
          ~stream_end
          ~ledger:(Masc.Http_h2_response_ledger.current_exn ())
          h2_reqd
      in
      Router.dispatch router (Masc.Http_reqd.request reqd) reqd)
  in
  let to_server = { pending = "" } in
  let to_client = { pending = "" } in
  let ask (meth, target) =
    let status = ref None in
    let headers = ref H2.Headers.empty in
    let body = Buffer.create 64 in
    let complete = ref false in
    let writer =
      H2.Client_connection.request
        client
        (H2.Request.create
           ~scheme:"http"
           meth
           target
           ~headers:(H2.Headers.of_list [ ":authority", "localhost:8935" ]))
        ~error_handler:(fun _ -> fail (Printf.sprintf "H2 stream error on %s" target))
        ~response_handler:(fun response reader ->
          status := Some (H2.Status.to_code response.H2.Response.status);
          headers := response.headers;
          let rec consume () =
            H2.Body.Reader.schedule_read
              reader
              ~on_eof:(fun () -> complete := true)
              ~on_read:(fun buffer ~off ~len ->
                Buffer.add_string body (Bigstringaf.substring buffer ~off ~len);
                consume ())
          in
          consume ())
    in
    H2.Body.Writer.close writer;
    let moved () =
      let sent =
        transfer
          to_server
          (fun () -> H2.Client_connection.next_write_operation client)
          (H2.Client_connection.report_write_result client)
          (H2.Server_connection.read server)
      in
      let received =
        transfer
          to_client
          (fun () -> H2.Server_connection.next_write_operation server)
          (H2.Server_connection.report_write_result server)
          (H2.Client_connection.read client)
      in
      sent || received
    in
    let rec pump () =
      let moved = moved () in
      if !complete
      then ()
      else if moved
      then pump ()
      else fail (Printf.sprintf "the response to %s did not complete" target)
    in
    pump ();
    match !status with
    | Some status -> { status; headers = !headers; body = Buffer.contents body }
    | None -> fail "the response carried no headers"
  in
  List.map ask requests
;;

let two_replies requests =
  match h2_exchange requests with
  | [ first; second ] -> first, second
  | replies -> fail (Printf.sprintf "expected two replies, got %d" (List.length replies))
;;

let check_whole_page name reply =
  check int (name ^ ": answered") 200 reply.status;
  check string (name ^ ": the page") page reply.body
;;

let test_h2_head_is_the_get_without_content () =
  let head, get = two_replies [ `HEAD, "/page"; `GET, "/page" ] in
  check int "HEAD is answered as the GET" 200 head.status;
  check string "HEAD has no content" "" head.body;
  check
    (list (pair string string))
    "HEAD has the GET's fields"
    (H2.Headers.to_list get.headers)
    (H2.Headers.to_list head.headers);
  check_whole_page "the GET after it" get
;;

let test_h2_head_of_a_streamed_response () =
  let head, get = two_replies [ `HEAD, "/stream"; `GET, "/page" ] in
  check int "answered" 200 head.status;
  check
    (option string)
    "the stream's content type"
    (Some "text/event-stream")
    (H2.Headers.get head.headers "content-type");
  check string "no content" "" head.body;
  check_whole_page "the GET after it" get
;;

let test_h2_no_content_has_no_content_length () =
  let deleted, get = two_replies [ `DELETE, "/item"; `GET, "/page" ] in
  check int "answered" 204 deleted.status;
  check (option string) "no content-length" None (H2.Headers.get deleted.headers "content-length");
  check string "no content" "" deleted.body;
  check_whole_page "the GET after it" get
;;

let test_h2_method_not_allowed_names_the_methods () =
  let refused, get = two_replies [ `HEAD, "/submit"; `GET, "/page" ] in
  check int "HEAD on a POST route" 405 refused.status;
  check (option string) "it allows POST" (Some "POST") (H2.Headers.get refused.headers "allow");
  check string "no content" "" refused.body;
  check_whole_page "the GET after it" get
;;

let () =
  run
    "HTTP response content"
    [ ( "HTTP/1.1"
      , [ test_case "HEAD is the GET without content" `Quick test_h1_head_is_the_get_without_content
        ; test_case "HEAD of a streamed response" `Quick test_h1_head_of_a_streamed_response
        ; test_case "a 204 has no content-length" `Quick test_h1_no_content_has_no_content_length
        ; test_case
            "a 405 names the allowed methods"
            `Quick
            test_h1_method_not_allowed_names_the_methods
        ] )
    ; ( "HTTP/2"
      , [ test_case "HEAD is the GET without content" `Quick test_h2_head_is_the_get_without_content
        ; test_case "HEAD of a streamed response" `Quick test_h2_head_of_a_streamed_response
        ; test_case "a 204 has no content-length" `Quick test_h2_no_content_has_no_content_length
        ; test_case
            "a 405 names the allowed methods"
            `Quick
            test_h2_method_not_allowed_names_the_methods
        ] )
    ]
;;
