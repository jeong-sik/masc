(* RFC play-link-for-the-shared-machine §2.6 through the real router: the
   play page is public and self-contained, and the seat names the bearer, the
   controller and whom it can be handed to. *)

open Alcotest
module Page = Server_routes_http_routes_play_page
module Guide = Server_routes_http_routes_play_guide
module Events = Server_routes_http_routes_play_events
module Machine_lane = Masc.Machine_lane

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

let dispatch ~body ~state ~target ~token =
  Server_request_authority.with_current (loopback_request_authority ()) (fun () ->
    let router = Guide.add_routes (Page.add_routes (Masc.Http_server_eio.Router.create ())) in
    Server_auth.publish_server_state state;
    let response_buf = Buffer.create 4096 in
    let conn =
      Httpun.Server_connection.create (fun reqd ->
        Masc.Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) (Masc.Http_reqd.of_httpun reqd))
    in
    let method_, content_headers, payload = match body with
      | None -> "GET", "", ""
      | Some body -> "POST", Printf.sprintf "Content-Type: application/json\r\nContent-Length: %d\r\n" (String.length body), body in
    let request_str =
      Printf.sprintf "%s %s HTTP/1.1\r\nHost: 127.0.0.1:8935\r\nOrigin: http://127.0.0.1:8935\r\n%s%s\r\n%s"
        method_ target content_headers
        (match token with
         | Some token -> Printf.sprintf "Authorization: Bearer %s\r\n" token
         | None -> "") payload
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

let dispatch_get ~state ~target ~token = dispatch ~body:None ~state ~target ~token

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
      Masc_test_deps.with_process_env "MASC_HTTP_BASE_URL" (Some "masc.example.com") (fun () ->
        let response = get () in
        check int "schemeless public base URL is not ready" 409 (status_of response);
        let json = Yojson.Safe.from_string (snd (split_response response)) in
        check bool "named as not ready" true (member "code" json = Some (`String "not_ready"));
        check bool "the refusal explains that an http(s) base URL is needed" true
          (member "error" json
           = Some (`String "MASC_HTTP_BASE_URL is not an http(s) base URL, so there is no address to join at")));
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
          ; public_base ^ Page.participants_path
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
                    ~bind_host:"127.0.0.1" ~bind_port:8935 ~https_port:None ~explicit_base_url:None with
            | Ok policy -> policy
            | Error error -> fail (Server_request_authority.trust_policy_error_to_string error)
          in
          let gateway =
            Server_h2_gateway.make_request_handler ~routes:(Server_routes_http.make_routes ~port:0 ~host:"127.0.0.1" ~sw ~clock:(Eio.Stdenv.clock env)) ~trust_policy
          in
          (* Every answer comes at once, far inside the 90 s flush bound. *)
          let handler h2_reqd =
            gateway
              ~stream_end:
                (Masc.Http_h2_stream.Stream_end.create ~stream_sw:sw ~clock:(Eio.Stdenv.clock env)
                   ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s
                   ~request:(H2.Reqd.request h2_reqd) h2_reqd)
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321)) h2_reqd
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
              (match Guide.guide ~base:public_base ~skills:(Guide.current_skills ()) with
               | Ok expected -> check string "same rendered guide" expected reply.h2_body
               | Error reason -> fail reason);
              check int "guide suffix is not another public guide" 404
                (get (Masc.Play_invite.agent_guide_path ^ "/x")).h2_status))))))

