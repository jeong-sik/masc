(** Typed route registration: what each auth kind records on the route, and what
    it does to the handler.

    The first group reads the route table. The second dispatches requests
    through the router. While the server has no state a wrapper of [Server_auth]
    answers 503 and never calls the handler, so the kinds that wrap must not run
    their handler and the two that wrap nothing must. With authentication on, each
    kind is dispatched with no credential, a Worker token and an Admin token and
    its whole response is compared with the same wrapper applied by hand. This runs
    twice, with strict HTTP auth on and off, because [with_public_read] is the one
    wrapper whose answer depends on it. *)

open Alcotest
open Masc
module Router = Http_server_eio.Router

let access_json access = Yojson.Safe.to_string (Route_access.to_json access)

let plain_handler : Http_server_eio.request_handler = fun _request _reqd -> ()
let state_handler : Server_route.state_handler = fun _state _request _reqd -> ()
let token_handler : Server_route.token_handler = fun _state _token _request _reqd -> ()
let actor_handler : Server_route.actor_handler = fun _state _actor _request _reqd -> ()

let single_route routes =
  match Router.routes routes with
  | [ route ] -> route
  | other -> failf "expected one route, got %d" (List.length other)
;;

(* Every kind, the registration that uses it, and what the route must record. *)
let kinds : (string * (Router.t -> Router.t) * Route_access.t) list =
  [ ( "always_public"
    , Server_route.get Server_route.Always_public "/x" plain_handler
    , Route_access.Always_public )
  ; ( "public_read"
    , Server_route.get Server_route.Public_read "/x" state_handler
    , Route_access.Public_read )
  ; ( "public_read_on_canonical_host"
    , Server_route.get
        (Server_route.Public_read_on_canonical_host { port = 8935 })
        "/x"
        state_handler
    , Route_access.Public_read )
  ; ( "read_auth"
    , Server_route.get Server_route.Read_auth "/x" state_handler
    , Route_access.Read_auth )
  ; ( "permission"
    , Server_route.get (Server_route.Permission Masc_domain.CanAdmin) "/x" state_handler
    , Route_access.Permission Masc_domain.CanAdmin )
  ; ( "token_permission"
    , Server_route.get
        (Server_route.Token_permission Masc_domain.CanReadState)
        "/x"
        token_handler
    , Route_access.Token_permission Masc_domain.CanReadState )
  ; ( "private_token_permission"
    , Server_route.get
        (Server_route.Private_token_permission Masc_domain.CanBroadcast)
        "/x"
        token_handler
    , Route_access.Private_token_permission Masc_domain.CanBroadcast )
  ; ( "tool"
    , Server_route.get (Server_route.Tool { tool_name = "masc_status" }) "/x" state_handler
    , Route_access.Tool { tool_name = "masc_status" } )
  ; ( "tool_observation"
    , Server_route.get (Server_route.Tool_observation { tool_name = "masc_status" }) "/x" state_handler
    , Route_access.Tool_observation { tool_name = "masc_status" } )
  ; ( "tool_actor"
    , Server_route.get
        (Server_route.Tool_actor { tool_name = "masc_lane_evidence" })
        "/x"
        actor_handler
    , Route_access.Tool_actor { tool_name = "masc_lane_evidence" } )
  ; ( "self_authenticated"
    , Server_route.get
        (Server_route.Self_authenticated Route_access.Mcp_transport)
        "/x"
        plain_handler
    , Route_access.Self_authenticated Route_access.Mcp_transport )
  ]
;;

let test_records_the_kind () =
  List.iter
    (fun (name, register, expected) ->
       let route = single_route (register (Router.create ())) in
       check string name (access_json expected) (access_json route.Router.access))
    kinds
;;

let test_access_matches_the_registered_kind () =
  (* [Server_route.access] is what the registration functions record. *)
  check
    string
    "permission"
    (access_json (Route_access.Permission Masc_domain.CanAdmin))
    (access_json (Server_route.access (Server_route.Permission Masc_domain.CanAdmin)))
;;

