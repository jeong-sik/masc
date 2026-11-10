(* The HTTPS listener (RFC-0512 D6): the certificate material under
   [.masc/tls], and the accept loop choosing the connection handler from the
   ALPN result of a real TLS 1.3 handshake on a loopback port. *)

open Alcotest
module Material = Server_tls_material
module Metrics = Masc.Https_listener_metrics

let rec remove_tree path =
  if Sys.is_directory path
  then (
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Sys.rmdir path)
  else Sys.remove path
;;

let with_tmp_dir f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-https-%d-%d" (Unix.getpid ()) (Random.bits ()))
  in
  Sys.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)
;;

let now () =
  match Ptime.of_float_s (Unix.gettimeofday ()) with
  | Some now -> now
  | None -> fail "the clock is not a representable time"
;;

let days n = Ptime.Span.of_int_s (n * 24 * 3600)

let shift now span =
  match Ptime.add_span now span with
  | Some t -> t
  | None -> fail "time shift overflowed"
;;

let material_or_fail = function
  | Ok material -> material
  | Error error -> fail (Material.error_to_string error)
;;

let self_signed ~now dir =
  material_or_fail
    (Material.load_or_generate
       ~now
       ~base_path:dir
       ~bind_host:"127.0.0.1"
       ~cert_file:None
       ~key_file:None)
;;

let fingerprint (material : Material.t) =
  X509.Certificate.fingerprint `SHA256 (List.hd material.chain)
;;

let file_mode path = (Unix.stat path).Unix.st_perm land 0o777

let test_generate_and_reuse () =
  with_tmp_dir @@ fun dir ->
  let now = now () in
  let first = self_signed ~now dir in
  let cert_path, key_path = Material.self_signed_paths ~base_path:dir in
  check string "source" "self_signed" (Material.source_to_string first.source);
  check int "key mode" 0o600 (file_mode key_path);
  check int "certificate mode" 0o644 (file_mode cert_path);
  let leaf = List.hd first.chain in
  check bool "names localhost" true
    (X509.Certificate.supports_hostname leaf
       (Domain_name.host_exn (Domain_name.of_string_exn "localhost")));
  check bool "names 127.0.0.1" true
    (X509.Certificate.supports_ip leaf (Ipaddr.of_string_exn "127.0.0.1"));
  check bool "names ::1" true
    (X509.Certificate.supports_ip leaf (Ipaddr.of_string_exn "::1"));
  check bool "expires in a year" true
    (Ptime.equal first.not_after (shift now Material.validity));
  let second = self_signed ~now:(shift now (days 1)) dir in
  check string "the next boot reuses the pair" (fingerprint first) (fingerprint second);
  let renewed = self_signed ~now:(shift now (days 340)) dir in
  check bool "within 30 days of expiry a new pair is made" false
    (String.equal (fingerprint first) (fingerprint renewed));
  check bool "the new pair expires a year after that boot" true
    (Ptime.equal renewed.not_after (shift (shift now (days 340)) Material.validity))
;;

let test_configured_pair () =
  with_tmp_dir @@ fun dir ->
  let now = now () in
  let generated = self_signed ~now dir in
  let cert_path, key_path = Material.self_signed_paths ~base_path:dir in
  let configured =
    material_or_fail
      (Material.load_or_generate
         ~now
         ~base_path:dir
         ~bind_host:"0.0.0.0"
         ~cert_file:(Some cert_path)
         ~key_file:(Some key_path))
  in
  check string "source" "configured" (Material.source_to_string configured.source);
  check string "same certificate" (fingerprint generated) (fingerprint configured);
  (match
     Material.load_or_generate
       ~now
       ~base_path:dir
       ~bind_host:"0.0.0.0"
       ~cert_file:(Some cert_path)
       ~key_file:None
   with
   | Ok _ -> fail "a certificate without its key loaded"
   | Error error ->
     check string "only the certificate"
       (Material.error_to_string (Material.Only_cert_configured cert_path))
       (Material.error_to_string error));
  let broken = Filename.concat dir "broken.pem" in
  Out_channel.with_open_bin broken (fun oc -> Out_channel.output_string oc "not pem");
  match
    Material.load_or_generate
      ~now
      ~base_path:dir
      ~bind_host:"0.0.0.0"
      ~cert_file:(Some broken)
      ~key_file:(Some key_path)
  with
  | Ok _ -> fail "a broken certificate file loaded"
  | Error (Material.Invalid_pem { path; reason = _ }) -> check string "path" broken path
  | Error
      (( Material.Only_cert_configured _
       | Material.Only_key_configured _
       | Material.Unreadable _
       | Material.Not_writable _
       | Material.Signing_failed _ ) as error) ->
    fail (Material.error_to_string error)
;;

(* {1 The accept loop} *)

type reply =
  { status : int
  ; body : string
  }

(* The handlers answer the way the live ingress starts: the request authority
   must be admitted by the trust policy built for this listener's port, and it
   must be the listener's own https identity. *)
let trust_policy ~port =
  match
    Server_request_authority.make_trust_policy
      ~bind_host:"127.0.0.1"
      ~bind_port:8935
      ~https_port:(Some port)
      ~explicit_base_url:None
  with
  | Ok policy -> policy
  | Error error -> fail (Server_request_authority.trust_policy_error_to_string error)
;;

let own_identity = function
  | Server_request_authority.Single authority ->
    (match Server_request_authority.scheme authority with
     | Server_request_authority.Https -> `OK
     | Server_request_authority.Http -> `Bad_request)
  | Server_request_authority.Missing
  | Server_request_authority.Multiple
  | Server_request_authority.Malformed
  | Server_request_authority.Untrusted ->
    `Bad_request
