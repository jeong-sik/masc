open Alcotest
module Response = Server_h2_gateway_helpers

let wire_response ~handler ~headers target =
  let response = ref None in
  let body = Buffer.create 4096 in
  let complete = ref false in
  let client = H2.Client_connection.create
    ~error_handler:(fun _ -> fail "H2 JSON connection error") () in
  let request = H2.Request.create ~scheme:"http" `GET target
    ~headers:(H2.Headers.of_list ((":authority", "localhost:8935") :: headers)) in
  let writer = H2.Client_connection.request client request
    ~error_handler:(fun _ -> fail "H2 JSON stream error")
    ~response_handler:(fun reply reader ->
      response := Some (H2.Status.to_code reply.H2.Response.status, H2.Headers.to_list reply.headers);
      let rec consume () = H2.Body.Reader.schedule_read reader
        ~on_eof:(fun () -> complete := true)
        ~on_read:(fun buffer ~off ~len ->
          Buffer.add_string body (Bigstringaf.substring buffer ~off ~len);
          consume ()) in
      consume ()) in
  H2.Body.Writer.close writer;
  let server = H2.Server_connection.create handler in
  let transfer next_write report_write read =
    let rec drain progressed = match next_write () with
      | `Write iovecs ->
        let written = List.fold_left (fun total (iov : Bigstringaf.t H2.IOVec.t) ->
          let rec feed off remaining =
            if remaining > 0 then (
              let consumed = read iov.buffer ~off ~len:remaining in
              if consumed <= 0 then fail "H2 JSON transfer made no progress";
              feed (off + consumed) (remaining - consumed))
          in
          feed iov.off iov.len;
          total + iov.len) 0 iovecs in
        report_write (`Ok written);
        drain true
      | `Yield | `Close _ -> progressed
    in
    drain false
  in
  let rec pump () =
    let sent = transfer
      (fun () -> H2.Client_connection.next_write_operation client)
      (H2.Client_connection.report_write_result client) (H2.Server_connection.read server) in
    let received = transfer
      (fun () -> H2.Server_connection.next_write_operation server)
      (H2.Server_connection.report_write_result server) (H2.Client_connection.read client) in
    if !complete then ()
    else if sent || received then pump ()
    else fail "H2 JSON route stalled before response completion"
  in
  pump ();
  match !response with
  | Some (status, headers) -> status, headers, Buffer.contents body
  | None -> fail "H2 JSON route omitted response headers"

let gunzip payload =
  let input = De.bigstring_create De.io_buffer_size in
  let output = De.bigstring_create De.io_buffer_size in
  let decoded = Buffer.create 4096 in
  let consumed = ref 0 in
  let refill buffer =
    let take = min (Bigstringaf.length buffer) (String.length payload - !consumed) in
    Bigstringaf.blit_from_string payload ~src_off:!consumed buffer ~dst_off:0 ~len:take;
    consumed := !consumed + take;
    take
  in
  let flush buffer written = Buffer.add_string decoded (Bigstringaf.substring buffer ~off:0 ~len:written) in
  match Gz.Higher.uncompress ~refill ~flush input output with
  | Ok _ -> Buffer.contents decoded
  | Error (`Msg detail) -> fail detail

type encoder = Inline | Worker

let test_wire_parity () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let pool = Eio.Executor_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
  let extra_headers = ["access-control-allow-origin", "https://dashboard.example";
                       "x-snapshot", "current"] in
  let payload revision = `Assoc ["revision", `Int revision;
                                "text", `String (String.make 8192 'x' ^ " 끝단")] in
  let serve encoder ~compress encoding json =
    wire_response ~headers:["accept-encoding", encoding] "/json"
      ~handler:(fun reqd -> match encoder with
        | Inline -> Response.h2_respond_json_value
            ~status:`Accepted ~extra_headers ~compress reqd json
        | Worker -> Response.h2_respond_json_value_on_cpu
            ~status:`Accepted ~extra_headers ~compress reqd json) in
  List.iter (fun installed ->
    Executor_pool_ref.For_testing.with_pool_option installed @@ fun () ->
    List.iter (fun (encoding, compress, expected_encoding) ->
      let first = payload 1 in
      let old_status, old_headers, old_body =
        serve Inline ~compress encoding first in
      let status, headers, body =
        serve Worker ~compress encoding first in
      check int "status retained" 202 status;
      check int "same status" old_status status;
      check (list (pair string string)) "headers and CORS unchanged" old_headers headers;
      check string "same negotiated response bytes" old_body body;
      check (option string) "encoding negotiated once" expected_encoding
        (List.assoc_opt "content-encoding" headers);
      check (option string) "CORS retained" (Some "https://dashboard.example")
        (List.assoc_opt "access-control-allow-origin" headers);
      check (option string) "wire content length" (Some (string_of_int (String.length body)))
        (List.assoc_opt "content-length" headers);
      let decode bytes = match expected_encoding with
        | Some _ -> gunzip bytes | None -> bytes in
      check string "complete JSON on wire" (Yojson.Safe.to_string first) (decode body);
      let _, _, next_body =
        serve Worker ~compress encoding (payload 2) in
      check string "fresh JSON per call" (Yojson.Safe.to_string (payload 2)) (decode next_body)
    ) ["identity", true, None; "gzip", true, Some "gzip"; "gzip", false, None]
  ) [None; Some pool]

let () = run "H2 worker JSON" ["wire", [
  test_case "identity, gzip, headers and fresh JSON with and without pool" `Quick test_wire_parity]]