let test_method_and_kind () =
  let route =
    single_route (Server_route.post Server_route.Always_public "/x" plain_handler (Router.create ()))
  in
  check bool "post is exact" true (route.Router.kind = Router.Exact);
  check bool "post method" true (route.Router.methods = [ `POST ]);
  let route =
    single_route
      (Server_route.prefix_put Server_route.Always_public "/x/" plain_handler (Router.create ()))
  in
  check bool "prefix_put is a prefix" true (route.Router.kind = Router.Prefix);
  check bool "prefix_put method" true (route.Router.methods = [ `PUT ]);
  let route =
    single_route
      (Server_route.add
         Server_route.Always_public
         ~path:"/x"
         ~methods:[ `GET; `POST ]
         plain_handler
         (Router.create ()))
  in
  check bool "add keeps its methods" true (route.Router.methods = [ `GET; `POST ])
;;

let test_ws_get_records_the_upgrade_reason () =
  let route =
    single_route
      (Server_route.ws_get "/ws" (fun ~upgrade:_ _request _reqd -> ()) (Router.create ()))
  in
  check
    string
    "access"
    (access_json (Route_access.Self_authenticated Route_access.Websocket_upgrade))
    (access_json route.Router.access);
  match route.Router.handler with
  | Router.Ws _ -> ()
  | Router.Plain _ -> fail "ws_get registered a plain handler"
;;

let test_json_shape () =
  let expect name access json =
    check string name json (access_json access)
  in
  expect
    "permission"
    (Route_access.Permission Masc_domain.CanAdmin)
    {|{"kind":"permission","permission":"CanAdmin"}|};
  expect
    "tool_actor"
    (Route_access.Tool_actor { tool_name = "masc_lane_evidence" })
    {|{"kind":"tool_actor","tool_name":"masc_lane_evidence"}|};
  expect
    "tool_observation"
    (Route_access.Tool_observation { tool_name = "masc_status" })
    {|{"kind":"tool_observation","tool_name":"masc_status"}|};
  expect
    "self_authenticated"
    (Route_access.Self_authenticated Route_access.Oauth_protocol)
    {|{"kind":"self_authenticated","reason":"oauth_protocol"}|}
;;

(* ---- dispatch ---- *)

let authority_of host =
  match Server_request_authority.of_host_port ~host ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> failf "failed to construct the request authority of %s" host
;;

type response =
  { status : int
  ; headers : (string * string) list
  ; body : string
  }

let show_response response =
  Printf.sprintf
    "%d %s %S"
    response.status
    (String.concat "; " (List.map (fun (k, v) -> k ^ "=" ^ v) response.headers))
    response.body
;;

(* [date] differs between two answers given a second apart; nothing else does. *)
let parse_response raw =
  let separator = "\r\n\r\n" in
  let rec find index =
    if index + String.length separator > String.length raw
    then failf "no end of headers in %S" raw
    else if String.sub raw index (String.length separator) = separator
    then index
    else find (index + 1)
  in
  let split = find 0 in
  let head = String.sub raw 0 split in
  let body =
    String.sub
      raw
      (split + String.length separator)
      (String.length raw - split - String.length separator)
  in
  match List.map String.trim (String.split_on_char '\n' head) with
  | status_line :: header_lines ->
    let status =
      match String.split_on_char ' ' status_line with
      | _ :: code :: _ -> int_of_string code
      | _ -> failf "no status in %S" status_line
    in
    let headers =
      List.filter_map
        (fun line ->
           match String.index_opt line ':' with
           | None -> None
           | Some i ->
             let name = String.lowercase_ascii (String.sub line 0 i) in
             let value =
               String.trim (String.sub line (i + 1) (String.length line - i - 1))
             in
             if String.equal name "date" then None else Some (name, value))
        header_lines
    in
    { status; headers = List.sort compare headers; body }
  | [] -> failf "empty response %S" raw
;;

type origin = Same_origin | No_origin | Origin of string

