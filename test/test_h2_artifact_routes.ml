(* Exercise artifact routes through the production H2 connection runner and
   compare their observable contract with the H1 router. The default live
   transport fixture uses a minimal synthetic transformer; the optional run
   uses the actual masc-artifact-document executable. *)
open Alcotest
module Http = Masc.Http_server_eio
module Live = Masc.Artifact_draft_live
module Draft = Masc.Artifact_draft

type reply = { status : int; headers : (string * string) list; body : string }
type transport = H1 | H2
type gateway =
  { client : H2_eio.Client.t
  ; flow : Eio_unix.Net.stream_socket_ty Eio.Resource.t
  ; router : Http.Router.t
  ; authority : Server_request_authority.authority
  ; mutable next_stream : int
  }

let member = Yojson.Safe.Util.member
let json reply = Yojson.Safe.from_string reply.body
let field_string name value = member name value |> Yojson.Safe.Util.to_string
let field_int name value = member name value |> Yojson.Safe.Util.to_int
let header name reply =
  List.find_map (fun (key, value) ->
    if String.equal (String.lowercase_ascii key) (String.lowercase_ascii name)
    then Some value else None) reply.headers
let header_has_token name token reply =
  match header name reply with
  | None -> false
  | Some value ->
    String.split_on_char ',' value
    |> List.exists (fun part -> String.equal (String.lowercase_ascii (String.trim part)) token)
let check_status label expected reply = check int label expected reply.status
let check_code label expected reply = check string label expected (field_string "code" (json reply))
let check_json label expected actual =
  check string label (Yojson.Safe.to_string expected) (Yojson.Safe.to_string actual)

let rec remove_tree path = match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path

let token base_path ~actor ~role = match Auth.create_token base_path ~agent_name:actor ~role with
  | Ok (token, _) -> token
  | Error error -> fail (Masc_domain.masc_error_to_string error)

let with_gateway ?(runtime = false) ?resources ?(zero_window = false) run =
  let base_path = Filename.temp_dir "h2-artifacts-" "" |> Unix.realpath in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  let previous_startup = Server_startup_state.snapshot () in
  let previous_fs = Fs_compat.get_fs_opt () in
  Fun.protect ~finally:(fun () ->
    Server_auth.For_testing.restore_server_state previous_state;
    Server_startup_state.For_testing.restore previous_startup;
    (match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ());
    remove_tree base_path) (fun () ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 40.0 (fun () ->
        Eio.Switch.run (fun sw ->
          Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
              if runtime then Process_eio.init ~cwd_default:(Eio.Stdenv.fs env)
                ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
              Fun.protect ~finally:(fun () -> if runtime then Process_eio.reset_for_testing ()) (fun () ->
                let state = if runtime then Masc.Mcp_server.create_state_eio ~sw
                  ~proc_mgr:(Eio.Stdenv.process_mgr env) ~fs:(Eio.Stdenv.fs env)
                  ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env)
                  ~net:(Eio.Stdenv.net env) ~base_path
                else Masc.Mcp_server.For_testing.create_state ~base_path in
                ignore (Masc.Workspace.init (Masc.Mcp_server.workspace_config state) ~agent_name:None);
                Auth.save_auth_config base_path
                  { Masc_domain.default_auth_config with enabled = true; require_token = true };
                let worker = token base_path ~actor:"worker" ~role:Masc_domain.Worker in
                let player = token base_path ~actor:"player" ~role:Masc_domain.Player in
                let admin = token base_path ~actor:"admin" ~role:Masc_domain.Admin in
                Server_auth.publish_server_state state;
                (match Server_startup_state.mark_state_ready () with
                 | Ok () -> () | Error error -> fail (Server_startup_state.state_ready_error_to_string error));
                let trust_policy = match Server_request_authority.make_trust_policy
                  ~bind_host:"localhost" ~bind_port:8935 ~explicit_base_url:None with
                  | Ok policy -> policy
                  | Error error -> fail (Server_request_authority.trust_policy_error_to_string error) in
                let authority = match Server_request_authority.of_host_port ~host:"localhost" ~port:8935 with
                  | Ok value -> value | Error `Malformed -> fail "invalid test authority" in
                let handler = Server_h2_gateway.make_request_handler ~trust_policy ~sw
                  ~clock:(Eio.Stdenv.clock env) ~server_start_time:0. in
                let server_flow, client_flow = Eio_unix.Net.socketpair_stream ~sw () in
                let server = Eio.Fiber.fork_promise ~sw (fun () ->
                  Eio.Switch.run (fun conn_sw ->
                    Server_bootstrap_http.serve_h2_connection ?resources ~sw:conn_sw
                      ~h2_request_handler:handler ~h2_error_handler:(Server_h2_gateway.make_error_handler ())
                      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321)) server_flow)) in
                let closing = ref false in
                let config = if zero_window then { H2.Config.default with initial_window_size = 0l } else H2.Config.default in
                let client = H2_eio.Client.create_connection ~sw ~config
                  ~error_handler:(fun _ -> if not !closing then fail "H2 connection failed") client_flow in
                let router = Http.Router.create ()
                  |> Server_routes_http_routes_published_artifacts.add_routes
                  |> Server_routes_http_routes_artifact_app_data.add_routes
                  |> Server_routes_http_routes_artifact_drafts.add_routes
                  |> Server_routes_http_routes_artifact_draft_live.add_routes in
                let gateway = { client; flow = client_flow; router; authority; next_stream = 1 } in
                Fun.protect ~finally:(fun () -> closing := true; Eio.Flow.shutdown client_flow `All) (fun () ->
                  run ~base_path ~worker ~player ~admin gateway);
                Eio.Promise.await_exn server))))))

let auth_headers = function None -> [] | Some token -> ["authorization", "Bearer " ^ token]
let split_h1 wire =
  let rec boundary at =
    if at + 4 > String.length wire then failf "no H1 response boundary: %S" wire
    else if String.sub wire at 4 = "\r\n\r\n" then at else boundary (at + 1) in
  let at = boundary 0 in
  let lines = String.sub wire 0 at |> String.split_on_char '\n' |> List.map String.trim in
  let status = match lines with
    | first :: _ -> (match String.split_on_char ' ' first with _ :: code :: _ -> int_of_string code | _ -> fail "bad H1 status")
    | [] -> fail "missing H1 status" in
  let headers = List.filter_map (fun line -> match String.index_opt line ':' with
    | None -> None
    | Some n -> Some (String.sub line 0 n, String.trim (String.sub line (n + 1) (String.length line - n - 1)))) lines in
  { status; headers; body = String.sub wire (at + 4) (String.length wire - at - 4) }