let with_dos_worker ~env ~sw ~base_path f =
  let config = Masc.Workspace.default_config base_path in
  Machine_worker_fixture.with_dos ~clock:(Eio.Stdenv.clock env) ~sw ~base_path
    (fun ~invoke:_ ~detach ->
      (* The seat trails the worker by one observation: a call that may change
         the controller is followed by a new observation, and scheduling that
         follow-up is the host call path's job. Handing the test the worker RPC
         directly bypassed it, so the seat kept reading the pre-load
         observation and machine stayed false. Drive the exported tools through
         the host boundary, controller included, like every production caller. *)
      let export name =
        let reading = Masc.Lane_addon_runtime.tool_export_snapshot ~config
          ~access:Masc.Lane_addon_sources.Unauthenticated ~reserved:[] in
        match List.find_opt (fun (candidate : Masc.Lane_addon_runtime.tool_export) ->
          candidate.tool.name = name) reading.exports with
        | Some export -> export
        | None -> fail (name ^ " is not an exported tool") in
      let invoke ~holder name arguments =
        let controller = Some {Machine_controller_contract.observed_holder=holder;
          release=None;handoff_target=(if name="masc_dos_pass" then Some "minsu" else None)} in
        let authority : Lane_addon_call_context.mediation =
          fun ~release_controller:_ ~snapshot:_ ~invoke -> invoke controller in
        match Masc.Lane_addon_runtime.call_exported_tool_with_authority
          ~on_complete:(fun () -> ()) ~on_result:(fun _ -> ()) ~authorize:(Some authority)
          ~principal:(Some (Lane_addon_call_context.Host_actor "operator"))
          ~config ~access:Masc.Lane_addon_sources.Unauthenticated ~reserved:[]
          ~export:(export name) ~arguments with
        | Error (Host_refusal (Rejected detail)) -> fail (name ^ ": " ^ detail)
        | Error (Host_refusal (Unavailable detail)) -> fail (name ^ ": " ^ detail)
        | Error (Host_refusal (Activity_disabled detail)) -> fail (name ^ ": " ^ detail)
        | Error (Host_refusal (Activity_unobserved detail)) -> fail (name ^ ": " ^ detail)
        | Error (Unavailable detail | Outcome_unknown detail) -> fail (name ^ ": " ^ detail)
        | Ok result -> check bool (name ^ " accepted by worker") false (result.is_error = Some true) in
      f ~invoke ~detach)

let test_the_seat () =
  with_dir "play-seat-" (fun base_path ->
    Auth.save_auth_config base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let _operator = token_for base_path ~agent_name:"operator" ~role:Masc_domain.Admin in
    let _worker = token_for base_path ~agent_name:"codex" ~role:Masc_domain.Worker in
    let player = token_for base_path ~agent_name:"minsu" ~role:Masc_domain.Player in
    let state = Masc.Mcp_server.For_testing.create_state ~base_path in
    let programs = Filename.concat (Common.masc_dir_from_base_path ~base_path) "dos/programs" in
    Fs_compat.mkdir_p programs;
    Out_channel.with_open_bin (Filename.concat programs "game.com") (fun channel -> output_string channel hello_com);
    Dos_lane.install_activity_observer (Some (fun () -> Machine_configuration.Enabled));
    Fun.protect ~finally:(fun () ->
      ignore (Dos_lane.eject ~who:"minsu" ~announce:ignore ());
      ignore (Dos_lane.eject ~who:"operator" ~announce:ignore ());
      Dos_lane.install_activity_observer None) (fun () ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 30. (fun () ->
      Eio.Switch.run (fun sw ->
      Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env)
        ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
      Masc.Lane_addon_runtime.For_testing.reset ();
      let seat token = dispatch_get ~state ~target:Page.seat_path ~token in
      let participants token = dispatch_get ~state ~target:Page.participants_path ~token in
      check int "the seat needs a bearer" 401 (status_of (seat None));
      check int "the roster needs a bearer" 401 (status_of (participants None));
      (* The roster is read from credentials, not from the worker. *)
      let roster = participants (Some player) in
      check int "the roster answers without a worker" 200 (status_of roster);
      check bool "operators and invites, not agents' clients" true
        (member "participants" (Yojson.Safe.from_string (snd (split_response roster)))
         = Some (`List [`String "minsu"; `String "operator"]));
      check int "no attached worker is unavailable" 503 (status_of (seat (Some player)));
      with_dos_worker ~env ~sw ~base_path (fun ~invoke ~detach ->
        let read () =
          let response = seat (Some player) in
          check int "a player reads its seat" 200 (status_of response);
          Yojson.Safe.from_string (snd (split_response response)) in
        let answer = read () in
        check bool "the bearer's name" true (member "name" answer = Some (`String "minsu"));
        check bool "unloaded worker has no machine" true (member "machine" answer = Some (`Bool false));
        check bool "nobody holds it" true (member "controller" answer = Some `Null);
        check bool "no saves name without a machine" true (member "saves_name" answer = Some `Null);
        check bool "the seat poll does not carry the roster" true (member "participants" answer = None);
        invoke ~holder:None "masc_dos_load" (`Assoc ["program",`String "game.com"]);
        invoke ~holder:(Some "operator") "masc_dos_pass" (`Assoc ["to",`String "minsu"]);
        (* Each May_change call schedules a fresh observation and the seat
           trails the worker by that one observation, so poll until the
           refreshed row lands instead of asserting on the stale one; the
           outer 30 s timeout bounds a stalled worker. *)
        let rec settled () =
          let response = seat (Some player) in
          match status_of response with
          | 200 ->
            let answer = Yojson.Safe.from_string (snd (split_response response)) in
            (* Both May_change wakes must land before the seat settles: the load
               refresh names the machine, the pass refresh names the holder.
               Waiting only for the machine read the handoff's previous row. *)
            if member "machine" answer = Some (`Bool true)
               && member "controller" answer = Some (`String "minsu") then answer
            else (Eio.Time.sleep (Eio.Stdenv.clock env) 0.01; settled ())
          | _ -> Eio.Time.sleep (Eio.Stdenv.clock env) 0.01; settled () in
        let answer = settled () in
        check bool "a machine" true (member "machine" answer = Some (`Bool true));
        check bool "the invite holds the controller" true
          (member "controller" answer = Some (`String "minsu"));
        check bool "worker inventory name identifies the pad" true
          (member "saves_name" answer = Some (`String "game.com"));
        detach ();
        check int "detached worker cannot publish a seat" 503 (status_of (seat (Some player))))))))))

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
    let seats at = match Masc.Play_seat.participants ~base_path ~keepers:[ "Alpha"; "operator" ] ~now:at with
      | Ok names -> names
      | Error error -> fail (Masc_domain.masc_error_to_string error) in
    check (list string) "live" [ "Alpha"; "minsu"; "operator"; "visiting-operator" ] (seats now);
    check (list string) "two hours on" [ "Alpha"; "operator" ] (seats (now +. (2. *. 3600.))))