let dispatch ?(host = "127.0.0.1") ?(method_ = "GET") ?(origin = Same_origin)
    ?token router path =
  Server_request_authority.with_current (authority_of host) (fun () ->
    let output = Buffer.create 256 in
    let connection =
      Httpun.Server_connection.create (fun reqd ->
        Router.dispatch router (Httpun.Reqd.request reqd) reqd)
    in
    let authorization =
      Option.fold ~none:"" ~some:(fun token -> "Authorization: Bearer " ^ token ^ "\r\n") token
    in
    let origin = match origin with
      | Same_origin -> "Origin: http://" ^ host ^ ":8935\r\n"
      | No_origin -> ""
      | Origin value -> "Origin: " ^ value ^ "\r\n" in
    let raw_request =
      Printf.sprintf
        "%s %s HTTP/1.1\r\nHost: %s:8935\r\n%s%s\r\n"
        method_
        path
        host
        origin
        authorization
    in
    let input =
      Bigstringaf.of_string ~off:0 ~len:(String.length raw_request) raw_request
    in
    ignore
      (Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input));
    let rec drain () =
      match Httpun.Server_connection.next_write_operation connection with
      | `Write iovecs ->
        let bytes =
          List.fold_left
            (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
               Buffer.add_string
                 output
                 (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
               total + iov.len)
            0
            iovecs
        in
        Httpun.Server_connection.report_write_result connection (`Ok bytes);
        drain ()
      | `Yield | `Close _ -> ()
    in
    drain ();
    parse_response (Buffer.contents output))
;;

(* One handler per shape. Each answers with its own name, and the handlers that
   are given a string answer with it too, so the typed route and the one built by
   hand are compared on what the handler was given as well. *)
let answer text reqd = Http_server_eio.Response.text text reqd

let plain name : Http_server_eio.request_handler =
  fun _request reqd -> answer ("ran " ^ name) reqd
;;

let on_state name : Server_route.state_handler =
  fun _state _request reqd -> answer ("ran " ^ name) reqd
;;

let on_string name : Server_route.token_handler =
  fun _state given _request reqd -> answer ("ran " ^ name ^ " given " ^ given) reqd
;;

(* Where a kind is registered. [Public_read] is also registered on a path of
   [Server_auth.is_public_read_path], because under strict HTTP auth it only stays
   open there, and that is what tells it from [Read_auth]. *)
let public_path = "/api/v1/gate/status"

let path_of = function
  | "public_read_on_public_path" -> public_path
  | name -> "/" ^ name
;;

(* Every kind with its path, the registration under test, and the same wrapper
   applied by hand. The by-hand side registers through [Always_public], which
   wraps nothing, so its handler runs as written. *)