let h1_request gateway ~meth ~path ~headers ~body =
  let output = Buffer.create 2048 in
  let connection = Httpun.Server_connection.create (fun reqd ->
    let request = Httpun.Reqd.request reqd in
    Server_request_authority.with_current gateway.authority (fun () ->
      Server_workspace_precondition.guard_http1 ~path:(Http.Request.path request) request reqd
        ~admitted:(fun () -> match request.Httpun.Request.meth with
          | `OPTIONS -> Server_routes_http_runtime.options_handler request reqd
          | _ -> Http.Router.dispatch gateway.router request reqd))) in
  let fields = List.map (fun (key, value) -> key ^ ": " ^ value ^ "\r\n") headers |> String.concat "" in
  let head = Printf.sprintf "%s %s HTTP/1.1\r\nHost: localhost:8935\r\n%sContent-Length: %d\r\n\r\n"
    (Httpun.Method.to_string meth) path fields (String.length body) in
  let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length head) head in
  ignore (Httpun.Server_connection.read connection bytes ~off:0 ~len:(Bigstringaf.length bytes));
  (* Deliver body bytes after dispatch has returned and its authority binding
     has ended, matching the actual asynchronous HTTP/1 callback boundary. *)
  let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length body) body in
  ignore (Httpun.Server_connection.read_eof connection bytes ~off:0 ~len:(Bigstringaf.length bytes));
  let rec drain () = match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let n = List.fold_left (fun n (iov : Bigstringaf.t Httpun.IOVec.t) ->
        Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len); n + iov.len) 0 iovecs in
      Httpun.Server_connection.report_write_result connection (`Ok n); drain ()
    | `Yield when Buffer.length output = 0 ->
      let ready, resolve = Eio.Promise.create () in
      Httpun.Server_connection.yield_writer connection (fun () -> Eio.Promise.resolve resolve ());
      Eio.Promise.await ready; drain ()
    | `Yield | `Close _ -> () in
  drain (); split_h1 (Buffer.contents output)

let h2_request gateway ~meth ~path ~headers ~body =
  gateway.next_stream <- gateway.next_stream + 2;
  let result, resolve = Eio.Promise.create () in
  let request = H2.Request.create ~scheme:"http" meth path
    ~headers:(H2.Headers.of_list ((":authority", "localhost:8935") :: headers)) in
  let writer = H2_eio.Client.request gateway.client ~flush_headers_immediately:true request
    ~error_handler:(fun _ -> if not (Eio.Promise.is_resolved result) then Eio.Promise.resolve resolve (Error ()))
    ~response_handler:(fun response reader ->
      let bytes = Buffer.create 1024 in
      let rec read () = H2.Body.Reader.schedule_read reader
        ~on_eof:(fun () -> if not (Eio.Promise.is_resolved result) then
          Eio.Promise.resolve resolve (Ok { status = H2.Status.to_code response.status;
            headers = H2.Headers.to_list response.headers; body = Buffer.contents bytes }))
        ~on_read:(fun chunk ~off ~len ->
          Buffer.add_string bytes (Bigstringaf.substring chunk ~off ~len); read ()) in
      read ()) in
  H2.Body.Writer.write_string writer body;
  (* A close before the flush settles can discard queued DATA when a body
     crosses the initial HTTP/2 flow-control window. *)
  H2.Body.Writer.flush writer (fun _ -> H2.Body.Writer.close writer);
  match Eio.Promise.await result with Ok reply -> reply | Error () -> fail "H2 stream failed"

let request transport gateway ?token ?(headers = []) ?(meth = `GET) ?(body = "") path =
  let headers = auth_headers token @ headers in
  match transport with
  | H1 -> h1_request gateway ~meth ~path ~headers ~body
  | H2 -> h2_request gateway ~meth ~path ~headers ~body

let both gateway ?token ?headers ?meth ?body path =
  request H1 gateway ?token ?headers ?meth ?body path,
  request H2 gateway ?token ?headers ?meth ?body path
let pair_status label expected (h1, h2) =
  check_status (label ^ " H1") expected h1; check_status (label ^ " H2") expected h2
let pair_code label expected (h1, h2) =
  check_code (label ^ " H1") expected h1; check_code (label ^ " H2") expected h2
let body fields = Yojson.Safe.to_string (`Assoc fields)
let publication_body ?id ?revision content = body
  ((match id, revision with None, None -> [] | Some id, Some revision ->
    ["id", `String id; "expected_revision", `Int revision] | _ -> fail "bad revision fixture") @
   ["title", `String "H2 document"; "summary", `String "shared fixture";
    "format", `String "markdown"; "content", `String content])
let list = "/api/v1/published-artifacts"
let checks = "/api/v1/published-artifact-checks"
let shares = "/api/v1/published-artifact-shares"
let app_data = "/api/v1/artifact-app-data"
let drafts = "/api/v1/artifact-drafts"
let checkpoints = "/api/v1/artifact-draft-checkpoints"

let test_access_and_preconditions () = with_gateway (fun ~base_path ~worker ~player ~admin gateway ->
  let created = request H2 gateway ~token:worker ~meth:`POST ~body:(publication_body "version one") list in
  check_status "Worker publishes over H2" 201 created;
  let artifact = member "artifact" (json created) in
  let id = field_string "id" artifact in
  let digest = member "body" artifact |> member "_blob" |> field_string "sha256" in
  check string "publication records token-bound actor" "worker" (field_string "author" artifact);
  let doc = list ^ "/" ^ id in
  List.iter (fun (label, token, expected) ->
    pair_status label expected (both gateway ?token list);
    pair_status (label ^ " checks") expected (both gateway ?token checks))
    ["Worker", Some worker, 200; "Player", Some player, 403; "anonymous", None, 401; "invalid token", Some "invalid", 401];
  List.iter (fun (label, token, expected) -> pair_status label expected (both gateway ?token doc))
    ["private Worker", Some worker, 200; "private Player", Some player, 403;
     "private anonymous", None, 401; "private invalid token", Some "invalid", 401];
  let h1, h2 = both gateway ~token:worker doc in
  check_json "same exact source and metadata over both transports" (json h1) (json h2);
  List.iter (fun reply -> check (option string) "private no-store" (Some "private, no-store") (header "cache-control" reply)) [h1; h2];
  let etag = match header "etag" h1 with Some value -> value | None -> fail "H1 omitted its JSON validator" in
  check (option string) "same JSON validator over H2" (Some etag) (header "etag" h2);
  let cached_h1, cached_h2 = both gateway ~token:worker ~headers:["if-none-match", etag] doc in
  List.iter (fun reply ->
    check_status "matching validator returns 304" 304 reply;
    check string "304 contains no body" "" reply.body;
    check (option string) "304 retains validator" (Some etag) (header "etag" reply);
    check (option string) "304 remains private no-store" (Some "private, no-store") (header "cache-control" reply))
    [cached_h1; cached_h2];
  let write_paths = [list; drafts; checkpoints; "/api/v1/artifact-draft-presence"] in
  List.iter (fun path ->
    List.iter (fun (label, token, expected) ->
      pair_status (path ^ " " ^ label) expected (both gateway ?token ~meth:`POST ~body:"{}" path))
      ["Worker reaches parser", Some worker, 400; "Player", Some player, 403;
       "anonymous", None, 401; "invalid", Some "invalid", 401]) write_paths;
  List.iter (fun path ->
    List.iter (fun (label, token, expected) ->
      pair_status (path ^ " " ^ label) expected (both gateway ?token ~meth:`POST ~body:"{}" path))
      ["Worker", Some worker, 403; "Player", Some player, 403;
       "anonymous", None, 401; "Admin reaches parser", Some admin, 400]) [checks; shares];
  let draft_path = drafts ^ "/" ^ id in
  List.iter (fun (label, token, expected) -> pair_status label expected (both gateway ?token draft_path))
    ["Worker reaches draft store", Some worker, 404; "Player draft", Some player, 403;
     "anonymous draft", None, 401; "invalid draft credential", Some "invalid", 401];
  let events = "/api/v1/artifact-draft-events/" ^ id ^ "?generation=019f0000-0000-7000-8000-000000000000" in
  List.iter (fun (label, token, expected) -> pair_status label expected (both gateway ?token events))
    ["Worker reaches SSE admission without runtime", Some worker, 503; "Player SSE", Some player, 403;
     "anonymous SSE", None, 401; "invalid SSE credential", Some "invalid", 401];
  let target = `Assoc ["artifact_id", `String id; "generation", `String "019f0000-0000-7000-8000-000000000000"] in
  let invalid_checkpoint = body ["target", target; "expected_sequence", `Int (-1); "revision", `Int 1] in
  let target_text = Yojson.Safe.to_string target in
  let invalid_bodies = [invalid_checkpoint;
    "{\"target\":" ^ target_text ^ ",\"expected_sequence\":0,\"revision\":1,\"extra\":true}";
    "{\"target\":" ^ target_text ^ ",\"expected_sequence\":0,\"revision\":1,\"revision\":1}";
    "{\"target\":" ^ target_text ^ ",\"expected_sequence\":9007199254740992,\"revision\":1}";
    "{\"target\":" ^ target_text ^ ",\"expected_sequence\":0,\"revision\":1.0}"] in
  List.iter (fun invalid ->
    let rejected = both gateway ~token:worker ~meth:`POST ~body:invalid checkpoints in
    pair_status "checkpoint validates its exact fields and safe integers" 400 rejected;
    pair_code "checkpoint validation code" "invalid_artifact_draft" rejected) invalid_bodies;
  let valid_checkpoint = body ["target", target; "expected_sequence", `Int 0; "revision", `Int 1] in
  let missing = both gateway ~token:worker ~meth:`POST ~body:valid_checkpoint checkpoints in
  pair_status "valid checkpoint reaches store" 404 missing;
  pair_code "missing checkpoint" "artifact_draft_not_found" missing;
  let expected = match Server_workspace_precondition.served_workspace () with
    | Some value -> value | None -> fail "workspace unavailable" in
  let h2_headers = ["x-masc-expected-base-path", expected.base_path; "x-masc-expected-masc-root", expected.masc_root] in
  let foreign_headers = ["x-masc-expected-base-path", "/foreign-workspace"; "x-masc-expected-masc-root", expected.masc_root] in
  let update = publication_body ~id ~revision:1 "foreign write must not commit" in
  let blocked = both gateway ~token:worker ~meth:`POST ~headers:foreign_headers ~body:update list in
  pair_status "header blocks write before dispatch" 409 blocked;
  pair_code "header workspace refusal" "workspace_precondition_failed" blocked;
  let incomplete = both gateway ~token:worker ~meth:`POST
    ~headers:["x-masc-expected-base-path", expected.base_path] ~body:update list in
  pair_status "incomplete workspace headers" 400 incomplete;
  let encode = Uri.pct_encode ~component:`Query_value in
  let query base root = "?expected_base_path=" ^ encode base ^ "&expected_masc_root=" ^ encode root in
  let matched_h1, matched_h2 = both gateway ~token:worker (doc ^ query expected.base_path expected.masc_root) in
  List.iter (fun reply ->
    check_status "matching GET workspace" 200 reply;
    check (option string) "matching GET receipt" (Some "matched-v1") (header "x-masc-workspace-read" reply);
    check string "foreign write had no effect" "version one" (field_string "content" (json reply))) [matched_h1; matched_h2];
  let matched_304_h1, matched_304_h2 = both gateway ~token:worker ~headers:["if-none-match", etag]
    (doc ^ query expected.base_path expected.masc_root) in
  List.iter (fun reply ->
    check_status "matching workspace conditional GET" 304 reply;
    check (option string) "304 retains workspace admission receipt" (Some "matched-v1")
      (header "x-masc-workspace-read" reply)) [matched_304_h1; matched_304_h2];
  let foreign_query = both gateway ~token:worker (doc ^ query "/foreign-workspace" expected.masc_root) in
  pair_status "GET query blocks wrong workspace" 409 foreign_query;
  pair_code "GET workspace refusal" "workspace_precondition_failed" foreign_query;
  (* This test executable starts with an unconfigured HTTP auth policy.
     Install the same explicit loopback development Origin used by the
     authority tests and restore that initial state even on failure. *)
  let dev_origin = "http://localhost:4173" in
  let dev_config = match Server_auth_config.resolve
      { allow_anonymous_mutations = None; loopback_dev_mutation_origins = Some dev_origin } with
    | Ok config -> config | Error error -> fail (Server_auth_config.resolve_error_to_string error) in
  Server_auth.For_testing.restore_auth_config (Some dev_config);
  Fun.protect ~finally:(fun () -> Server_auth.For_testing.restore_auth_config None) (fun () ->
    let requested_headers = "authorization, x-masc-expected-base-path, x-masc-expected-masc-root" in
    let preflight origin = both gateway ~meth:`OPTIONS
      ~headers:["origin", origin; "access-control-request-method", "GET";
        "access-control-request-headers", requested_headers] doc in
    let h1_preflight, h2_preflight = preflight dev_origin in
    List.iter (fun reply ->
      check_status "allowed development Origin gets a preflight" 204 reply;
      check (option string) "preflight reflects allowed Origin" (Some dev_origin)
        (header "access-control-allow-origin" reply);
      List.iter (fun name -> check bool "workspace request header allowed by preflight" true
        (header_has_token "access-control-allow-headers" name reply))
        ["authorization"; "x-masc-expected-base-path"; "x-masc-expected-masc-root"])
      [h1_preflight; h2_preflight];
    let denied_h1, denied_h2 = preflight "https://untrusted.example" in
    List.iter (fun reply ->
      check (option string) "untrusted preflight does not gain CORS admission" None
        (header "access-control-allow-origin" reply)) [denied_h1; denied_h2];
    let bound_h1, bound_h2 = both gateway ~token:worker ~headers:["origin", dev_origin]
      (doc ^ query expected.base_path expected.masc_root) in
    List.iter (fun reply ->
      check_status "allowed development Origin reads a bound document" 200 reply;
      check bool "bound response exposes workspace admission" true
        (header_has_token "access-control-expose-headers" "x-masc-workspace-read" reply))
      [bound_h1; bound_h2];
    let check_ingress_refusal label ~status ~code ~retry_after headers =
      List.iter (fun (origin, allowed) ->
        let replies = both gateway ~token:worker ~meth:`POST ~body:update
          ~headers:(("origin", origin) :: headers) list in
        pair_status label status replies;
        pair_code label code replies;
        let h1, h2 = replies in
        List.iter (fun reply ->
          check (option string) (label ^ " admitted Origin")
            (if allowed then Some origin else None) (header "access-control-allow-origin" reply);
          check (option string) (label ^ " admitted credentials")
            (if allowed then Some "true" else None) (header "access-control-allow-credentials" reply);
          check (option string) (label ^ " varies by Origin") (Some "Origin") (header "vary" reply);
          check (option string) (label ^ " retry-after") retry_after (header "retry-after" reply))
          [h1; h2])
        [dev_origin, true; "https://untrusted.example", false] in
    check_ingress_refusal "mismatched workspace headers" ~status:409
      ~code:"workspace_precondition_failed" ~retry_after:None foreign_headers;
    check_ingress_refusal "incomplete workspace headers" ~status:400
      ~code:"invalid_workspace_precondition" ~retry_after:None
      ["x-masc-expected-base-path", expected.base_path];
    let startup = Server_startup_state.snapshot () in
    Fun.protect ~finally:(fun () -> Server_startup_state.For_testing.restore startup) (fun () ->
      Server_startup_state.For_testing.restore { startup with state_ready = false };
      check_ingress_refusal "workspace admission while booting" ~status:503
        ~code:"server_booting" ~retry_after:(Some "1") h2_headers);
    List.iter (fun path ->
      let h1, h2 = both gateway ~token:worker ~headers:["origin", dev_origin]
        (path ^ query "/foreign-workspace" expected.masc_root) in
      pair_status "allowed development Origin receives workspace refusal" 409 (h1, h2);
      pair_code "same workspace refusal code" "workspace_precondition_failed" (h1, h2);
      List.iter (fun reply ->
        check (option string) "409 preserves allowed development Origin" (Some dev_origin)
          (header "access-control-allow-origin" reply);
        check (option string) "409 preserves allowed credentials" (Some "true")
          (header "access-control-allow-credentials" reply);
        check (option string) "409 varies by Origin" (Some "Origin") (header "vary" reply)) [h1; h2])
      [doc; list; checks];
    let h1, h2 = both gateway ~token:worker ~headers:["origin", "https://untrusted.example"]
      (doc ^ query "/foreign-workspace" expected.masc_root) in
    pair_status "untrusted Origin still receives workspace refusal" 409 (h1, h2);
    List.iter (fun reply ->
      check (option string) "409 does not reflect an untrusted Origin" None
        (header "access-control-allow-origin" reply);
      check (option string) "untrusted 409 varies by Origin" (Some "Origin") (header "vary" reply)) [h1; h2]);
  List.iter (fun path ->
    pair_status "workspace query also guards catalog/check/draft reads" 409
      (both gateway ~token:worker (path ^ query "/foreign-workspace" expected.masc_root)))
    [list; checks; draft_path];
  let incomplete_query = both gateway ~token:worker (doc ^ "?expected_base_path=" ^ encode expected.base_path) in
  pair_status "incomplete GET workspace query" 400 incomplete_query;
  let no_draft_foreign = both gateway ~token:worker ~meth:`POST ~headers:foreign_headers ~body:valid_checkpoint checkpoints in
  pair_status "foreign checkpoint refused before store" 409 no_draft_foreign;
  let check_body = body ["id", `String id; "revision", `Int 1; "body_sha256", `String digest;
    "checked", `Bool true; "expected_change_id", `Null] in
  let denied_check = request H2 gateway ~token:worker ~meth:`POST ~body:check_body checks in
  check_status "Worker cannot change shared check" 403 denied_check;
  pair_status "foreign workspace cannot change shared check" 409
    (both gateway ~token:admin ~meth:`POST ~headers:foreign_headers ~body:check_body checks);
  let checks_before = request H2 gateway ~token:worker checks |> json |> member "checks" |> Yojson.Safe.Util.to_list in
  check int "rejected check did not mutate inventory" 0 (List.length checks_before);
  let set_check = request H2 gateway ~token:admin ~meth:`POST ~headers:h2_headers ~body:check_body checks in
  check_status "Admin may confirm exact revision" 200 set_check;
  check string "authenticated check actor" "admin" (member "check" (json set_check) |> field_string "changed_by");
  let h1, h2 = both gateway ~token:worker checks in
  check_json "same checked version over H1 and H2" (json h1) (json h2);
  let share_body = body ["id", `String id; "shared", `Bool true] in
  check_status "Worker cannot enable external sharing" 403 (request H2 gateway ~token:worker ~meth:`POST ~body:share_body shares);
  pair_status "foreign workspace cannot enable sharing" 409
    (both gateway ~token:admin ~meth:`POST ~headers:foreign_headers ~body:share_body shares);
  pair_status "rejected share leaves document private" 401 (both gateway doc);
  check_status "Admin enables external sharing" 200 (request H2 gateway ~token:admin ~meth:`POST ~body:share_body shares);
  pair_status "explicit shared link is public" 200 (both gateway doc);
  let same_origin = "http://localhost:8935" in
  let origin_headers = ["origin", same_origin] in
  let origin_publication = request H1 gateway ~token:worker ~headers:origin_headers ~meth:`POST
    ~body:(publication_body "origin split body") list in
  check_status "H1 split-body publication with Origin succeeds" 201 origin_publication;
  check (option string) "H1 delayed publication retains admitted Origin" (Some same_origin)
    (header "access-control-allow-origin" origin_publication);
  let origin_id = member "artifact" (json origin_publication) |> field_string "id" in
  let origin_readback = request H2 gateway ~token:worker (list ^ "/" ^ origin_id) in
  check string "H2 reads H1 split-body publication" "origin split body" (field_string "content" (json origin_readback));
  let origin_share = request H1 gateway ~token:admin ~headers:origin_headers ~meth:`POST ~body:share_body shares in
  check_status "H1 split-body share with Origin succeeds" 200 origin_share;
  check (option string) "H1 delayed share retains admitted Origin" (Some same_origin)
    (header "access-control-allow-origin" origin_share);
  let origin_checkpoint = request H1 gateway ~token:worker ~headers:origin_headers ~meth:`POST
    ~body:valid_checkpoint checkpoints in
  check_status "H1 split-body checkpoint reaches store" 404 origin_checkpoint;
  check (option string) "H1 delayed checkpoint retains admitted Origin" (Some same_origin)
    (header "access-control-allow-origin" origin_checkpoint);
  let permitted_h1, permitted_h2 = both gateway ~headers:["origin", same_origin] doc in
  List.iter (fun reply ->
    check_status "same-origin shared read" 200 reply;
    check (option string) "admitted origin reflected" (Some same_origin) (header "access-control-allow-origin" reply))
    [permitted_h1; permitted_h2];
  let refused_h1, refused_h2 = both gateway ~headers:["origin", "https://untrusted.example"] doc in
  List.iter (fun reply ->
    check_status "public document can be fetched without a credential" 200 reply;
    check (option string) "untrusted browser origin cannot read via CORS" None (header "access-control-allow-origin" reply);
    check (option string) "origin-sensitive response varies by origin" (Some "Origin") (header "vary" reply))
    [refused_h1; refused_h2];
  pair_status "Player credential is not anonymous" 403 (both gateway ~token:player doc);
  pair_status "invalid credential is not anonymous" 401 (both gateway ~token:"invalid" doc);
  pair_status "external sharing never exposes catalog" 401 (both gateway list);
  let revised = request H2 gateway ~token:worker ~meth:`POST ~headers:h2_headers
    ~body:(publication_body ~id ~revision:1 "version two") list in
  check_status "Worker publishes next revision" 201 revised;
  check int "version increment" 2 (member "artifact" (json revised) |> field_int "revision");
  let h1, h2 = both gateway ~token:worker doc in
  check_json "same latest version over H1 and H2" (json h1) (json h2);
  check string "read back exact published source" "version two" (field_string "content" (json h2));
  let stale = both gateway ~token:worker ~meth:`POST ~body:(publication_body ~id ~revision:1 "stale") list in
  pair_status "stale CAS rejected" 409 stale;
  pair_code "stale CAS code" "artifact_revision_conflict" stale;
  let large_source = String.make (2 * 65535 + 17) 'q' in
  let large = request H2 gateway ~token:worker ~meth:`POST
    ~body:(publication_body ~id ~revision:2 large_source) list in
  check_status "body larger than initial H2 window publishes completely" 201 large;
  let h1, h2 = both gateway ~token:worker doc in
  check string "H1 reads every posted byte" large_source (field_string "content" (json h1));
  check string "H2 reads every posted byte" large_source (field_string "content" (json h2));
  let oversize = String.make (Http.Request.max_body_bytes + 1) 'x' in
  let rejected = both gateway ~token:worker ~meth:`POST ~body:oversize list in
  pair_status "oversize body rejected by both transports" 413 rejected;
  let h1, h2 = both gateway ~token:worker doc in
  check string "oversize request did not mutate H1 readback" large_source (field_string "content" (json h1));
  check string "oversize request did not mutate H2 readback" large_source (field_string "content" (json h2));
  let html = body ["title", `String "H2 HTML app"; "summary", `String "input fixture";
    "format", `String "html"; "content", `String "<form><input></form>"] in
  let created_app = request H2 gateway ~token:worker ~meth:`POST ~body:html list in
  check_status "create HTML app" 201 created_app;
  let app_id = member "artifact" (json created_app) |> field_string "id" in
  let app_path = app_data ^ "/" ^ app_id ^ "?revision=1" in
  List.iter (fun (label, credential, expected) ->
    pair_status ("app input read " ^ label) expected (both gateway ?token:credential app_path);
    if expected <> 200 then pair_status ("app input write " ^ label) expected
      (both gateway ?token:credential ~meth:`POST ~body:"{}" app_data))
    ["Admin", Some admin, 200; "Worker", Some worker, 403; "Player", Some player, 403;
     "anonymous", None, 401; "invalid", Some "invalid", 401];
  let h1, h2 = both gateway ~token:admin app_path in
  check_json "same empty app input over both transports" (json h1) (json h2);
  check int "new app input version" 0 (field_int "version" (json h2));
  let input_target = `Assoc ["artifact_id", `String app_id; "revision", `Int 1] in
  let input_body = body ["target", input_target; "id", `String "019f0000-0000-7000-8000-000000000001";
    "expected_version", `Int 0; "data", `Assoc ["answer", `String "alice"]] in
  let written = request H2 gateway ~token:admin ~headers:h2_headers ~meth:`POST ~body:input_body app_data in
  check_status "Admin writes app input on H2" 200 written;
  check string "token owns app input" "admin" (field_string "actor" (json written));
  check int "app input advances once" 1 (field_int "version" (json written));
  let replay = request H1 gateway ~token:admin ~headers:origin_headers ~meth:`POST ~body:input_body app_data in
  check_status "same app request replays on H1" 200 replay;
  check (option string) "H1 delayed app input retains admitted Origin" (Some same_origin)
    (header "access-control-allow-origin" replay);
  check_json "idempotent app receipt is transport independent" (json written) (json replay);
  let h1, h2 = both gateway ~token:admin app_path in
  check_json "same stored app data over H1 and H2" (json h1) (json h2);
  check string "stored input is preserved" "alice" (member "data" (json h2) |> field_string "answer");
  let other_admin = token base_path ~actor:"second-admin" ~role:Masc_domain.Admin in
  let other = both gateway ~token:other_admin app_path in
  pair_status "another actor can read only its own input" 200 other;
  let _, other_h2 = other in
  check int "another actor starts with an empty input" 0 (field_int "version" (json other_h2));
  check string "another actor's identity is retained" "second-admin" (field_string "actor" (json other_h2));
  let input_next = body ["target", input_target; "id", `String "019f0000-0000-7000-8000-000000000002";
    "expected_version", `Int 1; "data", `Assoc ["answer", `String "wrong workspace"]] in
  pair_status "foreign workspace rejects app input write" 409
    (both gateway ~token:admin ~headers:foreign_headers ~meth:`POST ~body:input_next app_data);
  let h1, h2 = both gateway ~token:admin app_path in
  List.iter (fun reply -> check string "refused app input write left data unchanged" "alice"
    (member "data" (json reply) |> field_string "answer")) [h1; h2];
  let query = "&expected_base_path=" ^ encode expected.base_path ^ "&expected_masc_root=" ^ encode expected.masc_root in
  let app_bound_h1, app_bound_h2 = both gateway ~token:admin (app_path ^ query) in
  List.iter (fun reply ->
    check_status "bound app read" 200 reply;
    check (option string) "bound app read admission" (Some "matched-v1") (header "x-masc-workspace-read" reply))
    [app_bound_h1; app_bound_h2])

let reset_frame stream_id =
  let frame = Bytes.of_string "\000\000\004\003\000\000\000\000\000\000\000\000\008" in
  Bytes.set_int32_be frame 5 (Int32.of_int stream_id);
  Bytes.to_string frame

let open_draft_stream gateway ~worker ~headers ~path =
  let stream_id = gateway.next_stream in
  gateway.next_stream <- stream_id + 2;
  let first, resolve = Eio.Promise.create () in
  let buffer = Buffer.create 1024 in
  let request = H2.Request.create ~scheme:"http" `GET path
    ~headers:(H2.Headers.of_list ((":authority", "localhost:8935") ::
      ("authorization", "Bearer " ^ worker) :: headers)) in
  let writer = H2_eio.Client.request gateway.client ~flush_headers_immediately:true request
    ~error_handler:(fun _ -> if not (Eio.Promise.is_resolved first) then Eio.Promise.resolve resolve (Error "SSE stream failed"))
    ~response_handler:(fun response reader ->
      if H2.Status.to_code response.status <> 200 then (
        if not (Eio.Promise.is_resolved first) then Eio.Promise.resolve resolve (Error "SSE admission refused"))
      else
        let rec read () = H2.Body.Reader.schedule_read reader
          ~on_eof:(fun () -> if not (Eio.Promise.is_resolved first) then Eio.Promise.resolve resolve (Error "SSE closed before initial frame"))
          ~on_read:(fun chunk ~off ~len ->
            Buffer.add_string buffer (Bigstringaf.substring chunk ~off ~len);
            if not (Eio.Promise.is_resolved first) then (
              (* The trailing split element is incomplete until a newline. *)
              let complete = String.split_on_char '\n' (Buffer.contents buffer) |> List.rev |> List.tl |> List.rev in
              match List.find_opt (String.starts_with ~prefix:"data: ") complete with
              | None -> ()
              | Some line ->
                check bool "first SSE event is a draft frame" true
                  (String.starts_with ~prefix:"event: draft\n" (Buffer.contents buffer));
                let payload = String.sub line 6 (String.length line - 6) in
                Eio.Promise.resolve resolve (Ok (response, Yojson.Safe.from_string payload)));
            read ()) in
        read ()) in
  H2.Body.Writer.flush writer (fun _ -> H2.Body.Writer.close writer);
  match Eio.Promise.await first with
  | Error message -> fail message
  | Ok (response, frame) -> stream_id, response, frame

let test_live_checkpoint () = with_gateway ~runtime:true (fun ~base_path ~worker ~player:_ ~admin:_ gateway ->
  let source = "published shared source\r\n한글 😀\n" in
  let created = request H2 gateway ~token:worker ~meth:`POST ~body:(publication_body source) list in
  check_status "publish draft base over H2" 201 created;
  let id = member "artifact" (json created) |> field_string "id" in
  let opened = request H2 gateway ~token:worker ~meth:`POST
    ~body:(body ["action", `String "open"; "artifact_id", `String id; "revision", `Int 1]) drafts in
  check_status "open a real shared draft over H2" 200 opened;
  let document = json opened in
  let draft = member "draft" document in
  let target_json = member "target" draft in
  let target = match Draft.target_of_json target_json with Ok target -> target | Error message -> fail message in
  check int "new draft sequence" 0 (field_int "sequence" draft);
  let h1, h2 = both gateway ~token:worker (drafts ^ "/" ^ id) in
  check_status "H1 reads real draft" 200 h1;
  check_status "H2 reads real draft" 200 h2;
  check_json "same draft over both transports" (json h1) (json h2);
  check string "draft source preserved" source (field_string "content" (json h2));
  let observer = Live.join ~base_path ~actor:"other-worker" ~source:Live.Dashboard_connection ~target in
  Fun.protect ~finally:(fun () -> Live.leave observer) (fun () ->
    let path = "/api/v1/artifact-draft-events/" ^ id ^ "?generation=" ^ target.generation in
    let expected = match Server_workspace_precondition.served_workspace () with
      | Some value -> value | None -> fail "workspace unavailable" in
    let encode = Uri.pct_encode ~component:`Query_value in
    let bound base root = path ^ "&expected_base_path=" ^ encode base
      ^ "&expected_masc_root=" ^ encode root in
    let receipt = "x-masc-workspace-read" in
    let origin_headers = ["origin", "http://localhost:8935"] in
    let leave_h1_session () =
      let peers = match Live.observe observer with
        | None -> fail "observer unexpectedly closed"
        | Some (frame, _) -> member "peers" frame |> Yojson.Safe.Util.to_list in
      let workers = List.filter (fun peer -> field_string "actor" peer = "worker") peers in
      check int "one H1 session to clean up" 1 (List.length workers);
      let session_id = field_string "session_id" (List.hd workers) in
      (match Live.find ~base_path ~actor:"worker" ~target ~session_id with
       | Error _ -> fail "H1 session missing before cleanup"
       | Ok session -> Live.leave session);
      Eio.Fiber.yield ();
      let remaining = match Live.observe observer with
        | None -> fail "observer unexpectedly closed"
        | Some (frame, _) -> member "peers" frame |> Yojson.Safe.Util.to_list in
      check bool "H1 session left before the next request" false
        (List.exists (fun peer -> field_string "actor" peer = "worker") remaining) in
    let unbound_h1 = request H1 gateway ~token:worker path in
    check_status "unbound H1 SSE" 200 unbound_h1;
    check (option string) "unbound H1 SSE has no admission receipt" None (header receipt unbound_h1);
    leave_h1_session ();
    let bound_h1 = request H1 gateway ~token:worker ~headers:origin_headers
      (bound expected.base_path expected.masc_root) in
    check_status "workspace-bound H1 SSE" 200 bound_h1;
    check (option string) "H1 SSE carries its workspace admission" (Some "matched-v1") (header receipt bound_h1);
    check int "H1 SSE admission is not duplicated" 1
      (List.length (List.filter (fun (name, _) -> String.lowercase_ascii name = receipt) bound_h1.headers));
    check bool "H1 SSE exposes workspace admission to allowed Origin" true
      (header_has_token "access-control-expose-headers" receipt bound_h1);
    leave_h1_session ();
    pair_status "foreign workspace cannot open SSE" 409
      (both gateway ~token:worker (bound "/foreign-workspace" expected.masc_root));
    let unbound_id, unbound_response, _ = open_draft_stream gateway ~worker ~headers:[] ~path in
    check (option string) "unbound H2 SSE has no admission receipt" None
      (H2.Headers.get unbound_response.headers receipt);
    Eio.Flow.copy_string (reset_frame unbound_id) gateway.flow;
    let stream_id, response, frame = open_draft_stream gateway ~worker ~headers:origin_headers
      ~path:(bound expected.base_path expected.masc_root) in
    check (option string) "H2 SSE carries its workspace admission" (Some "matched-v1")
      (H2.Headers.get response.headers receipt);
    check int "H2 SSE admission is not duplicated" 1
      (List.length (List.filter (fun (name, _) -> String.lowercase_ascii name = receipt)
        (H2.Headers.to_list response.headers)));
    check bool "H2 SSE exposes workspace admission to allowed Origin" true
      (H2.Headers.to_list response.headers |> List.exists (fun (name, value) ->
        String.lowercase_ascii name = "access-control-expose-headers"
        && (String.split_on_char ',' value |> List.exists (fun part ->
          String.lowercase_ascii (String.trim part) = receipt))));
    check (option string) "SSE type" (Some "text/event-stream") (H2.Headers.get response.headers "content-type");
    check (option string) "SSE is not cached" (Some "private, no-store") (H2.Headers.get response.headers "cache-control");
    check string "SSE frame schema" "masc.artifact_draft_live.v1" (field_string "schema" frame);
    check_json "SSE frame names the same draft generation" target_json (member "target" frame);
    check string "SSE initial draft contains the real source" source
      (member "document" frame |> field_string "content");
    let session_id = field_string "session_id" frame in
    let peers = member "peers" frame |> Yojson.Safe.Util.to_list in
    check bool "frame owns worker presence" true
      (List.exists (fun peer -> field_string "session_id" peer = session_id && field_string "actor" peer = "worker") peers);
    check bool "another active peer remains visible" true
      (List.exists (fun peer -> field_string "actor" peer = "other-worker") peers);
    Eio.Flow.copy_string (reset_frame stream_id) gateway.flow;
    (match Eio.Promise.await (H2_eio.Client.ping gateway.client) with
     | Ok () -> () | Error `EOF -> fail "connection closed after reset");
    let rec wait_for_departure () = match Live.observe observer with
      | None -> fail "observer unexpectedly closed"
      | Some (frame, pulse) ->
        let peers = member "peers" frame |> Yojson.Safe.Util.to_list in
        if List.exists (fun peer -> field_string "session_id" peer = session_id) peers
        then (Eio.Promise.await pulse; wait_for_departure ())
        else check bool "other peer survives reset" true
          (List.exists (fun peer -> field_string "actor" peer = "other-worker") peers) in
    wait_for_departure ();
    check bool "reset session no longer belongs to worker" true
      (Result.is_error (Live.find ~base_path ~actor:"worker" ~target ~session_id)));
  let revised = request H2 gateway ~token:worker ~meth:`POST
    ~body:(publication_body ~id ~revision:1 source) list in
  check_status "publish exact draft as next revision" 201 revised;
  let checkpoint = body ["target", target_json; "expected_sequence", `Int 0; "revision", `Int 2] in
  let saved = request H2 gateway ~token:worker ~meth:`POST ~body:checkpoint checkpoints in
  check_status "checkpoint real shared draft over H2" 200 saved;
  check string "checkpoint performed" "checkpointed" (field_string "checkpoint" (json saved));
  let saved_draft = member "document" (json saved) |> member "draft" in
  check int "checkpoint advances base" 2 (field_int "base_revision" saved_draft);
  check int "checkpoint advances sequence" 1 (field_int "sequence" saved_draft);
  check string "authenticated checkpoint actor" "worker" (field_string "updated_by" saved_draft);
  let replay = request H1 gateway ~token:worker ~meth:`POST ~body:checkpoint checkpoints in
  check_status "H1 sees same current checkpoint" 200 replay;
  check string "repeat is observation only" "already_current" (field_string "checkpoint" (json replay));
  check_json "H1 and H2 checkpoint document is identical" (member "document" (json saved)) (member "document" (json replay));
  let revised = request H2 gateway ~token:worker ~meth:`POST
    ~body:(publication_body ~id ~revision:2 source) list in
  check_status "another publication advances history" 201 revised;
  let stale = body ["target", target_json; "expected_sequence", `Int 0; "revision", `Int 3] in
  let stale = both gateway ~token:worker ~meth:`POST ~body:stale checkpoints in
  pair_status "both transports refuse stale checkpoint sequence" 409 stale;
  pair_code "same checkpoint conflict" "artifact_draft_sequence_conflict" stale;
  let h1, h2 = both gateway ~token:worker (drafts ^ "/" ^ id) in
  check_json "stale checkpoint kept the same draft" (json h1) (json h2);
  check int "stale checkpoint retained prior base" 2 (member "draft" (json h2) |> field_int "base_revision"))

type pending_stream =
  { stream_id : int
  ; headers : H2.Response.t Eio.Promise.t
  ; error : H2.Client_connection.error Eio.Promise.t
  }

let open_pending_stream gateway ~worker path =
  let stream_id = gateway.next_stream in
  gateway.next_stream <- stream_id + 2;
  let headers, put_headers = Eio.Promise.create () in
  let error, put_error = Eio.Promise.create () in
  let request = H2.Request.create ~scheme:"http" `GET path
    ~headers:(H2.Headers.of_list [":authority", "localhost:8935"; "authorization", "Bearer " ^ worker]) in
  let writer = H2_eio.Client.request gateway.client ~flush_headers_immediately:true request
    ~error_handler:(fun problem -> if not (Eio.Promise.is_resolved error) then Eio.Promise.resolve put_error problem)
    ~response_handler:(fun response reader ->
      Eio.Promise.resolve put_headers response;
      let rec read () = H2.Body.Reader.schedule_read reader ~on_eof:(fun () -> ())
        ~on_read:(fun _ ~off:_ ~len:_ -> read ()) in
      read ()) in
  H2.Body.Writer.flush writer (fun _ -> H2.Body.Writer.close writer);
  { stream_id; headers; error }

type capacity_mode = Overflow | Peer_reset
let test_sse_capacity mode () =
  let module Resources = Server_h2_response_resources in
  let capacity = match mode with Overflow -> 1 | Peer_reset -> 256 * 1024 in
  let resources = Resources.create ~max_pending_bytes:capacity in
  with_gateway ~runtime:true ~resources ~zero_window:(mode = Peer_reset)
    (fun ~base_path ~worker ~player:_ ~admin:_ gateway ->
      let source = String.make (32 * 1024) 's' in
      let created = request H1 gateway ~token:worker ~meth:`POST ~body:(publication_body source) list in
      check_status "setup publishes without using H2 response budget" 201 created;
      let id = member "artifact" (json created) |> field_string "id" in
      let opened = request H1 gateway ~token:worker ~meth:`POST
        ~body:(body ["action", `String "open"; "artifact_id", `String id; "revision", `Int 1]) drafts in
      check_status "setup opens draft without using H2 response budget" 200 opened;
      let target_json = member "draft" (json opened) |> member "target" in
      let target = match Draft.target_of_json target_json with Ok target -> target | Error message -> fail message in
      let observer = Live.join ~base_path ~actor:"other-worker" ~source:Live.Dashboard_connection ~target in
      Fun.protect ~finally:(fun () -> Live.leave observer) (fun () ->
        let path = "/api/v1/artifact-draft-events/" ^ id ^ "?generation=" ^ target.generation in
        let stream = open_pending_stream gateway ~worker path in
        let response = Eio.Promise.await stream.headers in
        check int "SSE headers committed before its payload" 200 (H2.Status.to_code response.status);
        let rec wait_for_actor present = match Live.observe observer with
          | None -> fail "observer unexpectedly closed"
          | Some (frame, pulse) ->
            let peers = member "peers" frame |> Yojson.Safe.Util.to_list in
            let worker_present = List.exists (fun peer -> field_string "actor" peer = "worker") peers in
            if worker_present <> present then (Eio.Promise.await pulse; wait_for_actor present)
            else check bool "other observer remains connected" true
              (List.exists (fun peer -> field_string "actor" peer = "other-worker") peers) in
        (match mode with
         | Overflow ->
           (match Eio.Promise.await stream.error with
            | `Protocol_error (code, _) ->
              check bool "capacity refusal resets only this stream" true (code = H2.Error_code.InternalError)
            | `Malformed_response _ | `Invalid_response_body_length _ | `Exn _ ->
              fail "capacity exhaustion must reset the stream");
           wait_for_actor false
         | Peer_reset ->
           wait_for_actor true;
           let rec await_reserved () =
             let pending = Resources.pending_bytes resources in
             if pending = 0 then (Eio.Fiber.yield (); await_reserved ())
             else (
               check bool "blocked response stays within its budget" true (pending <= capacity);
               check bool "blocked response accounts for at least the complete source" true
                 (pending >= String.length source)) in
           await_reserved ();
           Eio.Flow.copy_string (reset_frame stream.stream_id) gateway.flow;
           wait_for_actor false);
        (match Eio.Promise.await (H2_eio.Client.ping gateway.client) with
         | Ok () -> () | Error `EOF -> fail "capacity or reset killed the connection");
        let rec await_release () =
          if Resources.pending_bytes resources <> 0 then (Eio.Fiber.yield (); await_release ()) in
        await_release ();
        check int "stream cancellation releases all reserved response bytes" 0 (Resources.pending_bytes resources);
        (match mode with
         | Peer_reset -> ()
         | Overflow ->
           let limited = request H2 gateway ~token:worker (list ^ "/" ^ id) in
           check_status "oversized ordinary response is an explicit refusal" 503 limited;
           check string "capacity refusal is not a short successful document" "" limited.body;
           let unchanged = request H1 gateway ~token:worker (list ^ "/" ^ id) in
           check string "capacity refusal leaves the publication intact" source (field_string "content" (json unchanged));
           let uncertain = request H2 gateway ~token:worker ~meth:`POST
             ~body:(publication_body ~id ~revision:1 "committed before response capacity failed") list in
           check_status "response capacity may fail after publication commits" 503 uncertain;
           check string "post-commit 503 does not invent a receipt" "" uncertain.body;
           let recovered = request H1 gateway ~token:worker (list ^ "/" ^ id) in
           check_status "H1 can recover publication after H2 503" 200 recovered;
           check int "publication committed despite H2 503" 2 (member "artifact" (json recovered) |> field_int "revision");
           check string "readback recovers exact committed content" "committed before response capacity failed"
             (field_string "content" (json recovered)))))

(* This is intentionally not a Yjs implementation. It supports only seed
   and no-op merge, so the default test exercises transport, persistence and
   checkpoint admission without claiming real CRDT semantics. *)
let run_synthetic_transformer () =
  let input = Yojson.Safe.from_channel stdin in
  let kind = field_string "kind" input in
  let state, content = match kind with
    | "seed" ->
      let content = field_string "content" input in Base64.encode_string content, content
    | "merge" when member "updates" input = `List [] ->
      let state = field_string "state" input in
      (match Base64.decode state with
       | Ok content -> state, content
       | Error (`Msg message) -> fail message)
    | _ -> fail "synthetic transformer received an unsupported operation" in
  Yojson.Safe.to_channel stdout (`Assoc ["ok", `Bool true; "state", `String state; "content", `String content]);
  flush stdout

