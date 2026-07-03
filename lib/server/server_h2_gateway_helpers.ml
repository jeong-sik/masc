let maybe_compress ?(compress = true) h2_reqd body =
  let req = H2.Reqd.request h2_reqd in
  Http_response_payload.compress_body
    ~compress
    ~accept_encoding:(H2.Headers.get req.headers "accept-encoding")
    body

let h2_respond_body
    ?(status = `OK)
    ?(extra_headers = [])
    ?(compress = true)
    ~content_type
    h2_reqd
    body =
  let final_body, compression_headers = maybe_compress ~compress h2_reqd body in
  let headers = H2.Headers.of_list ([
    ("content-type", content_type);
    ("content-length", string_of_int (String.length final_body));
  ] @ compression_headers @ extra_headers) in
  let response = H2.Response.create ~headers status in
  let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
  H2.Body.Writer.write_string writer final_body;
  H2.Body.Writer.close writer

let h2_respond_json_string ?status ?extra_headers ?(compress = true) h2_reqd body =
  h2_respond_body
    ?status
    ?extra_headers
    ~compress
    ~content_type:"application/json; charset=utf-8"
    h2_reqd
    body

let h2_respond_json ?status ?extra_headers ?compress h2_reqd body =
  h2_respond_json_string ?status ?extra_headers ?compress h2_reqd body

let h2_respond_json_value ?status ?extra_headers ?compress h2_reqd json =
  h2_respond_json_string ?status ?extra_headers ?compress h2_reqd
    (Yojson.Safe.to_string json)

let h2_respond_text ?(status = `OK) ?(extra_headers = []) h2_reqd body =
  h2_respond_body
    ~status
    ~extra_headers
    ~compress:true
    ~content_type:"text/plain; charset=utf-8"
    h2_reqd
    body

let h2_respond_html ?(status = `OK) ?(extra_headers = []) h2_reqd body =
  h2_respond_body
    ~status
    ~extra_headers
    ~compress:true
    ~content_type:"text/html; charset=utf-8"
    h2_reqd
    body

let h2_respond_bytes
    ?(status = `OK)
    ?(extra_headers = [])
    ?(compress = false)
    ~content_type
    h2_reqd
    body =
  h2_respond_body ~status ~extra_headers ~compress ~content_type h2_reqd body

let h2_respond_empty ?(status = `No_content) ?(extra_headers = []) h2_reqd =
  let headers = H2.Headers.of_list (("content-length", "0") :: extra_headers) in
  let response = H2.Response.create ~headers status in
  let writer = H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response in
  H2.Body.Writer.close writer

let h2_respond_removed_surface h2_reqd ~surface ~extra_headers =
  h2_respond_json_value
    ~status:`Gone
    h2_reqd
    (`Assoc
       [
         ("error", `String "removed_surface");
         ("surface", `String surface);
         ( "message",
           `String
             "This compatibility surface was removed. Keepers and local clients should use the OAS-backed repo workspace front door."
         );
       ])
    ~extra_headers

let h2_read_body h2_reqd callback =
  let body = H2.Reqd.request_body h2_reqd in
  let buf = Http_body_buffer.create 4096 in
  let rec read_loop () =
    H2.Body.Reader.schedule_read body
      ~on_eof:(fun () -> callback (Http_body_buffer.contents buf))
      ~on_read:(fun bigstring ~off ~len ->
        Http_body_buffer.add_bigstring buf bigstring ~off ~len;
        read_loop ())
  in
  read_loop ()
