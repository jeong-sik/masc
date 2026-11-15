(* A workspace read of the TUI against a loopback server that answers the
   way the server's request entry does (#43356): the entry's own decision
   ([Server_workspace_precondition.check_request]) and refusal body, in place
   of its router. What is checked is what the TUI sent: the precondition
   headers on the read, and whether [/health] went out before or after it. *)

module Http = Masc_tui_http
module Scope = Masc_tui_workspace_precondition
module Precondition = Masc.Request_workspace_precondition
module Decode = Masc.Tui_decode

let host = "127.0.0.1"
let read_path = "/api/v1/workspace-read"

let identity base_path : Decode.server_identity =
  { sid_version = "test"
  ; sid_binary_commit = "test"
  ; sid_binary_commit_age_s = None; sid_runtime_instance_id = None
  ; sid_base_path = Decode.Canonical_path.of_path base_path
  ; sid_masc_root = Decode.Canonical_path.of_path (base_path ^ "/.masc")
  ; sid_executable_in_worktree = None
  ; sid_state_ready = Some true
  ; sid_uptime = None
  ; sid_sse_clients = None
  ; sid_gc = None
  ; sid_scheduler = None; sid_operator_action = None
  }

let confirmed = identity "/owned-workspace"

(* One request the server received: its path and both precondition headers. *)
type received = { path : string; base_path : string option; masc_root : string option }

let respond ~status body reqd =
  let headers = Httpun.Headers.of_list
      [ "content-type", "application/json"
      ; "content-length", string_of_int (String.length body) ] in
  Httpun.Reqd.respond_with_string reqd (Httpun.Response.create ~headers status) body

let health_body ~(served : Precondition.workspace) ~ready =
  Yojson.Safe.to_string (`Assoc
    [ "version", `String "test"
    ; "paths", `Assoc [ "effective_base_path", `String served.base_path
                      ; "effective_masc_root", `String served.masc_root ]
    ; "startup", `Assoc [ "state_ready", `Bool ready ] ])

let with_server env ~(served : Precondition.workspace) ~ready body =
  let received = ref [] in
  let handler reqd =
    let request = Httpun.Reqd.request reqd in
    let path = Uri.path (Uri.of_string request.Httpun.Request.target) in
    let header name = Httpun.Headers.get request.headers name in
    received := !received @ [ { path
                              ; base_path = header Precondition.expected_base_path_header
                              ; masc_root = header Precondition.expected_masc_root_header } ];
    if String.equal path "/health" then respond ~status:`OK (health_body ~served ~ready) reqd
    else match Server_workspace_precondition.check_request ~served:(fun () -> Some served)
        ~ready ~path request with
    | Precondition.Refused refusal ->
      respond ~status:(Server_workspace_precondition.refusal_status refusal)
        (Yojson.Safe.to_string (Server_workspace_precondition.refusal_body refusal)) reqd
    | Precondition.No_precondition | Precondition.Precondition_met ->
      respond ~status:`OK {|{"ok":true}|} reqd
  in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run (fun sw ->
    let socket = Eio.Net.listen ~reuse_addr:true ~backlog:8 ~sw (Eio.Stdenv.net env)
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
    let port = match Eio.Net.listening_addr socket with
      | `Tcp (_, port) -> port
      | `Unix _ -> Alcotest.fail "the test listens on TCP" in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Server_bootstrap_http.serve ~sw ~clock ~socket ~addr_label:"workspace precondition test"
        ~request_handler:(fun _addr (gluten_reqd : Httpun.Reqd.t Gluten.Reqd.t) ->
          handler gluten_reqd.Gluten.Reqd.reqd);
      `Stop_daemon);
    Eio.Switch.run (fun pool_sw ->
      Masc_http_client.with_scoped_pool ~sw:pool_sw ~env (fun () ->
        Eio.Switch.run (fun sw ->
          Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock
            ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw (fun () ->
              Http.start_io_domain ~sw ~env;
              body ~port;
              !received)))))

