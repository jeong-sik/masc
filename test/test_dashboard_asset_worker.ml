open Alcotest

type response = { status : int; headers : (string * string) list; body : string }

(* The server keeps the compressed form of an asset by name and content, and
   the cases share one process, so each case serves bytes of its own. *)
let asset_body_of case =
  String.concat "" (List.init 1000 (fun _ -> "export const text = '한글🙂 " ^ case ^ "';\n"))
let tiny_body = "export {};"
let slow_path = "/dashboard/assets/slow.js"

let rec remove_tree path =
  if Sys.is_directory path then (
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path)
  else Sys.remove path

let with_assets ~asset_body f =
  let root = Filename.temp_file "masc-asset-worker" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let previous_fs = Fs_compat.get_fs_opt () in
  Fun.protect ~finally:(fun () ->
    (match previous_fs with None -> Fs_compat.clear_fs () | Some fs -> Fs_compat.set_fs fs);
    remove_tree root) (fun () ->
    let dashboard = Filename.concat root "dashboard" in
    let assets = Filename.concat dashboard "assets" in
    Unix.mkdir dashboard 0o700;
    Unix.mkdir assets 0o700;
    List.iter (fun (name, body) ->
      Out_channel.with_open_bin (Filename.concat assets name)
        (fun ch -> Out_channel.output_string ch body))
      ["slow.js", asset_body; "identity.js", asset_body;
       "image.png", asset_body; "tiny.js", tiny_body];
    (* Inline reads of this small local fixture make route admission a
       deterministic boundary: only compression can suspend before the
       responder writes. File I/O scheduling is outside this regression. *)
    Fs_compat.clear_fs ();
    Masc_test_deps.with_process_env "MASC_ASSETS_DIR" (Some root) f)

(* The pool's one worker is held until [release ()]. [hold_next ()] puts a
   second hold in the pool's queue, behind what was submitted before it and
   ahead of what comes after; it lasts until the end of the case. *)
let with_occupied_pool f =
  Eio_main.run @@ fun env ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:1 env#domain_mgr in
  let previous = Domain_pool_ref.get () in
  Eio.Switch.on_release sw (fun () ->
    match previous with
    | None -> Domain_pool_ref.clear_for_tests ()
    | Some pool -> Domain_pool_ref.set pool);
  Domain_pool_ref.set pool;
  let releases = ref [] in
  let hold () =
    let occupied, occupy = Eio.Promise.create () in
    let released, release_worker = Eio.Promise.create () in
    let release () =
      if not (Eio.Promise.is_resolved released) then Eio.Promise.resolve release_worker () in
    releases := release :: !releases;
    Eio.Fiber.fork ~sw (fun () ->
      Domain_pool.submit_cpu ~name:__FUNCTION__ pool (fun () ->
        Eio.Promise.resolve occupy ();
        Eio.Promise.await released));
    occupied, release in
  Fun.protect ~finally:(fun () -> List.iter (fun release -> release ()) !releases) (fun () ->
    let occupied, release = hold () in
    Eio.Promise.await occupied;
    let hold_next () = ignore (hold () : unit Eio.Promise.t * (unit -> unit)) in
    f ~sw ~release ~hold_next)