;;

let request_handler ~trust_policy _addr (reqd : Httpun.Reqd.t Gluten.Reqd.t) =
  let status =
    own_identity
      (Server_request_authority.classify_http1_request
         ~trust_policy
         (Httpun.Reqd.request reqd.Gluten.Reqd.reqd))
  in
  let headers = Httpun.Headers.of_list [ "content-type", "text/plain"; "content-length", "2" ] in
  Httpun.Reqd.respond_with_string
    reqd.Gluten.Reqd.reqd
    (Httpun.Response.create ~headers status)
    "h1"
;;

let h2_request_handler ~trust_policy ~stream_end:_ _addr reqd =
  let status =
    match
      Server_request_authority.classify_h2_request ~trust_policy (H2.Reqd.request reqd)
    with
    | Server_request_authority.H2_authority classification -> own_identity classification
    | Server_request_authority.Unsupported_asterisk_form_options -> `Bad_request
  in
  H2.Reqd.respond_with_string
    reqd
    (H2.Response.create ~headers:(H2.Headers.of_list [ "content-type", "text/plain" ]) status)
    "h2"
;;

let h2_error_handler _addr ?request:_ _error _respond = fail "unexpected h2 server error"
let authenticator ?ip:_ ~host:_ _chain = Ok None

let tls_client ~sw ~net ~port ~alpn =
  let config =
    match Tls.Config.client ~authenticator ~alpn_protocols:[ alpn ] () with
    | Ok config -> config
    | Error (`Msg reason) -> fail reason
  in
  let flow = Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
  let session = Tls_eio.client_of_flow config flow in
  match Tls_eio.epoch session with
  | Ok epoch -> epoch.Tls.Core.alpn_protocol, Tls_stream_socket.wrap session
  | Error () -> fail "no session after the client handshake"
;;

let h2_get ~sw ~authority socket =
  let closing = ref false in
  let client =
    H2_eio.Client.create_connection
      ~sw
      ~error_handler:(fun _ -> if not !closing then fail "unexpected h2 connection error")
      socket
  in
  let reply, resolve = Eio.Promise.create () in
  let writer =
    H2_eio.Client.request
      client
      (H2.Request.create
         ~scheme:"https"
         `GET
         "/"
         ~headers:(H2.Headers.of_list [ ":authority", authority ]))
      ~error_handler:(fun _ -> fail "unexpected h2 stream error")
      ~response_handler:(fun response reader ->
        let body = Buffer.create 16 in
        let rec read () =
          H2.Body.Reader.schedule_read
            reader
            ~on_eof:(fun () ->
              Eio.Promise.resolve
                resolve
                { status = H2.Status.to_code response.status; body = Buffer.contents body })
            ~on_read:(fun chunk ~off ~len ->
              Buffer.add_string body (Bigstringaf.substring chunk ~off ~len);
              read ())
        in
        read ())
  in
  H2.Body.Writer.close writer;
  let reply = Eio.Promise.await reply in
  closing := true;
  Eio.Promise.await (H2_eio.Client.shutdown client);
  reply
;;

let h1_get ~sw ~host socket =
  let client = Httpun_eio.Client.create_connection ~sw socket in
  let reply, resolve = Eio.Promise.create () in
  let writer =
    Httpun_eio.Client.request
      client
      (Httpun.Request.create ~headers:(Httpun.Headers.of_list [ "host", host ]) `GET "/")
      ~error_handler:(fun _ -> fail "unexpected h1 client error")
      ~response_handler:(fun response reader ->
        let body = Buffer.create 16 in
        let rec read () =
          Httpun.Body.Reader.schedule_read
            reader
            ~on_eof:(fun () ->
              Eio.Promise.resolve
                resolve
                { status = Httpun.Status.to_code response.status; body = Buffer.contents body })
            ~on_read:(fun chunk ~off ~len ->
              Buffer.add_string body (Bigstringaf.substring chunk ~off ~len);
              read ())
        in
        read ())
  in
  Httpun.Body.Writer.close writer;
  let reply = Eio.Promise.await reply in
  Eio.Promise.await (Httpun_eio.Client.shutdown client);
  reply
;;

let metric name = Yojson.Safe.Util.(Metrics.json () |> member name |> to_int)
let status_label () = Yojson.Safe.Util.(Metrics.json () |> member "status" |> to_string)