let dispatch_kinds =
  let admin = Masc_domain.CanAdmin in
  [ ( "always_public"
    , (fun r -> Server_route.get Server_route.Always_public "/always_public" (plain "always_public") r)
    , fun r -> Server_route.get Server_route.Always_public "/always_public" (plain "always_public") r )
  ; ( "self_authenticated"
    , (fun r ->
        Server_route.get
          (Server_route.Self_authenticated Route_access.Oauth_protocol)
          "/self_authenticated"
          (plain "self_authenticated")
          r)
    , fun r ->
        Server_route.get
          Server_route.Always_public
          "/self_authenticated"
          (plain "self_authenticated")
          r )
  ; ( "public_read"
    , (fun r -> Server_route.get Server_route.Public_read "/public_read" (on_state "public_read") r)
    , fun r ->
        Server_route.get
          Server_route.Always_public
          "/public_read"
          (Server_auth.with_public_read (on_state "public_read"))
          r )
  ; ( "public_read_on_public_path"
    , (fun r ->
        Server_route.get Server_route.Public_read public_path (on_state "public_read_on_public_path") r)
    , fun r ->
        Server_route.get
          Server_route.Always_public
          public_path
          (Server_auth.with_public_read (on_state "public_read_on_public_path"))
          r )
  ; ( "public_read_on_canonical_host"
    , (fun r ->
        Server_route.get
          (Server_route.Public_read_on_canonical_host { port = 8935 })
          "/public_read_on_canonical_host"
          (on_state "public_read_on_canonical_host")
          r)
    , fun r ->
        (* The shape the dashboard pages had before they carried a kind. *)
        Server_route.get
          Server_route.Always_public
          "/public_read_on_canonical_host"
          (fun request reqd ->
             Server_canonical_host.with_canonical_loopback_host
               ~port:8935
               (fun req reqd ->
                  Server_auth.with_public_read
                    (on_state "public_read_on_canonical_host")
                    req
                    reqd)
               request
               reqd)
          r )
  ; ( "read_auth"
    , (fun r -> Server_route.get Server_route.Read_auth "/read_auth" (on_state "read_auth") r)
    , fun r ->
        Server_route.get
          Server_route.Always_public
          "/read_auth"
          (Server_auth.with_read_auth (on_state "read_auth"))
          r )
  ; ( "permission"
    , (fun r ->
        Server_route.get (Server_route.Permission admin) "/permission" (on_state "permission") r)
    , fun r ->
        Server_route.get
          Server_route.Always_public
          "/permission"
          (Server_auth.with_permission_auth ~permission:admin (on_state "permission"))
          r )
  ; ( "token_permission"
    , (fun r ->
        Server_route.get
          (Server_route.Token_permission admin)
          "/token_permission"
          (on_string "token_permission")
          r)
    , fun r ->
        Server_route.get
          Server_route.Always_public
          "/token_permission"
          (Server_auth.with_token_permission_auth ~permission:admin (on_string "token_permission"))
          r )
  ; ( "private_token_permission"
    , (fun r ->
        Server_route.get
          (Server_route.Private_token_permission admin)
          "/private_token_permission"
          (on_string "private_token_permission")
          r)
    , fun r ->
        Server_route.get
          Server_route.Always_public
          "/private_token_permission"
          (Server_auth.with_private_token_permission_auth
             ~permission:admin
             (on_string "private_token_permission"))
          r )
  ; ( "tool"
    , (fun r ->
        Server_route.get
          (Server_route.Tool { tool_name = "masc_status" })
          "/tool"
          (on_state "tool")
          r)
    , fun r ->
        Server_route.get
          Server_route.Always_public
          "/tool"
          (Server_auth.with_tool_auth ~tool_name:"masc_status" (on_state "tool"))
          r )
  ; ( "tool_observation"
    , (fun r ->
        Server_route.get
          (Server_route.Tool_observation { tool_name = "masc_status" })
          "/tool_observation" (on_state "tool_observation") r)
    , fun r ->
        Server_route.get Server_route.Always_public "/tool_observation"
          (Server_auth.with_tool_observation_auth ~tool_name:"masc_status"
             (on_state "tool_observation")) r )
  ; ( "tool_actor"
    , (fun r ->
        Server_route.get
          (Server_route.Tool_actor { tool_name = "masc_status" })
          "/tool_actor"
          (on_string "tool_actor")
          r)
    , fun r ->
        Server_route.get
          Server_route.Always_public
          "/tool_actor"
          (Server_auth.with_tool_actor_auth ~tool_name:"masc_status" (on_string "tool_actor"))
          r )
  ]
;;

let test_wrappers_gate_the_handler () =
  (* [Server_request_authority.with_current] binds a fiber-local value. *)
  Eio_main.run @@ fun _env ->
  Server_auth.clear_server_state ();
  let router =
    List.fold_left (fun r (_, typed, _) -> typed r) (Router.create ()) dispatch_kinds
  in
  let unavailable =
    Httpun.Status.to_code (Server_auth.not_initialized_status :> Httpun.Status.t)
  in
  List.iter
    (fun (name, _, _) ->
       let response = dispatch router (path_of name) in
       let runs_handler = List.mem name [ "always_public"; "self_authenticated" ] in
       check int (name ^ " status") (if runs_handler then 200 else unavailable) response.status;
       check
         bool
         (name ^ " ran its handler")
         runs_handler
         (String.starts_with ~prefix:"ran " response.body))
    dispatch_kinds
;;

let remove_tree path =
  let rec go path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> go (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  in
  go path
;;

(* [Server_auth.http_auth_strict_enabled] reads these variables, and a shell that
   exports a public [MASC_HTTP_BASE_URL] turns strict auth on by itself. The test
   pins all three. A variable that was unset cannot be unset again, so it is left
   empty, which every reader treats as unset. *)
let with_http_environment ~strict f =
  let bindings =
    [ "MASC_HTTP_AUTH_STRICT", string_of_bool strict
    ; "MASC_HOST", "127.0.0.1"
    ; "MASC_HTTP_BASE_URL", "http://127.0.0.1:8935"
    ]
  in
  let previous = List.map (fun (name, _) -> name, Sys.getenv_opt name) bindings in
  List.iter (fun (name, value) -> Unix.putenv name value) bindings;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (name, old) -> Unix.putenv name (Option.value old ~default:""))
        previous)
    f