type answer = Read of (Yojson.Safe.t, string) result | Withdrawn

(* What [Masc_tui.launch_workspace_request] runs once the workspace is
   confirmed: the read in a scope, and one [/health] read after a workspace
   refusal. *)
let confirmed_read ~port ~refused =
  Scope.run ~host ~port ~expected:confirmed
    ~on_workspace_refused:(fun refusal ->
      refused := !refused @ [ refusal ];
      ignore (Masc_tui_loader.load_server_identity ~host ~port))
    ~withdrawn:(fun () -> Withdrawn)
    (fun () -> Read (Http.get_json ~host ~port ~path:read_path))

let carried = { path = read_path
              ; base_path = Some "/owned-workspace"
              ; masc_root = Some "/owned-workspace/.masc" }
let health = { path = "/health"; base_path = None; masc_root = None }

let check_received = Alcotest.(check (list (triple string (option string) (option string))))
let triples = List.map (fun r -> r.path, r.base_path, r.masc_root)

let refusal_name = function
  | Precondition.Invalid_precondition _ -> "invalid"
  | Precondition.Workspace_mismatch -> "mismatch"
  | Precondition.Server_booting -> "booting"

let test_confirmed_read_sends_one_request env =
  let refused = ref [] in
  let answer = ref Withdrawn in
  let received = with_server env
      ~served:{ base_path = "/owned-workspace"; masc_root = "/owned-workspace/.masc" } ~ready:true
      (fun ~port ->
         answer := confirmed_read ~port ~refused;
         Alcotest.(check bool) "outside the scope nothing is expected" false (Scope.expects confirmed);
         Scope.run ~host ~port ~expected:confirmed ~on_workspace_refused:(fun _ -> ())
           ~withdrawn:(fun () -> ()) (fun () ->
             Alcotest.(check bool) "the scope expects its workspace" true (Scope.expects confirmed);
             Alcotest.(check bool) "the scope does not expect another" false
               (Scope.expects (identity "/other-workspace")))) in
  (match !answer with
   | Read (Ok _) -> ()
   | Read (Error detail) -> Alcotest.fail detail
   | Withdrawn -> Alcotest.fail "an admitted read was withdrawn");
  check_received "the read alone, carrying the confirmed paths" (triples [ carried ]) (triples received);
  Alcotest.(check (list string)) "no refusal" [] (List.map refusal_name !refused)

let refused_read env ~served ~ready ~expected_refusal =
  let refused = ref [] in
  let answer = ref (Read (Error "not run")) in
  let received = with_server env ~served ~ready (fun ~port ->
    answer := confirmed_read ~port ~refused) in
  (match !answer with
   | Withdrawn -> ()
   | Read _ -> Alcotest.fail "a refused read kept its own answer");
  Alcotest.(check (list string)) "one workspace refusal" [ expected_refusal ]
    (List.map refusal_name !refused);
  check_received "the refused read, then one /health" (triples [ carried; health ]) (triples received)

let test_mismatch_reads_health_once env =
  refused_read env ~served:{ base_path = "/other-workspace"; masc_root = "/other-workspace/.masc" }
    ~ready:true ~expected_refusal:"mismatch"

let test_booting_reads_health_once env =
  refused_read env ~served:{ base_path = "/owned-workspace"; masc_root = "/owned-workspace/.masc" }
    ~ready:false ~expected_refusal:"booting"

let () =
  Eio_main.run (fun env ->
    Alcotest.run "tui_workspace_precondition"
      [ ( "workspace read"
        , [ Alcotest.test_case "a confirmed read goes out once with the precondition" `Quick
              (fun () -> test_confirmed_read_sends_one_request env)
          ; Alcotest.test_case "409 reads /health once and withdraws the read" `Quick
              (fun () -> test_mismatch_reads_health_once env)
          ; Alcotest.test_case "503 reads /health once and withdraws the read" `Quick
              (fun () -> test_booting_reads_health_once env) ] ) ])