let test_explicit_departure_and_same_link_reconnect () =
  with_dir "play-participation-http-" (fun base_path ->
    Auth.save_auth_config base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let token = token_for base_path ~agent_name:"minsu" ~role:Masc_domain.Player in
    let state = Masc.Mcp_server.For_testing.create_state ~base_path in
    Eio_main.run (fun env ->
      Masc_test_deps.init_eio_clock env;
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 30. (fun () ->
      Eio.Switch.run (fun sw ->
      Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env)
        ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
      Masc.Lane_addon_runtime.For_testing.reset ();
      (* The seat read comes from the attached DOS worker and is 503 without
         one (test_the_seat); attendance itself needs no worker. *)
      with_dos_worker ~env ~sw ~base_path (fun ~invoke:_ ~detach ->
      let change token body = dispatch ~body:(Some body) ~state ~target:Page.session_path ~token in
      check int "anonymous departure is forbidden" 401 (status_of (change None {|{"connected":false}|}));
      check int "unknown session fields are refused" 400
        (status_of (change (Some token) {|{"connected":false,"who":"operator"}|}));
      let read () = dispatch_get ~state ~target:Page.seat_path ~token:(Some token)
        |> split_response |> snd |> Yojson.Safe.from_string in
      let roster () = dispatch_get ~state ~target:Page.participants_path ~token:(Some token)
        |> split_response |> snd |> Yojson.Safe.from_string in
      check bool "a fresh invited agent remains connected" true (member "connected" (read ()) = Some (`Bool true));
      check int "atomic departure" 200 (status_of (change (Some token) {|{"connected":false}|}));
      let departed = read () in
      check bool "the reusable bearer can read its departed seat" true (member "connected" departed = Some (`Bool false));
      check bool "departed identities are not handoff targets" true (member "participants" (roster ()) = Some (`List []));
      check int "the same invitation explicitly reconnects" 200 (status_of (change (Some token) {|{"connected":true}|}));
      let connected = read () in
      check bool "reconnect restores eligibility" true (member "participants" (roster ()) = Some (`List [`String "minsu"]));
      check bool "reconnect does not take a controller" true (member "controller" connected = Some `Null);
      detach ()))))))