;;

(* A server state with authentication on, and one token per role. *)
let with_authentication ~strict f =
  with_http_environment ~strict @@ fun () ->
  let base_path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-server-route-%d-%d" (Unix.getpid ()) (Random.int 1_000_000))
  in
  Unix.mkdir base_path 0o700;
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  let previous_startup = Server_startup_state.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Server_startup_state.For_testing.restore previous_startup;
      Server_auth.For_testing.restore_server_state previous_state;
      remove_tree base_path)
    (fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       Fun.protect ~finally:Fs_compat.clear_fs
       @@ fun () ->
       let state = Mcp_server.For_testing.create_state ~base_path in
       ignore (Workspace.init (Mcp_server.workspace_config state) ~agent_name:(Some "test"));
       Server_auth.For_testing.restore_server_state (Some state);
       (* [with_public_read] answers 503 until the server says it is ready. *)
       (match Server_startup_state.mark_state_ready () with
        | Ok () -> ()
        | Error error -> fail (Server_startup_state.state_ready_error_to_string error));
       Auth.save_auth_config
         base_path
         { Masc_domain.default_auth_config with enabled = true; require_token = true };
       let token role =
         match Auth.create_token base_path ~agent_name:("route-" ^ role) ~role:(
             if String.equal role "worker" then Masc_domain.Worker else Masc_domain.Admin)
         with
         | Ok (token, _) -> token
         | Error error -> fail (Masc_domain.masc_error_to_string error)
       in
       f ~base_path ~worker:(token "worker") ~admin:(token "admin"))
;;

(* The status each kind answers with no credential, with a Worker token and with
   an Admin token. Both routers must agree, and these are what they agree on.
   Only [Public_read] off the public list changes with strict auth: strict
   makes it ask for a read credential, as [Read_auth] does. *)
let expected_status ~strict =
  [ "always_public", (200, 200, 200)
  ; "self_authenticated", (200, 200, 200)
  ; "public_read_on_public_path", (200, 200, 200)
  ; "public_read", if strict then 401, 200, 200 else 200, 200, 200
  ; "public_read_on_canonical_host", if strict then 401, 200, 200 else 200, 200, 200
  ; "read_auth", (401, 200, 200)
  ; "permission", (401, 403, 200)
  ; "token_permission", (401, 403, 200)
  ; "private_token_permission", (401, 403, 200)
  ; "tool", (401, 200, 200)
  ; "tool_observation", (401, 200, 200)
  ; "tool_actor", (401, 200, 200)
  ]
;;

let test_typed_routes_answer_like_the_wrapper_by_hand ~strict () =
  with_authentication ~strict
  @@ fun ~base_path:_ ~worker ~admin ->
  let typed =
    List.fold_left (fun r (_, typed, _) -> typed r) (Router.create ()) dispatch_kinds
  in
  let by_hand =
    List.fold_left (fun r (_, _, by_hand) -> by_hand r) (Router.create ()) dispatch_kinds
  in
  List.iter
    (fun (name, _, _) ->
       let none_status, worker_status, admin_status =
         List.assoc name (expected_status ~strict)
       in
       List.iter
         (fun (who, token, status) ->
            let label = name ^ " with " ^ who in
            let answered = dispatch ?token typed (path_of name) in
            let expected = dispatch ?token by_hand (path_of name) in
            check string label (show_response expected) (show_response answered);
            check int (label ^ " status") status answered.status)
         [ "no credential", None, none_status
         ; "a worker token", Some worker, worker_status
         ; "an admin token", Some admin, admin_status
         ])
    dispatch_kinds
;;