let test_alpn_dispatch () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  with_tmp_dir @@ fun dir ->
  let material = self_signed ~now:(now ()) dir in
  let tls =
    match Material.tls_config material with
    | Ok tls -> tls
    | Error reason -> fail reason
  in
  let net = Eio.Stdenv.net env in
  let socket =
    Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:8 (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix _ -> fail "a TCP socket has a port"
  in
  let trust_policy = trust_policy ~port in
  let accepted = metric "accepted_total" in
  let h2 = metric "alpn_h2_total" in
  let http1 = metric "alpn_http1_total" in
  let failures = metric "handshake_failures_total" in
  let alpn_h2, alpn_http1 =
    Eio.Fiber.first
      (fun () ->
        Eio.Switch.run (fun server_sw ->
          Server_bootstrap_http.serve_tls
            ~sw:server_sw
            ~clock:(Eio.Stdenv.clock env)
            ~socket
            ~addr_label:(Printf.sprintf "127.0.0.1:%d" port)
            ~tls
            ~request_handler:(request_handler ~trust_policy)
            ~h2_request_handler:(h2_request_handler ~trust_policy)
            ~h2_error_handler;
          fail "the accept loop returned"))
      (fun () ->
        (* The authority a client of this listener sends: the loopback host
           and the listener's own port, over https. *)
        let authority = Printf.sprintf "127.0.0.1:%d" port in
        let alpn_h2, h2_socket = tls_client ~sw ~net ~port ~alpn:"h2" in
        let h2_reply = h2_get ~sw ~authority h2_socket in
        check int "h2 status" 200 h2_reply.status;
        check string "h2 handler answered" "h2" h2_reply.body;
        let alpn_http1, h1_socket = tls_client ~sw ~net ~port ~alpn:"http/1.1" in
        let h1_reply = h1_get ~sw ~host:(Printf.sprintf "localhost:%d" port) h1_socket in
        check int "http/1.1 status" 200 h1_reply.status;
        check string "httpun handler answered" "h1" h1_reply.body;
        (* The cleartext port's authority is not this listener's. *)
        let _, stranger_socket = tls_client ~sw ~net ~port ~alpn:"h2" in
        let stranger = h2_get ~sw ~authority:"127.0.0.1:8935" stranger_socket in
        check int "the cleartext authority is refused on the TLS listener" 400 stranger.status;
        (* A cleartext request on the TLS port is read as a record header. The
           TLS reader checks the length before the content type (tls
           reader.ml, parse_record) and waits for the 8,239 bytes that "GET /"
           spells, so the peer gives up; the listener counts the handshake
           that ended at the peer's EOF. *)
        let raw = Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
        Eio.Flow.copy_string "GET / HTTP/1.1\r\nhost: localhost\r\n\r\n" raw;
        Eio.Flow.shutdown raw `Send;
        (match Eio.Flow.single_read raw (Cstruct.create 64) with
         | _ -> ()
         | exception End_of_file -> ()
         | exception Eio.Io _ -> ());
        (* The accept loop records Listening when it starts and Stopped when
           its switch releases. Fiber.first cancels it once this fiber
           returns, so the live status is read here. *)
        check string "listener status while serving" "listening" (status_label ());
        alpn_h2, alpn_http1)
  in
  check (option string) "server chose h2" (Some "h2") alpn_h2;
  check (option string) "server chose http/1.1" (Some "http/1.1") alpn_http1;
  check string "listener status after the accept loop ends" "stopped" (status_label ());
  check int "four connections accepted" (accepted + 4) (metric "accepted_total");
  check int "two h2 negotiations" (h2 + 2) (metric "alpn_h2_total");
  check int "one http/1.1 negotiation" (http1 + 1) (metric "alpn_http1_total");
  check int "one handshake failure" (failures + 1) (metric "handshake_failures_total")
;;

let test_h2_settings () =
  let config = Server_bootstrap_http.h2_config () in
  check bool "server push is never advertised" false config.H2.Config.enable_server_push;
  check int32 "stream limit" 100l config.H2.Config.max_concurrent_streams;
  check int32 "initial window is the h2 library default"
    H2.Config.default.initial_window_size config.H2.Config.initial_window_size;
  check int32 "the library default is 2^27, not the RFC 9113 65,535"
    (Int32.shift_left 1l 27) config.H2.Config.initial_window_size;
  check int "largest frame is the library default"
    H2.Config.default.read_buffer_size config.H2.Config.read_buffer_size;
  check int "the library default is the RFC 9113 minimum 16,384"
    16384 config.H2.Config.read_buffer_size
;;

let () =
  run
    "HTTPS listener"
    [ ( "material"
      , [ test_case "self-signed pair: generate, reuse, renew" `Quick test_generate_and_reuse
        ; test_case "configured pair and its refusals" `Quick test_configured_pair
        ] )
    ; ( "listener"
      , [ test_case "ALPN picks h2 or httpun" `Quick test_alpn_dispatch
        ; test_case "h2 settings: push off, library defaults" `Quick test_h2_settings
        ] )
    ]
;;