let test_ineligible_participation_does_not_hide_active_seats () =
  with_dir "play-ineligible-participation-" (fun base_path ->
    Eio_main.run (fun env ->
      Masc_test_deps.init_eio_clock env;
      let auth_ok = function
        | Ok value -> value
        | Error error -> fail (Masc_domain.masc_error_to_string error) in
      let _, expired = auth_ok (Auth.create_token_expiring_in base_path
          ~agent_name:"expired" ~role:Masc_domain.Player ~hours:1) in
      let expired = { expired with expires_at = Some "2000-01-01T00:00:00Z" } in
      Auth.save_credential base_path expired;
      let _, worker = auth_ok (Auth.create_token_without_expiry base_path
          ~agent_name:"worker" ~role:Masc_domain.Worker) in
      ignore (auth_ok (Auth.create_token_without_expiry base_path
          ~agent_name:"active" ~role:Masc_domain.Player));
      auth_ok (Auth.with_credential_transaction base_path (fun transaction ->
        List.iter (fun credential ->
          match Masc.Play_participation.write ~transaction ~base_path credential Connected with
          | Ok () -> ()
          | Error detail -> fail detail) [expired; worker]));
      let directory = Filename.concat (Common.masc_dir_from_base_path ~base_path) "play" in
      Array.iter (fun file -> Out_channel.with_open_bin (Filename.concat directory file)
          (fun channel -> output_string channel "malformed")) (Sys.readdir directory);
      let seats = auth_ok (Masc.Play_seat.participants ~base_path ~keepers:[] ~now:(Unix.gettimeofday ())) in
      check (list string) "irrelevant damaged state does not block eligible seats" ["active"] seats))

let test_observation_requires_a_scoped_bearer () =
  with_dir "play-observation-auth-" (fun base_path ->
    Auth.save_auth_config base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let token = token_for base_path ~agent_name:"minsu" ~role:Masc_domain.Player in
    (* This router fixture has no connection switch or clock. A correctly
       admitted Player reaches readiness, rather than the Admin observer gate. *)
    let state = Masc.Mcp_server.For_testing.create_state ~base_path in
    Eio_main.run (fun env ->
      Masc_test_deps.init_eio_clock env;
      let get suffix bearer = dispatch_get ~state ~target:(Events.path ^ suffix) ~token:bearer |> status_of in
      check int "anonymous observation is refused" 401 (get "?machine=dos" None);
      check int "an invalid bearer is refused" 401 (get "?machine=dos" (Some "invalid"));
      check int "a Player is admitted without generic observer authority" 503 (get "?machine=dos" (Some token));
      List.iter (fun suffix -> check int suffix 400 (get suffix (Some token)))
        [ ""; "?machine=unknown"; "?machine=dos&machine=msx"
        ; "?machine=dos&token=must-not-be-used"; "?machine=dos&scope=admin"
        ; "?machine=dos&client_id=bad%20client" ]))