let with_synthetic_transformer run =
  let directory = Filename.temp_dir "h2-artifact-transformer-" "" |> Unix.realpath in
  let executable = Unix.realpath Sys.executable_name in
  let link = Filename.concat directory "masc-artifact-document" in
  Unix.symlink executable link;
  Fun.protect ~finally:(fun () -> Unix.unlink link; Unix.rmdir directory) (fun () ->
    let original_path = Option.value ~default:"" (Sys.getenv_opt "PATH") in
    Masc_test_deps.with_process_env "PATH" (Some (directory ^ ":" ^ original_path)) run)

let () = if Filename.basename Sys.argv.(0) = "masc-artifact-document" then run_synthetic_transformer () else (
  let runtime, argv =
    if Array.length Sys.argv = 3 && String.equal Sys.argv.(1) "--transformer-dir" then
      let directory = Sys.argv.(2) in
      let binary = Filename.concat directory "masc-artifact-document" in
      if not (Sys.file_exists binary) then failf "transformer not found: %s" binary;
      let original_path = Option.value ~default:"" (Sys.getenv_opt "PATH") in
      ["live checkpoint and SSE reset", `Quick, (fun () ->
        Masc_test_deps.with_process_env "PATH" (Some (directory ^ ":" ^ original_path)) test_live_checkpoint)],
      [|Sys.argv.(0)|]
    else [], Sys.argv in
  run ~argv "H2 artifact gateway"
    ["access and workspace", ["H1/H2 parity, publication, body admission", `Quick, test_access_and_preconditions];
     "synthetic transformer transport", ["checkpoint and SSE reset", `Quick,
       (fun () -> with_synthetic_transformer test_live_checkpoint);
       "SSE response capacity exhaustion resets the stream", `Quick,
       (fun () -> with_synthetic_transformer (test_sse_capacity Overflow));
       "peer reset releases a zero-window SSE response", `Quick,
       (fun () -> with_synthetic_transformer (test_sse_capacity Peer_reset))];
     "optional real transformer integration", runtime])
