let h2_respond_json ?(status = `OK) ?(extra_headers = []) h2_reqd body =
  let headers =
    H2.Headers.of_list
      ([ "content-type", "application/json; charset=utf-8"
       ; "content-length", string_of_int (String.length body)
       ]
       @ extra_headers)
  in
  let response = H2.Response.create ~headers status in
  let writer =
    H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response
  in
  H2.Body.Writer.write_string writer body;
  H2.Body.Writer.close writer
;;

let h2_respond_text ?(status = `OK) ?(extra_headers = []) h2_reqd body =
  let headers =
    H2.Headers.of_list
      ([ "content-type", "text/plain; charset=utf-8"
       ; "content-length", string_of_int (String.length body)
       ]
       @ extra_headers)
  in
  let response = H2.Response.create ~headers status in
  let writer =
    H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response
  in
  H2.Body.Writer.write_string writer body;
  H2.Body.Writer.close writer
;;

let h2_respond_html ?(status = `OK) ?(extra_headers = []) h2_reqd body =
  let headers =
    H2.Headers.of_list
      ([ "content-type", "text/html; charset=utf-8"
       ; "content-length", string_of_int (String.length body)
       ]
       @ extra_headers)
  in
  let response = H2.Response.create ~headers status in
  let writer =
    H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response
  in
  H2.Body.Writer.write_string writer body;
  H2.Body.Writer.close writer
;;

let h2_respond_bytes ?(status = `OK) ?(extra_headers = []) ~content_type h2_reqd body =
  let headers =
    H2.Headers.of_list
      ([ "content-type", content_type
       ; "content-length", string_of_int (String.length body)
       ]
       @ extra_headers)
  in
  let response = H2.Response.create ~headers status in
  let writer =
    H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response
  in
  H2.Body.Writer.write_string writer body;
  H2.Body.Writer.close writer
;;

let h2_respond_empty ?(status = `No_content) ?(extra_headers = []) h2_reqd =
  let headers = H2.Headers.of_list (("content-length", "0") :: extra_headers) in
  let response = H2.Response.create ~headers status in
  let writer =
    H2.Reqd.respond_with_streaming ~flush_headers_immediately:true h2_reqd response
  in
  H2.Body.Writer.close writer
;;

let h2_read_body h2_reqd callback =
  let body = H2.Reqd.request_body h2_reqd in
  let buf = Buffer.create 4096 in
  let rec read_loop () =
    H2.Body.Reader.schedule_read
      body
      ~on_eof:(fun () -> callback (Buffer.contents buf))
      ~on_read:(fun bigstring ~off ~len ->
        let chunk = Bigstringaf.substring bigstring ~off ~len in
        Buffer.add_string buf chunk;
        read_loop ())
  in
  read_loop ()
;;