let test_observation_invalidates_only_its_public_read_models () =
  let changed fields = Events.change_of_payload ~machine:Machine_lane.Dos (`Assoc fields) in
  let dataset name extra = changed
      (["type", `String Masc.Workspace_dataset_event.event_type; "dataset", `String name; "ts_unix", `Float 1.] @ extra) in
  check bool "selected machine changed" true
    (dataset "machine_live" ["machine", `String "dos"] = Some Events.Machine);
  check bool "another machine cannot drive this frame read" true
    (dataset "machine_live" ["machine", `String "msx"] = None);
  check bool "the public transcript is shared across machines" true
    (dataset "play_room" ["machine", `String "msx"] = Some Events.Room);
  check bool "participation commits refresh the seat and roster" true
    (dataset "play_seats" [] = Some Events.Seats);
  let keeper kind extra = changed
      (["type", `String kind; "name", `String "private-holder-name"; "ts_unix", `Float 1.] @ extra) in
  check bool "idle Keeper pause refreshes recoverability" true
    (keeper "keeper_phase_changed" ["prev_phase", `String "running"; "new_phase", `String "paused"] = Some (Events.Keeper "private-holder-name"));
  check bool "composite changes refresh holder identity" true
    (keeper "keeper_composite_changed" [] = Some (Events.Keeper "private-holder-name"));
  check bool "invalid lifecycle state is not a producer" true
    (keeper "keeper_phase_changed" ["prev_phase", `String "running"; "new_phase", `String "invented"] = None);
  check bool "private chat cannot appear on the Play transport" true
    (keeper "keeper_chat_appended" ["text", `String "private"] = None);
  check string "only a public read invalidation leaves the transport"
    "event: play\ndata: {\"change\":\"seats\"}\n\n" (Events.frame Events.Seats)

let test_seat_expiry_uses_bearer_admission_boundary () =
  let credential : Masc_domain.agent_credential =
    { id = None; agent_id = None; agent_name = "holder"; token = "unused-hash"
    ; role = Player; created_at = "2000-01-01T00:00:00Z"
    ; expires_at = Some "2000-01-01T00:00:00Z" } in
  let epoch = 946684800. in
  let next now credentials = Events.For_testing.next_seat_expiry ~now credentials in
  check (option (float 0.)) "a credential remains live throughout its expiry second"
    (Some (epoch +. 1.)) (next (epoch +. 0.75) [credential]);
  check (option (float 0.)) "an already expired credential cannot create a busy deadline loop"
    None (next (epoch +. 1.) [credential]);
  check (option (float 0.)) "workers do not form a seat expiry source"
    None (next (epoch -. 1.) [{ credential with role = Worker }]);
  check (option (float 0.)) "a non-expiring operator has no read timer"
    None (next epoch [{ credential with role = Admin; expires_at = None }]);
  let malformed = { credential with expires_at = Some "malformed" } in
  check (option (float 0.)) "malformed authority supplies no seat deadline"
    None (next epoch [malformed]);
  List.iter (fun credentials ->
    check (option (float 0.)) "one malformed expiry cannot hide a valid seat deadline"
      (Some (epoch +. 1.)) (next epoch credentials))
    [[malformed; credential]; [credential; malformed]]

let test_malformed_credential_does_not_poison_seat_observation () =
  with_dir "play-malformed-seat-expiry-" (fun base_path ->
    Eio_main.run (fun env ->
      Masc_test_deps.init_eio_clock env;
      Auth.save_auth_config base_path
        { Masc_domain.default_auth_config with enabled = true; require_token = true };
      let auth_ok = function
        | Ok value -> value
        | Error error -> fail (Masc_domain.masc_error_to_string error) in
      ignore (auth_ok (Auth.create_token_without_expiry base_path
        ~agent_name:"operator" ~role:Masc_domain.Admin));
      let _, holder = auth_ok (Auth.create_token_without_expiry base_path
        ~agent_name:"holder" ~role:Masc_domain.Player) in
      Auth.save_credential base_path
        { holder with expires_at = Some "2100-01-01T00:00:00Z" };
      List.iter (fun (agent_name, role) ->
        let token, damaged = auth_ok (Auth.create_token_without_expiry base_path
          ~agent_name ~role) in
        Auth.save_credential base_path
          { damaged with expires_at = Some "malformed" };
        check bool "ignoring a damaged deadline cannot admit its bearer" true
          (Result.is_error (Auth.verify_token base_path ~agent_name ~token)))
        ["invalid-admin", Masc_domain.Admin; "invalid-player", Masc_domain.Player];
      (* This is the actual transaction and selector used by the stream's
         deadline worker, including the two readable damaged credentials. *)
      let next = match Events.For_testing.observe_seat_expiry ~base_path with
        | Ok next -> next
        | Error () -> fail "one damaged expiry retired the workspace observation" in
      check (option (float 0.)) "the valid expiry still drives the observer"
        (Some 4102444801.) next;
      let seats = auth_ok (Masc.Play_seat.participants ~base_path ~keepers:[]
        ~now:(Time_compat.now ())) in
      check (list string) "valid seats remain visible and damaged credentials are excluded"
        ["holder"; "operator"] seats))

let () =
  run "play-page"
    [ ( "page"
      , [ test_case "the page is public and self-contained" `Quick test_the_page_is_public_and_self_contained
        ; test_case "the guide names this server's doors" `Quick test_the_guide_names_this_servers_doors
        ; test_case "the guide over HTTP/2" `Quick test_the_guide_over_h2
        ; test_case "the seat names the bearer, the holder and the seats" `Quick test_the_seat
        ; test_case "expired invites and operators are not seats" `Quick test_expired_credentials_are_not_seats
        ; test_case "explicit departure and same-link reconnect over HTTP" `Quick test_explicit_departure_and_same_link_reconnect
        ; test_case "ineligible damaged participation cannot hide active seats" `Quick test_ineligible_participation_does_not_hide_active_seats
        ; test_case "Play observation requires an exact scoped bearer" `Quick test_observation_requires_a_scoped_bearer
        ; test_case "Play observation emits only relevant public invalidations" `Quick test_observation_invalidates_only_its_public_read_models
        ; test_case "seat expiry uses the bearer admission boundary" `Quick test_seat_expiry_uses_bearer_admission_boundary
        ; test_case "one malformed credential cannot retire seat observation" `Quick test_malformed_credential_does_not_poison_seat_observation
        ] )
    ]
