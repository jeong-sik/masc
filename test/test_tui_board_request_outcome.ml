(** The actual TUI request owner, HTTP domain, authenticated registered routes
    and stores. The supplied admission callback exercises the public workspace
    authority check; the executable's extra identity probe is outside this suite. *)
open Alcotest

module Types = Masc_tui_types
module Publication = Masc_tui_board_publication
module Requests = Masc_tui_board_requests
module Results = Masc_tui_workspace_result
module Updates = Masc_tui_board_updates
module Client = Masc_tui_http
module Http = Masc.Http_server_eio

let () = Mirage_crypto_rng_unix.use_default ()
let () = Masc.Server_startup_state.mark_state_ready () |> Result.get_ok

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
    Unix.unlink path

let identity base_path : Masc.Tui_decode.server_identity =
  let canonical = Masc.Tui_decode.Canonical_path.of_path in
  { sid_version = "test"; sid_binary_commit = "test"; sid_binary_commit_age_s = None
  ; sid_base_path = canonical base_path; sid_masc_root = canonical (base_path ^ "/.masc")
  ; sid_executable_in_worktree = None; sid_state_ready = Some true
  ; sid_uptime = None; sid_sse_clients = None; sid_gc = None; sid_scheduler = None }

let noop : Masc.Board_metrics_hooks.observer =
  { observe_persist_lock_acquire_sec = (fun _ -> ())
  ; observe_persist_lock_held_sec = (fun _ -> ())
  ; inc_dispatch_flusher_start_outcome = (fun ~outcome:_ -> ()) }

let serve env ~sw ~router ~posts =
  let socket = Eio.Net.listen (Eio.Stdenv.net env) ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port | `Unix _ -> fail "expected a loopback TCP listener" in
  let authority = match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port with
    | Ok authority -> authority | Error `Malformed -> fail "invalid fixture authority" in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Server_bootstrap_http.serve ~sw ~clock:(Eio.Stdenv.clock env) ~socket
      ~addr_label:"Board publication test"
      ~request_handler:(fun _ (request : Httpun.Reqd.t Gluten.Reqd.t) ->
        let reqd = request.Gluten.Reqd.reqd in
        let request = Httpun.Reqd.request reqd in
        if request.meth = `POST && String.equal request.target "/api/v1/tools/masc_board_post"
        then incr posts;
        Server_request_authority.with_current authority (fun () ->
          Http.Router.dispatch router request reqd));
    `Stop_daemon);
  port

let with_fixture run =
  let base_path = Filename.temp_dir "tui-board-publication-" "" in
  let previous_server = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () ->
      Masc.Board_metrics_hooks.set_observer noop;
      Masc.Board_dispatch.reset_for_test ();
      Masc.Board.reset_global_for_test ();
      Server_auth.For_testing.restore_server_state previous_server;
      remove_tree base_path)
    (fun () ->
      Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some base_path)
      @@ fun () ->
      Masc_test_deps.with_process_env Masc_tui_credential.token_env_var None
      @@ fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run @@ fun sw ->
      Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
        ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw @@ fun () ->
      Masc_test_deps.Board_test_preparation.prepare ~base_path
        ~action:Masc_test_deps.Board_test_preparation.Bootstrap;
      let server = Masc.Mcp_server.For_testing.create_state ~base_path in
      let config = Masc.Mcp_server.workspace_config server in
      ignore (Masc.Workspace.init config ~agent_name:(Some "fixture"));
      Auth.save_auth_config base_path
        { Masc_domain.default_auth_config with enabled = true; require_token = true };
      Server_auth.For_testing.restore_server_state (Some server);
      Masc.Board.reset_global_for_test ();
      Masc.Board_dispatch.reset_for_test ();
      Result.get_ok (Masc.Board_dispatch.init_jsonl
        ~base_path:(Env_config_core.base_path ())
        ~recipient_lookup:Masc.Recipient_lookup.none_declared ());
      let router = Server_routes_http_routes_activity.add_routes ~sw
          ~clock:(Eio.Stdenv.clock env) (Http.Router.create ())
        |> Server_routes_http_routes_artifacts.add_routes in
      let posts = ref 0 in
      let port = serve env ~sw ~router ~posts in
      (match Client.install_operator_token ~base_path ~host:"127.0.0.1" ~port with
       | Masc_tui_credential.Held | Masc_tui_credential.Minted _ -> ()
       | Masc_tui_credential.Not_required | Masc_tui_credential.Workspace_pending
       | Masc_tui_credential.Mint_failed _ -> fail "temporary operator credential unavailable");
      Client.start_io_domain ~sw ~env;
      Masc_http_client.with_scoped_pool ~sw ~env @@ fun () ->
      (* A fixture hang detector, like test_tui_io_domain's existing deadline;
         it is not a product timeout or publication outcome classifier. *)
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
        run ~env ~sw ~base_path ~port ~posts))

