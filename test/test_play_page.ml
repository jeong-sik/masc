(* RFC play-link-for-the-shared-machine §2.6 through the real router: the
   play page is public and self-contained, and the seat names the bearer, the
   controller and whom it can be handed to. *)

open Alcotest
module Page = Server_routes_http_routes_play_page
module Guide = Server_routes_http_routes_play_guide

let remove_tree path =
  let rec go path =
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
      Array.iter (fun name -> go (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end
    else Unix.unlink path
  in
  go path

let with_dir prefix f =
  let dir = Filename.temp_dir prefix "" in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)

let loopback_request_authority () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> fail "failed to construct loopback request authority"

let dispatch_get ~state ~target ~token =
  Server_request_authority.with_current (loopback_request_authority ()) (fun () ->
    let router = Guide.add_routes (Page.add_routes (Masc.Http_server_eio.Router.create ())) in
    Server_auth.publish_server_state state;
    let response_buf = Buffer.create 4096 in
    let conn =
      Httpun.Server_connection.create (fun reqd ->
        Masc.Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
    in
    let request_str =
      Printf.sprintf "GET %s HTTP/1.1\r\nHost: 127.0.0.1:8935\r\nOrigin: http://127.0.0.1:8935\r\n%s\r\n"
        target
        (match token with
         | Some token -> Printf.sprintf "Authorization: Bearer %s\r\n" token
         | None -> "")
    in
    let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length request_str) request_str in
    ignore (Httpun.Server_connection.read_eof conn bytes ~off:0 ~len:(Bigstringaf.length bytes));
    let rec flush () =
      match Httpun.Server_connection.next_write_operation conn with
      | `Write iovecs ->
        let written =
          List.fold_left
            (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
              Buffer.add_string response_buf
                (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
              total + iov.len)
            0 iovecs
        in
        Httpun.Server_connection.report_write_result conn (`Ok written);
        flush ()
      | `Yield | `Close _ -> ()
    in
    flush ();
    Server_auth.clear_server_state ();
    Buffer.contents response_buf)