let test_tool_observation_does_not_consume_operation_quota () =
  with_authentication ~strict:false @@ fun ~base_path:_ ~worker ~admin ->
  let routes = Router.create ()
    |> Server_route.get (Server_route.Tool_observation {tool_name = "masc_status"})
         "/observation" (on_state "observation")
    |> Server_route.post (Server_route.Tool_observation {tool_name = "masc_status"})
         "/observation" (on_state "observation")
    |> Server_route.get (Server_route.Tool {tool_name = "masc_status"})
         "/operation" (on_state "operation") in
  let key = match Rate_limit.agent_key_of_token_or_name ~token:worker () with
    | Some key -> key | None -> fail "worker has no quota key" in
  let before = Rate_limit.remaining_agent_global ~key in
  check int "first observation authorized" 200 (dispatch ~token:worker routes "/observation").status;
  check int "second observation authorized" 200 (dispatch ~token:worker routes "/observation").status;
  check int "observations leave the operation bucket alone" before (Rate_limit.remaining_agent_global ~key);
  check int "operation authorized" 200 (dispatch ~token:worker routes "/operation").status;
  check int "ordinary tool still consumes an operation" (before - 1) (Rate_limit.remaining_agent_global ~key);
  let admin_key = match Rate_limit.agent_key_of_token_or_name ~token:admin () with
    | Some key -> key | None -> fail "admin has no quota key" in
  let admin_before = Rate_limit.remaining_agent_global ~key:admin_key in
  check int "non-read method authorized" 200
    (dispatch ~method_:"POST" ~token:admin routes "/observation").status;
  check int "non-read method remains metered" (admin_before - 1)
    (Rate_limit.remaining_agent_global ~key:admin_key)
;;

let test_tool_observation_preserves_anonymous_tool_authorization () =
  with_authentication ~strict:false @@ fun ~base_path ~worker:_ ~admin:_ ->
  Auth.save_auth_config base_path
    { Masc_domain.default_auth_config with enabled = false; require_token = false };
  Server_auth.For_testing.restore_auth_config (Some Server_auth_config.fail_closed);
  Fun.protect ~finally:(fun () -> Server_auth.For_testing.restore_auth_config None) (fun () ->
    let routes = Router.create ()
      |> Server_route.get (Server_route.Tool {tool_name = "masc_status"})
           "/operation" (on_state "operation")
      |> Server_route.get (Server_route.Tool_observation {tool_name = "masc_status"})
           "/observation" (on_state "observation") in
    List.iter (fun (origin, expected) ->
      let operation = dispatch ~origin routes "/operation" in
      let observation = dispatch ~origin routes "/observation" in
      check int "observation and ordinary tool enforce the same origin policy"
        operation.status observation.status;
      check bool "same-origin admits; missing or foreign origin refuses"
        expected (observation.status = 200))
      [Same_origin, true; No_origin, false; Origin "http://elsewhere.invalid:8935", false])
;;

(* ---- the canonical-host redirect runs before the public read ---- *)

let location_of response = List.assoc_opt "location" response.headers

let page_routes () =
  Router.create ()
  |> Server_route.get
       (Server_route.Public_read_on_canonical_host { port = 8935 })
       "/page"
       (on_state "page")
  |> Server_route.get Server_route.Public_read "/plain" (on_state "plain")
;;

let check_redirected label response ~target =
  check int (label ^ ": status") 302 response.status;
  check (option string) (label ^ ": location") (Some ("http://127.0.0.1:8935" ^ target)) (location_of response)
;;

(* A request that names [localhost] is redirected whatever state the server is in.
   [Public_read] alone is not that: it answers 503 until the server is ready. *)
let test_alias_host_is_redirected_while_the_server_is_not_ready () =
  Eio_main.run @@ fun _env ->
  Server_auth.clear_server_state ();
  let routes = page_routes () in
  check_redirected "alias host" (dispatch ~host:"localhost" routes "/page") ~target:"/page";
  check int "canonical host" 503 (dispatch routes "/page").status;
  check int "Public_read alone, alias host" 503 (dispatch ~host:"localhost" routes "/plain").status
;;

(* The same for the workspace precondition of a read: with one of its two
   parameters, or with values that do not match, an alias host is redirected and
   the canonical host gets the answer of the public read. *)