let state base_path port =
  let state = Types.create_state ~workspace:"publication" ~local_base_path:base_path
      ~port ~refresh_interval:0. () in
  state.server_identity <- Some (identity base_path);
  state.workspace_identity <- Types.Workspace_identity_match;
  state.board_mode <- Types.Board_compose;
  Buffer.add_string state.board_draft "original draft";
  state

let staged path : Types.board_staged_attachment =
  { sa_path = path; sa_name = Filename.basename path; sa_kind = Types.Uk_file }

let start state results =
  Requests.start_board_post state ~host:"127.0.0.1" ~results
    ~admit:(fun request ->
      if Types.workspace_reply_admitted state ~authority:request.Publication.authority
          ~reading:None ~kind:Types.Workspace_operation_outcome
      then Ok () else Error "fixture workspace authority withdrawn")
    ~report:(fun _ _ -> ()) ~title:"published fixture" ~body:"original body" ()

let rec take_outcome results =
  match Results.take_ready results with
  | [] -> Eio.Fiber.yield (); take_outcome results
  | [{ Results.message = Masc_tui_async_protocol.Board_publication_done outcome; _ }] -> outcome
  | _ -> fail "expected one unscoped Board publication completion"

let with_results run =
  let results = Results.create () in
  Fun.protect ~finally:(fun () -> Results.close results) (fun () -> run results)

let returned = function
  | Publication.Returned { prepared; response } -> prepared, response
  | Publication.Not_attempted _ -> fail "expected an actual Board POST attempt"

let check_committed response =
  match Publication.committed_post_id response with
  | Some id -> Masc.Board.Post_id.to_string id
  | None -> fail "the actual publication response lost its committed post ID"

let rows () = Fs_compat.load_jsonl (Masc.Board.persist_path (Masc.Board.global ()))

let apply state outcome =
  Updates.apply_publication state ~report:(fun _ _ -> ()) ~refresh:(fun () -> ()) outcome

type proxy_mode = Forward_ack | Drop_ack | Hold_ack