type h2_reply = { h2_status : int; h2_headers : H2.Headers.t; h2_body : string }

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
            Buffer.add_string chunk
              (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
            total + iov.len)
          0 iovecs
      in
      report_write (`Ok written);
      let data = Buffer.contents chunk in
      let length = String.length data in
      let consumed =
        read (Bigstringaf.of_string data ~off:0 ~len:length) ~off:0 ~len:length
      in
      lane.pending <- String.sub data consumed (length - consumed);
      drain true
    | `Yield | `Close _ -> progressed
  in
  drain false

(* Real H2 frames, including response body completion, through the gateway.
   Stop with a failure if neither peer advances rather than hanging. *)
let exchange_h2 ~handler target =
  let status = ref None in
  let headers = ref (H2.Headers.of_list []) in
  let body = Buffer.create 4096 in
  let complete = ref false in
  let client =
    H2.Client_connection.create
      ~config:
        { H2.Config.default with
          H2.Config.initial_window_size = 65535l
        }
      ~error_handler:(fun _ -> fail "H2 connection error")
      ()
  in
  let request =
    H2.Request.create ~scheme:"http" `GET target
      ~headers:(H2.Headers.of_list [ ":authority", "127.0.0.1:8935" ])
  in
  let writer =
    H2.Client_connection.request client request
      ~error_handler:(fun _ -> fail "H2 stream error")
      ~response_handler:(fun response reader ->
        status := Some (H2.Status.to_code response.H2.Response.status);
        headers := response.H2.Response.headers;
        let rec consume () =
          H2.Body.Reader.schedule_read reader
            ~on_eof:(fun () -> complete := true)
            ~on_read:(fun buffer ~off ~len ->
              Buffer.add_string body (Bigstringaf.substring buffer ~off ~len);
              consume ())
        in
        consume ())
  in
  H2.Body.Writer.close writer;
  let server = H2.Server_connection.create handler in
  let to_server = { pending = "" } in
  let to_client = { pending = "" } in
  let rec pump () =
    let sent =
      transfer to_server
        (fun () -> H2.Client_connection.next_write_operation client)
        (H2.Client_connection.report_write_result client)
        (H2.Server_connection.read server)
    in
    let received =
      transfer to_client
        (fun () -> H2.Server_connection.next_write_operation server)
        (H2.Server_connection.report_write_result server)
        (H2.Client_connection.read client)
    in
    if !complete then ()
    else if sent || received then pump ()
    else fail "H2 exchange stalled before the response completed"
  in
  pump ();
  match !status with
  | Some status -> { h2_status = status; h2_headers = !headers; h2_body = Buffer.contents body }
  | None -> fail "the response carried no headers"

let split_response response =
  let separator = "\r\n\r\n" in
  let rec find i =
    if i + 4 > String.length response then failf "no body in %S" response
    else if String.sub response i 4 = separator then i
    else find (i + 1)
  in
  let at = find 0 in
  String.sub response 0 at, String.sub response (at + 4) (String.length response - at - 4)

let status_of response =
  match String.split_on_char ' ' response with
  | _ :: status :: _ -> int_of_string status
  | _ -> failf "could not parse response status: %S" response

let header name head =
  let prefix = String.lowercase_ascii name ^ ":" in
  String.split_on_char '\n' head
  |> List.find_map (fun line ->
    let line = String.trim line in
    if String.length line > String.length prefix
       && String.lowercase_ascii (String.sub line 0 (String.length prefix)) = prefix
    then Some (String.trim (String.sub line (String.length prefix) (String.length line - String.length prefix)))
    else None)

let contains ~sub s =
  let n = String.length sub and m = String.length s in
  let rec at i = i + n <= m && (String.sub s i n = sub || at (i + 1)) in
  at 0

let count ~sub s =
  let n = String.length sub and m = String.length s in
  let rec go i acc = if i + n > m then acc else if String.sub s i n = sub then go (i + n) (acc + 1) else go (i + 1) acc in
  go 0 0

let token_for base_path ~agent_name ~role =
  match Auth.create_token base_path ~agent_name ~role with
  | Ok (token, _) -> token
  | Error err -> failf "create_token failed: %s" (Masc_domain.masc_error_to_string err)

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let hello_com = "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$"

let test_the_page_is_public_and_self_contained () =
  check bool "/play is a public read path" true (Server_auth.is_public_read_path Server_auth.play_page_path);
  check bool "nothing under it is" false (Server_auth.is_public_read_path (Server_auth.play_page_path ^ "/x"));
  with_dir "play-page-" (fun base_path ->
    Auth.save_auth_config base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let state = Masc.Mcp_server.For_testing.create_state ~base_path in
    Eio_main.run (fun env ->
      Masc_test_deps.init_eio_clock env;
      let get () = dispatch_get ~state ~target:Server_auth.play_page_path ~token:None in
      let first = get () in
      check int "the page needs no bearer" 200 (status_of first);
      let head, body = split_response first in
      check (option string) "it is HTML" (Some "text/html; charset=utf-8") (header "content-type" head);
      check (option string) "it sends no referrer" (Some "no-referrer") (header "referrer-policy" head);
      let csp =
        match header "content-security-policy" head with
        | Some csp -> csp
        | None -> fail "no CSP"
      in
      let nonce =
        match String.index_opt csp '\'' with
        | Some _ ->
          let marker = "'nonce-" in
          let rec find i =
            if String.sub csp i (String.length marker) = marker then i + String.length marker else find (i + 1)
          in
          let start = find 0 in
          String.sub csp start (String.index_from csp start '\'' - start)
        | None -> fail "no nonce in the CSP"
      in
      check string "the CSP is the one the page is built with" (Page.csp_header nonce) csp;
      check int "the nonce is on the one script and the one style" 2
        (count ~sub:(Printf.sprintf "nonce=\"%s\"" nonce) body);
      check int "one script tag" 1 (count ~sub:"<script" body);
      check bool "no script is loaded from anywhere" false (contains ~sub:" src=" body);
      check bool "no stylesheet is linked" false (contains ~sub:"<link" body);
      check bool "an agent that reads the page finds the guide" true
        (contains ~sub:(Printf.sprintf "href=\"%s\"" Masc.Play_invite.agent_guide_path) body);
      let second_head, _ = split_response (get ()) in
      check bool "every response has its own nonce" true
        (header "content-security-policy" second_head <> Some csp)))

let public_base = "https://play.example"

let test_the_guide_names_this_servers_doors () =
  check bool "the guide is a public read path" true
    (Server_auth.is_public_read_path Masc.Play_invite.agent_guide_path);
  with_dir "play-guide-" (fun base_path ->
    Auth.save_auth_config base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let state = Masc.Mcp_server.For_testing.create_state ~base_path in
    Eio_main.run (fun env ->
      Masc_test_deps.init_eio_clock env;
      let get () = dispatch_get ~state ~target:Masc.Play_invite.agent_guide_path ~token:None in
      Masc_test_deps.with_process_env "MASC_HTTP_BASE_URL" None (fun () ->
        let response = get () in
        check int "no public base URL, no address to join at" 409 (status_of response);
        check bool "named as not ready" true
          (member "code" (Yojson.Safe.from_string (snd (split_response response)))
           = Some (`String "not_ready"));
        check bool "the refusal explains why" true
          (member "error" (Yojson.Safe.from_string (snd (split_response response)))
           = Some (`String "MASC_HTTP_BASE_URL is not set, so there is no address to join at")));
      Masc_test_deps.with_process_env "MASC_HTTP_BASE_URL" (Some public_base) (fun () ->
        let response = get () in
        check int "the guide needs no bearer" 200 (status_of response);
        let head, body = split_response response in
        check (option string) "it is markdown" (Some "text/markdown; charset=utf-8")
          (header "content-type" head);
        check bool "every template variable is filled" false (contains ~sub:"{{" body);
        List.iter
          (fun url -> check bool url true (contains ~sub:url body))
          [ public_base ^ "/mcp/play"
          ; public_base ^ Page.seat_path
          ; public_base ^ Server_routes_http_routes_play_screen.screen_path
          ];
        List.iter
          (fun (path, (schema : Masc_domain.tool_schema)) ->
            check bool ("the move route " ^ path) true
              (contains ~sub:(Printf.sprintf "`POST %s%s`" public_base path) body);
            check bool ("the arguments of " ^ schema.name) true
              (contains ~sub:(Yojson.Safe.pretty_to_string schema.input_schema) body))
          Server_routes_http_routes_dos.moves)))

let test_the_guide_over_h2 () =
  with_dir "play-guide-h2-" (fun base_path ->
    Auth.save_auth_config base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let state = Masc.Mcp_server.For_testing.create_state ~base_path in
    Server_auth.publish_server_state state;
    Fun.protect ~finally:Server_auth.clear_server_state (fun () ->
      Eio_main.run (fun env ->
        Masc_test_deps.init_eio_clock env;
        Eio.Switch.run (fun sw ->
          let trust_policy =
            match Server_request_authority.make_trust_policy
                    ~bind_host:"127.0.0.1" ~bind_port:8935 ~explicit_base_url:None with
            | Ok policy -> policy
            | Error error -> fail (Server_request_authority.trust_policy_error_to_string error)
          in
          let handler =
            Server_h2_gateway.make_request_handler ~trust_policy ~sw
              ~clock:(Eio.Stdenv.clock env) ~server_start_time:0.0 ~request_sw:sw
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321))
          in
          let get target = exchange_h2 ~handler target in
          Masc_test_deps.with_process_env "MASC_HTTP_AUTH_STRICT" (Some "1") (fun () ->
            Masc_test_deps.with_process_env "MASC_HTTP_BASE_URL" None (fun () ->
              let reply = get Masc.Play_invite.agent_guide_path in
              check int "H2 reports missing public address" 409 reply.h2_status;
              let json = Yojson.Safe.from_string reply.h2_body in
              check bool "H2 refusal code" true
                (member "code" json = Some (`String "not_ready"));
              check bool "H2 readable refusal" true
                (member "error" json = Some (`String
                  "MASC_HTTP_BASE_URL is not set, so there is no address to join at")));
            Masc_test_deps.with_process_env "MASC_HTTP_BASE_URL" (Some public_base) (fun () ->
              let reply = get Masc.Play_invite.agent_guide_path in
              check int "H2 guide is public even with strict auth" 200 reply.h2_status;
              List.iter (fun (name, value) ->
                check (option string) name (Some value) (H2.Headers.get reply.h2_headers name))
                [ "content-type", "text/markdown; charset=utf-8"
                ; "cache-control", "no-store"
                ; "x-content-type-options", "nosniff" ];
              (match Guide.guide ~base:public_base with
               | Ok expected -> check string "same rendered guide" expected reply.h2_body
               | Error reason -> fail reason);
              check int "guide suffix is not another public guide" 404
                (get (Masc.Play_invite.agent_guide_path ^ "/x")).h2_status))))))