let test_alias_host_is_redirected_before_the_workspace_precondition () =
  with_authentication ~strict:false
  @@ fun ~base_path:_ ~worker:_ ~admin:_ ->
  let routes = page_routes () in
  let one_parameter = "?expected_base_path=/x" in
  let mismatch = "?expected_base_path=/nowhere&expected_masc_root=/nowhere/.masc" in
  List.iter
    (fun (label, query, canonical_status) ->
       check_redirected
         (label ^ ", alias host")
         (dispatch ~host:"localhost" routes ("/page" ^ query))
         ~target:("/page" ^ query);
       check int (label ^ ", canonical host") canonical_status (dispatch routes ("/page" ^ query)).status;
       check
         int
         (label ^ ", Public_read alone, alias host")
         canonical_status
         (dispatch ~host:"localhost" routes ("/plain" ^ query)).status)
    [ "one parameter", one_parameter, 400; "values that do not match", mismatch, 409 ]
;;

(* ---- one table: the log, the index and the effective routes ---- *)

let resolved_access routes method_ path =
  match Router.resolve routes (Httpun.Request.create method_ path) with
  | `Matched route -> access_json route.Router.access
  | `Method_not_allowed -> "method_not_allowed"
  | `Not_found -> "not_found"
;;

let effective_rows routes =
  List.map
    (fun (route : Router.route) ->
       route.path, List.map Httpun.Method.to_string route.methods, access_json route.access)
    (Router.effective_routes routes)
;;

let rows_t = list (triple string (list string) string)
let public_read = access_json Route_access.Public_read
let read_auth = access_json Route_access.Read_auth
let admin = access_json (Route_access.Permission Masc_domain.CanAdmin)

(* A router that was passed to a registration function and is used afterwards
   describes the same table in the list, the count and the lookup. *)
let test_older_reference_sees_the_table () =
  let first =
    Server_route.get Server_route.Always_public "/a" plain_handler (Router.create ())
  in
  let second = Server_route.get Server_route.Read_auth "/b" state_handler first in
  check int "count" 2 (Router.route_count first);
  check int "list" 2 (List.length (Router.routes first));
  check string "lookup" read_auth (resolved_access first `GET "/b");
  check int "the newer reference agrees" (Router.route_count second) (Router.route_count first)
;;

let test_the_later_registration_wins () =
  let routes =
    Router.create ()
    |> Server_route.get (Server_route.Permission Masc_domain.CanAdmin) "/p" state_handler
    |> Server_route.get Server_route.Public_read "/p" state_handler
  in
  check int "both registrations are logged" 2 (List.length (Router.routes routes));
  check rows_t "one row is effective, the later one" [ "/p", [ "GET" ], public_read ] (effective_rows routes);
  check string "dispatch agrees" public_read (resolved_access routes `GET "/p")
;;

let test_replaced_for_some_methods_only () =
  let routes =
    Router.create ()
    |> Server_route.add Server_route.Read_auth ~path:"/m" ~methods:[ `GET; `POST ] state_handler
    |> Server_route.get Server_route.Public_read "/m" state_handler
  in
  check
    rows_t
    "the earlier route keeps the method it still serves"
    [ "/m", [ "POST" ], read_auth; "/m", [ "GET" ], public_read ]
    (effective_rows routes);
  check string "GET goes to the later route" public_read (resolved_access routes `GET "/m");
  check string "POST goes to the earlier route" read_auth (resolved_access routes `POST "/m")
;;

let test_exact_and_prefix_both_apply () =
  let routes =
    Router.create ()
    |> Server_route.prefix_get Server_route.Read_auth "/a/" state_handler
    |> Server_route.get Server_route.Public_read "/a/b" state_handler
  in
  check
    rows_t
    "both are effective"
    [ "/a/", [ "GET" ], read_auth; "/a/b", [ "GET" ], public_read ]
    (effective_rows routes);
  check string "the exact path beats the prefix" public_read (resolved_access routes `GET "/a/b");
  check string "another path under the prefix" read_auth (resolved_access routes `GET "/a/c");
  (* The same string registered as an exact path and as a prefix is two routes. *)
  let both =
    Router.create ()
    |> Server_route.prefix_get Server_route.Read_auth "/s" state_handler
    |> Server_route.get Server_route.Public_read "/s" state_handler
  in
  check int "same string, exact and prefix" 2 (List.length (Router.effective_routes both))
;;

let test_prefix_precedence () =
  let same_prefix =
    Router.create ()
    |> Server_route.prefix_get Server_route.Read_auth "/a/" state_handler
    |> Server_route.prefix_get Server_route.Public_read "/a/" state_handler
  in
  check rows_t "equal prefixes: the newest" [ "/a/", [ "GET" ], public_read ] (effective_rows same_prefix);
  check string "equal prefixes: dispatch agrees" public_read (resolved_access same_prefix `GET "/a/x");
  let longest_first =
    Router.create ()
    |> Server_route.prefix_get Server_route.Public_read "/a/b/" state_handler
    |> Server_route.prefix_get Server_route.Read_auth "/a/" state_handler
  in
  let longest_last =
    Router.create ()
    |> Server_route.prefix_get Server_route.Read_auth "/a/" state_handler
    |> Server_route.prefix_get Server_route.Public_read "/a/b/" state_handler
  in
  List.iter
    (fun (name, routes) ->
       check int (name ^ ": both prefixes are effective") 2 (List.length (Router.effective_routes routes));
       check string (name ^ ": the longest prefix wins") public_read (resolved_access routes `GET "/a/b/x");
       check string (name ^ ": the shorter prefix elsewhere") read_auth (resolved_access routes `GET "/a/z"))
    [ "longest registered first", longest_first; "longest registered last", longest_last ]