let proxy env ~sw ~upstream_port ~mode =
  let socket = Eio.Net.listen (Eio.Stdenv.net env) ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port | `Unix _ -> fail "expected a TCP proxy" in
  let observed, observe = Eio.Promise.create () in
  let closed, close_observed = Eio.Promise.create () in
  let actual_body = ref None and actual_status = ref None and parsed_posts = ref 0 in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec accept_request () =
      let flow, _ = Eio.Net.accept ~sw socket in
      let input = Eio.Buf_read.of_flow ~max_size:65536 flow in
      match Eio.Buf_read.line input with
      | line -> flow, input, line
      | exception End_of_file -> Eio.Flow.close flow; accept_request () in
    let rec loop () =
      let flow, input, request_line = accept_request () in
      let target = match String.split_on_char ' ' request_line with
        | ["POST"; target; _] -> target | _ -> fail "proxy expected a real POST" in
      let rec headers acc = match Eio.Buf_read.line input with
        | "" -> List.rev acc
        | line ->
          let colon = String.index line ':' in
          headers ((String.sub line 0 colon,
                    String.trim (String.sub line (colon + 1) (String.length line - colon - 1))) :: acc) in
      let headers = headers [] in
      let length = headers |> List.find_map (fun (name, value) ->
        if String.equal (String.lowercase_ascii name) "content-length"
        then Some (int_of_string value) else None) |> Option.get in
      let body = Eio.Buf_read.take length input in
      let board_post = String.equal target "/api/v1/tools/masc_board_post" in
      if not board_post && not (String.equal target "/api/v1/artifacts") then
        fail "the proxy only forwards actual Board and artifact POSTs";
      if board_post then begin incr parsed_posts; actual_body := Some body end;
      let headers = List.filter (fun (name, _) ->
        not (List.mem (String.lowercase_ascii name) ["host"; "content-length"; "connection"])) headers in
      let url = Printf.sprintf "http://127.0.0.1:%d%s" upstream_port target in
      let status, response =
        match Masc_http_client.post_sync ~clock:(Eio.Stdenv.clock env) ~url ~headers ~body () with
        | Ok response -> response
        | Error _ -> fail "the actual upstream HTTP request did not complete" in
      if board_post then begin
        actual_status := Some status;
        ignore (Eio.Promise.try_resolve observe () : bool)
      end;
      (match mode, board_post with
       | Forward_ack, _ | (Drop_ack | Hold_ack), false ->
         Eio.Flow.copy_string
           (Printf.sprintf "HTTP/1.1 %d Fixture\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
              status (String.length response) response) flow;
         Eio.Flow.close flow
       | Drop_ack, true ->
         check int "the real upstream committed before acknowledgement was dropped" 201 status;
         Eio.Flow.close flow
       | Hold_ack, true ->
         check int "the real upstream committed before acknowledgement was held" 201 status;
         (try ignore (Eio.Buf_read.take_all input) with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | Eio.Io _ | Unix.Unix_error _ -> ());
         ignore (Eio.Promise.try_resolve close_observed () : bool));
      loop () in
    loop ());
  port, observed, closed, actual_body, actual_status, parsed_posts

let check_unanswered outcome =
  let prepared, response = returned outcome in
  (match response with
   | Publication.Unanswered _ -> ()
   | Publication.Answered _ -> fail "a lost acknowledgement must remain unanswered");
  check bool "missing acknowledgement has unknown effect" true
    (Publication.response_effect response = Failure_effect.Effect_outcome_unknown);
  prepared

let test_real_committed_error_keeps_payload_and_late_input () = with_fixture
  (fun ~env ~sw ~base_path ~port:upstream_port ~posts -> with_results @@ fun results ->
    let port, _, _, actual_body, actual_status, parsed_posts =
      proxy env ~sw ~upstream_port ~mode:Forward_ack in
    let state = state base_path port in
    let path = Filename.concat base_path "original.txt" in
    Fs_compat.save_file path "actual uploaded bytes";
    let sent = staged path in
    state.board_compose_attachments <- [sent];
    let observer_calls = ref 0 in
    Masc.Board_metrics_hooks.set_observer
      { noop with observe_persist_lock_held_sec = (fun _ ->
          incr observer_calls;
          if !observer_calls = 1 then failwith "held publication observer") };
    start state results;
    let outcome = take_outcome results in
    Masc.Board_metrics_hooks.set_observer noop;
    let prepared, response = returned outcome in
    check int "the actual held observer ran" 1 !observer_calls;
    check (option int) "the actual registered route returned HTTP400" (Some 400) !actual_status;
    check string "the original draft is retained with its request" "original draft"
      prepared.request.sent_draft;
    check bool "the request retains the original physical staged object" true
      (match prepared.request.staged with [held] -> held == sent | _ -> false);
    check bool "the observed error proves the original write committed" true
      (Publication.response_effect response = Failure_effect.Proven_post_effect);
    let committed_id = check_committed response in
    (match response with
     | Publication.Answered (Tool_result.Failed failure) ->
       check bool "canonical error retains its exact committed ID" true
         (Option.map Masc.Board.Post_id.to_string failure.committed_post_id = Some committed_id)
     | Publication.Answered (Tool_result.Completed _ | Tool_result.Deferred _)
     | Publication.Unanswered _ -> fail "expected the actual post-effect HTTP400 result");
    check (option string) "the retained body is the exact actual POST bytes"
      (Some prepared.body) !actual_body;
    check int "one real Board POST passed through the recording proxy" 1 !parsed_posts;
    let payload = Yojson.Safe.from_string prepared.body in
    let open Yojson.Safe.Util in
    check string "retained body contains the submitted post body" "original body"
      (payload |> member "body" |> to_string);
    let attachments = payload |> member "attachments" |> to_list in
    let digest = match attachments with
      | [attachment] -> attachment |> member "sha256" |> to_string
      | _ -> fail "the real upload must appear once in the prepared POST" in
    check (list string) "the retained digest names the actual stored artifact" [digest]
      (Tool_blob_store.list_all (Tool_blob_store.create ~base_path));
    (match Masc.Board_dispatch.get_post ~post_id:committed_id with
     | Ok post ->
       check string "the ID names the actual published body" "original body" post.body;
       check string "the actual route stamps the operator" Client.default_agent_name
         (Masc.Board.Agent_id.to_string post.author)
     | Error _ -> fail "the committed receipt did not identify a real stored post");
    Buffer.clear state.board_draft;
    Buffer.add_string state.board_draft "later draft";
    let late_path = Filename.concat base_path "later.txt" in
    Fs_compat.save_file late_path "later staged bytes";
    let late = staged late_path in
    state.board_compose_attachments <- [sent; late];
    apply state outcome;
    check string "a late draft survives a real committed error" "later draft"
      (Buffer.contents state.board_draft);
    check bool "only the physically late staged file survives" true
      (match state.board_compose_attachments with [kept] -> kept == late | _ -> false);
    check int "there was one real Board POST" 1 !posts;
    check int "the real WAL contains one post" 1 (List.length (rows ()));
    check bool "the completion is retained once" true (Results.take_ready results = []))

let test_lost_ack_keeps_exact_request_without_duplicate_post () = with_fixture
  (fun ~env ~sw ~base_path ~port:upstream_port ~posts -> with_results @@ fun results ->
    let port, observed, _, actual_body, _, parsed_posts =
      proxy env ~sw ~upstream_port ~mode:Drop_ack in
    let state = state base_path port in
    start state results;
    Eio.Promise.await observed;
    let outcome = take_outcome results in
    let prepared = check_unanswered outcome in
    check (option string) "the retained prepared bytes are the actual forwarded POST"
      (Some prepared.body) !actual_body;
    apply state outcome;
    apply state outcome;
    check string "unknown publication keeps the original draft" "original draft"
      (Buffer.contents state.board_draft);
    check int "the transport parsed exactly one Board POST" 1 !parsed_posts;
    check int "the actual upstream route received exactly one Board POST" 1 !posts;
    check int "lost acknowledgement did not duplicate the real post" 1 (List.length (rows ())))

let test_attachment_failure_never_posts_to_board () = with_fixture
  (fun ~env:_ ~sw:_ ~base_path ~port ~posts -> with_results @@ fun results ->
    let state = state base_path port in
    let missing = staged (Filename.concat base_path "not-created.txt") in
    state.board_compose_attachments <- [missing];
    start state results;
    let outcome = take_outcome results in
    (match outcome with
     | Publication.Not_attempted _ -> ()
     | Publication.Returned _ -> fail "an unreadable attachment must stop before Board POST");
    apply state outcome;
    check int "no Board POST reached the real router" 0 !posts;
    check int "no actual post was created" 0 (List.length (Masc.Board_dispatch.list_posts ()));
    check bool "the exact original staged object stays" true
      (match state.board_compose_attachments with [kept] -> kept == missing | _ -> false);
    check string "the unsent draft stays" "original draft" (Buffer.contents state.board_draft))

let test_cancellation_retains_unknown_after_real_upstream_commit () = with_fixture
  (fun ~env ~sw ~base_path ~port:upstream_port ~posts -> with_results @@ fun results ->
    let port, observed, closed, actual_body, _, parsed_posts =
      proxy env ~sw ~upstream_port ~mode:Hold_ack in
    let state = state base_path port in
    let exception Stop_board_request in
    let propagated =
      try
        Eio.Cancel.sub (fun context -> Eio.Switch.run (fun request_sw ->
          Eio_context.with_turn_switch request_sw (fun () ->
            start state results;
            Eio.Promise.await observed;
            Eio.Cancel.cancel context Stop_board_request;
            Eio.Fiber.await_cancel ())))
      with Eio.Cancel.Cancelled Stop_board_request -> true in
    check bool "the original cancellation propagates" true propagated;
    let outcome = take_outcome results in
    let prepared = check_unanswered outcome in
    check (option string) "cancelled publication retains the original POST bytes"
      (Some prepared.body) !actual_body;
    Eio.Promise.await closed;
    (* Peer EOF is separate from receipt publication. The existing I/O-domain
       suite additionally checks actual pool-borrower release and reuse. *)
    apply state outcome;
    check int "cancellation caused no automatic duplicate POST" 1 !parsed_posts;
    check int "the real registered route committed once" 1 !posts;
    check int "the actual committed row remains" 1 (List.length (rows ()));
    check bool "only one terminal completion was published" true (Results.take_ready results = []))

let capture_for (state : Types.state) =
  Publication.capture ~authority:state.Types.workspace_authority ~host:"127.0.0.1"
    ~port:state.port ~expected_workspace:state.server_identity
    ~sent_draft:(Buffer.contents state.board_draft) ~staged:state.board_compose_attachments
    ~title:"published fixture" ~body:"original body" ~hearth:None ()

let test_old_outcome_archives_without_settling_successor () = with_fixture
  (fun ~env:_ ~sw:_ ~base_path ~port ~posts:_ -> with_results @@ fun results ->
    let state = state base_path port in
    start state results;
    let outcome = take_outcome results in
    let original = Publication.outcome_request outcome in
    let _, response = returned outcome in
    let original_id = check_committed response in
    let successor = capture_for state in
    check bool "equal inputs do not share request identity" false
      (Publication.same_request original successor);
    state.board_publications <- Publication.register state.board_publications successor;
    state.board_write <- Types.Board_posting successor;
    let reports = ref 0 and refreshes = ref 0 in
    let apply outcome = Updates.apply_publication state
        ~report:(fun _ _ -> incr reports) ~refresh:(fun () -> incr refreshes) outcome in
    apply outcome;
    check bool "the old receipt cannot release the exact successor request" true
      (match state.board_write with
       | Types.Board_posting held -> Publication.same_request held successor
       | Types.Board_idle | Types.Board_commenting -> false);
    check string "the successor draft remains" "original draft" (Buffer.contents state.board_draft);
    check int "old-request delivery emits no current report" 0 !reports;
    check int "old-request delivery initiates no current refresh" 0 !refreshes;
    (match Publication.entries state.board_publications with
     | [Publication.Finished archived; Publication.Pending pending] ->
       check bool "the original terminal outcome was archived" true
         (Publication.same_request original (Publication.outcome_request archived));
       check bool "the successor remains pending" true (Publication.same_request successor pending)
     | _ -> fail "expected original archive and the pending successor");
    apply (Publication.not_attempted original ~detail:"conflicting duplicate delivery");
    (match Publication.entries state.board_publications with
     | Publication.Finished archived :: _ ->
       let _, response = returned archived in
       check string "the first actual committed result survives a duplicate" original_id
         (check_committed response)
     | _ -> fail "duplicate delivery lost the original archive");
    let foreign = capture_for state in
    apply (Publication.not_attempted foreign ~detail:"unregistered foreign delivery");
    (match Publication.entries state.board_publications with
     | [Publication.Finished _; Publication.Pending pending] ->
       check bool "foreign delivery neither registers nor settles the successor" true
         (Publication.same_request pending successor)
     | _ -> fail "foreign delivery changed registered history"))

let test_workspace_return_cannot_revive_original_request_authority () = with_fixture
  (fun ~env:_ ~sw:_ ~base_path ~port ~posts:_ -> with_results @@ fun results ->
    let state = state base_path port in
    start state results;
    let outcome = take_outcome results in
    let original = Publication.outcome_request outcome in
    let Types.Workspace_authority generation = state.workspace_authority in
    (* Exercise the public update component's authority gate with an old exact
       posting slot retained. Executable workspace switching also retires its
       own UI state; that private orchestration is not copied into this test. *)
    state.workspace_authority <- Types.Workspace_authority (generation + 1);
    state.server_identity <- Some (identity (base_path ^ "/workspace-b"));
    state.workspace_authority <- Types.Workspace_authority (generation + 2);
    state.server_identity <- Some (identity base_path);
    state.workspace_identity <- Types.Workspace_identity_match;
    let refreshes = ref 0 in
    Updates.apply_publication state ~report:(fun _ _ -> ())
      ~refresh:(fun () -> incr refreshes) outcome;
    check string "returning to A does not clear the current draft" "original draft"
      (Buffer.contents state.board_draft);
    check bool "old authority cannot settle even the same old request slot" true
      (match state.board_write with
       | Types.Board_posting held -> Publication.same_request held original
       | Types.Board_idle | Types.Board_commenting -> false);
    check int "the old workspace result grants no refresh authority" 0 !refreshes;
    (match Publication.entries state.board_publications with
     | [Publication.Finished archived] ->
       check bool "withdrawn original result remains archived" true
         (Publication.same_request original (Publication.outcome_request archived))
     | _ -> fail "workspace withdrawal lost the original terminal result"))

let () = run "TUI Board request outcomes" ["actual request and registered routes", [
  test_case "committed HTTP400 preserves payload and late input" `Quick
    test_real_committed_error_keeps_payload_and_late_input;
  test_case "lost acknowledgement retains exact request without duplicate POST" `Quick
    test_lost_ack_keeps_exact_request_without_duplicate_post;
  test_case "attachment failure stops before Board POST" `Quick
    test_attachment_failure_never_posts_to_board;
  test_case "cancellation retains unknown after real upstream commit" `Quick
    test_cancellation_retains_unknown_after_real_upstream_commit;
  test_case "old outcomes archive without settling a successor" `Quick
    test_old_outcome_archives_without_settling_successor;
  test_case "returning to workspace A cannot revive old request authority" `Quick
    test_workspace_return_cannot_revive_original_request_authority
]]