let test_the_seat () =
  with_dir "play-seat-" (fun base_path ->
    Auth.save_auth_config base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let _operator = token_for base_path ~agent_name:"operator" ~role:Masc_domain.Admin in
    let _worker = token_for base_path ~agent_name:"codex" ~role:Masc_domain.Worker in
    let player = token_for base_path ~agent_name:"minsu" ~role:Masc_domain.Player in
    let state = Masc.Mcp_server.For_testing.create_state ~base_path in
    Eio_main.run (fun env ->
      Masc_test_deps.init_eio_clock env;
      let seat token = dispatch_get ~state ~target:Page.seat_path ~token in
      check int "the seat needs a bearer" 401 (status_of (seat None));
      let read () =
        let response = seat (Some player) in
        check int "a player reads its seat" 200 (status_of response);
        Yojson.Safe.from_string (snd (split_response response))
      in
      let answer = read () in
      check bool "the bearer's name" true (member "name" answer = Some (`String "minsu"));
      check bool "no machine" true (member "machine" answer = Some (`Bool false));
      check bool "nobody holds it" true (member "controller" answer = Some `Null);
      check bool "no saves name without a machine" true (member "saves_name" answer = Some `Null);
      check bool "operators and invites, not agents' clients" true
        (member "participants" answer = Some (`List [ `String "minsu"; `String "operator" ]));
      let dir = Filename.temp_dir "play-seat-dos-" "" in
      Fun.protect
        ~finally:(fun () ->
          (match Dos_lane.eject ~who:"minsu" ~announce:ignore () with
           | Ok () | Error _ -> ());
          (match Dos_lane.eject ~who:"operator" ~announce:ignore () with
           | Ok () | Error _ -> ());
          remove_tree dir)
        (fun () ->
          (match
             Dos_lane.load ~who:"operator" ~ledger_dir:(Filename.concat dir "ledger")
               ~saves_dir:(Filename.concat dir "saves")
               ~checkpoint_dir:(Filename.concat dir "checkpoints") ~program_name:"game.com"
               ~program_bytes:hello_com ~files:[] ~announce:ignore
           with
           | Ok _ -> ()
           | Error e -> fail ("load: " ^ Dos_lane.error_to_string e));
          (match Dos_lane.pass ~who:"operator" ~to_:(Some "minsu") ~announce:ignore with
           | Ok _ -> ()
           | Error e -> fail ("pass: " ^ Dos_lane.error_to_string e));
          let answer = read () in
          check bool "a machine" true (member "machine" answer = Some (`Bool true));
          check bool "the invite holds the controller" true
            (member "controller" answer = Some (`String "minsu"));
          check bool "the saves name the pad layout is found by" true
            (member "saves_name" answer = Some (`String "saves")))))