let gunzip payload =
  let input = De.bigstring_create De.io_buffer_size in
  let output = De.bigstring_create De.io_buffer_size in
  let decoded = Buffer.create 4096 in
  let consumed = ref 0 in
  let refill buffer =
    let take = min (Bigstringaf.length buffer) (String.length payload - !consumed) in
    Bigstringaf.blit_from_string payload ~src_off:!consumed buffer ~dst_off:0 ~len:take;
    consumed := !consumed + take;
    take in
  let flush buffer written =
    Buffer.add_string decoded (Bigstringaf.substring buffer ~off:0 ~len:written) in
  match Gz.Higher.uncompress ~refill ~flush input output with
  | Ok _ -> Buffer.contents decoded
  | Error (`Msg detail) -> fail detail

let check_response ~encoding ~content_type expected response =
  check int "status" 200 response.status;
  check (option string) "content type" (Some content_type)
    (List.assoc_opt "content-type" response.headers);
  check (option string) "immutable asset cache control"
    (Some "public, max-age=31536000, immutable")
    (List.assoc_opt "cache-control" response.headers);
  check (option string) "length describes transmitted bytes"
    (Some (string_of_int (String.length response.body)))
    (List.assoc_opt "content-length" response.headers);
  check (option string) "content encoding" encoding
    (List.assoc_opt "content-encoding" response.headers);
  let decoded = match encoding with
    | None -> response.body
    | Some "gzip" -> gunzip response.body
    | Some "zstd" ->
      (match Compression_codec.decompress ~orig_size:(String.length expected) response.body with
       | Ok body -> body | Error detail -> fail detail)
    | Some other -> failf "unsupported fixture encoding %s" other in
  check string "exact decoded asset" expected decoded

let exercise ~asset_body ~encoding ~send ~progress ~started ~finished ~release ~hold_next =
  let slow = send slow_path encoding in
  Eio.Promise.await started;
  (* The route has no earlier suspension (see with_assets). A direct codec
     would already have returned; a CPU submit waits for our held worker. *)
  check bool "asset compression waits off the request domain" false
    (Eio.Promise.is_resolved finished);
  progress ();
  (* A second request of the same asset, behind a hold that queued after the
     first one's compression. It is answered by that one compression; one of
     its own would wait behind the hold until the case's timeout. *)
  hold_next ();
  let second = send slow_path encoding in
  List.iter (fun (name, accept, body, content_type, vary) ->
    let response = Eio.Promise.await_exn (send ("/dashboard/assets/" ^ name) accept) in
    check_response ~encoding:None ~content_type body response;
    check (option string) "Vary policy on bypass" vary
      (List.assoc_opt "vary" response.headers))
    [ "identity.js", "identity", asset_body, "application/javascript; charset=utf-8", Some "Accept-Encoding"
    ; "image.png", encoding, asset_body, "image/png", None
    ; "tiny.js", encoding, tiny_body, "application/javascript; charset=utf-8", Some "Accept-Encoding"
    ];
  check bool "worker stays occupied while sibling requests complete" false
    (Eio.Promise.is_resolved finished);
  release ();
  let response = Eio.Promise.await_exn slow in
  check_response ~encoding:(Some encoding)
    ~content_type:"application/javascript; charset=utf-8" asset_body response;
  check (option string) "compressed asset Vary" (Some "Accept-Encoding")
    (List.assoc_opt "vary" response.headers);
  check_response ~encoding:(Some encoding)
    ~content_type:"application/javascript; charset=utf-8" asset_body
    (Eio.Promise.await_exn second);
  (* The worker is held again by now, so a request after the compression is
     answered from what it left. *)
  check_response ~encoding:(Some encoding)
    ~content_type:"application/javascript; charset=utf-8" asset_body
    (Eio.Promise.await_exn (send slow_path encoding))

let test_h1 encoding () =
  let asset_body = asset_body_of ("HTTP/1 " ^ encoding) in
  with_assets ~asset_body @@ fun () ->
  with_occupied_pool @@ fun ~sw ~release ~hold_next ->
  let started, start = Eio.Promise.create () in
  let finished, finish = Eio.Promise.create () in
  let send path encoding = Eio.Fiber.fork_promise ~sw (fun () ->
    Eio.Switch.run @@ fun conn_sw ->
    let server_flow, client_flow = Eio_unix.Net.socketpair_stream ~sw:conn_sw () in
    Eio.Fiber.fork_daemon ~sw:conn_sw (fun () ->
      Httpun_eio.Server.create_connection_handler ~sw:conn_sw
        ~request_handler:(fun _ wrapped ->
          let request = Httpun.Reqd.request wrapped.Gluten.Reqd.reqd in
          let reqd = Masc.Http_reqd.of_gluten wrapped in
          if String.equal path slow_path then ignore (Eio.Promise.try_resolve start () : bool);
          Server_routes_http_pages.serve_dashboard_static
            ("assets/" ^ Filename.basename path) request reqd;
          if String.equal path slow_path then ignore (Eio.Promise.try_resolve finish () : bool))
        ~error_handler:(fun _ ?request:_ _ _ -> fail "unexpected HTTP/1 server error")
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321)) server_flow;
      `Stop_daemon);
    let client = Httpun_eio.Client.create_connection ~sw:conn_sw client_flow in
    let reply, resolve = Eio.Promise.create () in
    let writer = Httpun_eio.Client.request client
      (Httpun.Request.create ~headers:(Httpun.Headers.of_list
        ["host", "localhost"; "accept-encoding", encoding]) `GET path)
      ~error_handler:(fun _ -> fail "unexpected HTTP/1 client error")
      ~response_handler:(fun response reader ->
        let body = Buffer.create 256 in
        let rec read () = Httpun.Body.Reader.schedule_read reader
          ~on_eof:(fun () -> Eio.Promise.resolve resolve
            { status = Httpun.Status.to_code response.status;
              headers = Httpun.Headers.to_list response.headers; body = Buffer.contents body })
          ~on_read:(fun chunk ~off ~len ->
            Buffer.add_string body (Bigstringaf.substring chunk ~off ~len); read ()) in
        read ()) in
    Httpun.Body.Writer.close writer;
    let response = Eio.Promise.await reply in
    Eio.Promise.await (Httpun_eio.Client.shutdown client);
    response) in
  exercise ~asset_body ~encoding ~send ~progress:(fun () -> ()) ~started ~finished ~release ~hold_next

let test_h2 encoding () =
  let asset_body = asset_body_of ("HTTP/2 " ^ encoding) in
  with_assets ~asset_body @@ fun () ->
  with_occupied_pool @@ fun ~sw ~release ~hold_next ->
  let started, start = Eio.Promise.create () in
  let finished, finish = Eio.Promise.create () in
  let handler ~stream_end _ h2_reqd =
    let path = (H2.Reqd.request h2_reqd).target in
    if String.equal path slow_path then ignore (Eio.Promise.try_resolve start () : bool);
    let reqd = Masc.Http_reqd.of_h2 ~stream_end
      ~ledger:(Masc.Http_h2_response_ledger.current_exn ()) h2_reqd in
    Server_routes_http_pages.serve_dashboard_static
      ("assets/" ^ Filename.basename path) (Masc.Http_reqd.request reqd) reqd;
    if String.equal path slow_path then ignore (Eio.Promise.try_resolve finish () : bool) in
  let server_flow, client_flow = Eio_unix.Net.socketpair_stream ~sw () in
  let server = Eio.Fiber.fork_promise ~sw (fun () ->
    Eio.Switch.run @@ fun conn_sw ->
    (* A clock nobody moves: no response flush stalls in this test. *)
    Server_bootstrap_http.serve_h2_connection ~clock:(Eio_mock.Clock.make ()) ~sw:conn_sw
      ~h2_request_handler:handler ~h2_error_handler:(Server_h2_gateway.make_error_handler ())
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321)) server_flow) in
  let closing = ref false in
  let client = H2_eio.Client.create_connection ~sw
    ~error_handler:(fun _ -> if not !closing then fail "unexpected H2 connection error")
    client_flow in
  let send path encoding = Eio.Fiber.fork_promise ~sw (fun () ->
    let reply, resolve = Eio.Promise.create () in
    let writer = H2_eio.Client.request client
      (H2.Request.create ~scheme:"http" `GET path
        ~headers:(H2.Headers.of_list [":authority", "localhost"; "accept-encoding", encoding]))
      ~error_handler:(fun _ -> fail "unexpected H2 stream error")
      ~response_handler:(fun response reader ->
        let body = Buffer.create 256 in
        let rec read () = H2.Body.Reader.schedule_read reader
          ~on_eof:(fun () -> Eio.Promise.resolve resolve
            { status = H2.Status.to_code response.status;
              headers = H2.Headers.to_list response.headers; body = Buffer.contents body })
          ~on_read:(fun chunk ~off ~len ->
            Buffer.add_string body (Bigstringaf.substring chunk ~off ~len); read ()) in
        read ()) in
    H2.Body.Writer.close writer;
    Eio.Promise.await reply) in
  let progress () =
    match Eio.Promise.await (H2_eio.Client.ping client) with
    | Ok () -> () | Error `EOF -> fail "H2 closed before PING acknowledgement" in
  exercise ~asset_body ~encoding ~send ~progress ~started ~finished ~release ~hold_next;
  closing := true;
  (* The client reader owns an in-flight read. Shutdown reaches the peer
     immediately; close alone can wait for that read before closing the FD. *)
  Eio.Flow.shutdown client_flow `All;
  Eio.Promise.await_exn server

let () = run "Dashboard asset worker"
  [ "HTTP/1", List.map (fun encoding -> test_case encoding `Quick (test_h1 encoding)) ["gzip"; "zstd"]
  ; "HTTP/2", List.map (fun encoding -> test_case encoding `Quick (test_h2 encoding)) ["gzip"; "zstd"]
  ]