;;

let test_unindexed_method_is_not_effective () =
  let routes =
    Router.create ()
    |> Server_route.add Server_route.Always_public ~path:"/h" ~methods:[ `HEAD ] plain_handler
  in
  check int "logged" 1 (List.length (Router.routes routes));
  check rows_t "no method of it is reachable" [] (effective_rows routes);
  check string "dispatch agrees" "method_not_allowed" (resolved_access routes `HEAD "/h")
;;

let () =
  run
    "server_route"
    [ ( "route table"
      , [ test_case "each kind is recorded on the route" `Quick test_records_the_kind
        ; test_case
            "access is what the registration records"
            `Quick
            test_access_matches_the_registered_kind
        ; test_case "method and kind follow the function" `Quick test_method_and_kind
        ; test_case
            "ws_get records the upgrade reason"
            `Quick
            test_ws_get_records_the_upgrade_reason
        ; test_case "inventory json" `Quick test_json_shape
        ] )
    ; ( "one table"
      , [ test_case "an older reference sees the same table" `Quick test_older_reference_sees_the_table
        ; test_case "the later registration of a path wins" `Quick test_the_later_registration_wins
        ; test_case "a route replaced for some methods keeps the others" `Quick test_replaced_for_some_methods_only
        ; test_case "an exact path and a prefix both apply" `Quick test_exact_and_prefix_both_apply
        ; test_case "equal prefixes and the longest prefix" `Quick test_prefix_precedence
        ; test_case "a method the router does not index" `Quick test_unindexed_method_is_not_effective
        ] )
    ; ( "dispatch"
      , [ test_case
            "without server state a wrapper stops the handler, the others run it"
            `Quick
            test_wrappers_gate_the_handler
        ; test_case "tool observations preserve operation quota" `Quick
            test_tool_observation_does_not_consume_operation_quota
        ; test_case "tool observations preserve anonymous origin authorization" `Quick
            test_tool_observation_preserves_anonymous_tool_authorization
        ; test_case
            "strict auth: each kind answers like its wrapper by hand"
            `Quick
            (test_typed_routes_answer_like_the_wrapper_by_hand ~strict:true)
        ; test_case
            "loopback: each kind answers like its wrapper by hand"
            `Quick
            (test_typed_routes_answer_like_the_wrapper_by_hand ~strict:false)
        ] )
    ; ( "canonical host"
      , [ test_case
            "an alias host is redirected while the server is not ready"
            `Quick
            test_alias_host_is_redirected_while_the_server_is_not_ready
        ; test_case
            "an alias host is redirected before the workspace precondition"
            `Quick
            test_alias_host_is_redirected_before_the_workspace_precondition
        ] )
    ]
;;