let test_expired_credentials_are_not_seats () =
  with_dir "play-seat-expiry-" (fun base_path ->
    let _ =
      Auth.create_token_expiring_in base_path ~agent_name:"minsu" ~role:Masc_domain.Player ~hours:1
    in
    let _ =
      Auth.create_token_expiring_in base_path ~agent_name:"visiting-operator" ~role:Masc_domain.Admin ~hours:1
    in
    let _ = Auth.create_token_without_expiry base_path ~agent_name:"operator" ~role:Masc_domain.Admin in
    let now = Unix.gettimeofday () in
    let seats at = Masc.Play_seat.participants ~base_path ~keepers:[ "Alpha"; "operator" ] ~now:at in
    check (list string) "live" [ "Alpha"; "minsu"; "operator"; "visiting-operator" ] (seats now);
    check (list string) "two hours on" [ "Alpha"; "operator" ] (seats (now +. (2. *. 3600.))))

let () =
  run "play-page"
    [ ( "page"
      , [ test_case "the page is public and self-contained" `Quick test_the_page_is_public_and_self_contained
        ; test_case "the guide names this server's doors" `Quick test_the_guide_names_this_servers_doors
        ; test_case "the guide over HTTP/2" `Quick test_the_guide_over_h2
        ; test_case "the seat names the bearer, the holder and the seats" `Quick test_the_seat
        ; test_case "expired invites and operators are not seats" `Quick test_expired_credentials_are_not_seats
        ] )
    ]
