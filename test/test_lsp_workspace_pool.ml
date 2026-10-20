open Alcotest

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fs_compat.realpath_lenient path
;;

let touch path =
  Fs_compat.mkdir_p (Filename.dirname path);
  let oc = open_out path in
  close_out oc
;;

let with_path path f =
  let prior = Sys.getenv_opt "PATH" in
  Unix.putenv "PATH" path;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some value -> Unix.putenv "PATH" value
      | None -> Unix.putenv "PATH" "")
    f
;;

(* --- where a language server gets rooted ------------------------------- *)

let test_root_is_the_clone_not_the_sandbox () =
  (* A Keeper's sandbox holds its clones under repos/<id>/. Rooting a language
     server at the sandbox root puts it one level above every project in it. *)
  let sandbox = temp_dir "masc-sandbox" in
  let clone = Filename.concat sandbox "repos/some-repo" in
  touch (Filename.concat clone "dune-project");
  let file = Filename.concat clone "lib/thing.ml" in
  touch file;
  match Lsp_project_root.resolve ~language:Lsp_process_manager.Ocaml ~file ~boundary:sandbox with
  | Lsp_project_root.Project_root root -> check string "rooted at the clone" clone root
  | Lsp_project_root.No_project_root _ -> fail "found no root"
  | Lsp_project_root.Outside_boundary _ -> fail "called the file outside the sandbox"
;;

let test_root_is_the_nearest_marker () =
  let sandbox = temp_dir "masc-sandbox" in
  touch (Filename.concat sandbox "dune-project");
  let inner = Filename.concat sandbox "vendor/dep" in
  touch (Filename.concat inner "dune-project");
  let file = Filename.concat inner "src/dep.ml" in
  touch file;
  match Lsp_project_root.resolve ~language:Lsp_process_manager.Ocaml ~file ~boundary:sandbox with
  | Lsp_project_root.Project_root root -> check string "nearest wins" inner root
  | Lsp_project_root.No_project_root _ -> fail "found no root"
  | Lsp_project_root.Outside_boundary _ -> fail "called the file outside the sandbox"
;;

let test_no_marker_is_not_the_boundary () =
  (* Answering the sandbox root here would start a server that indexes a
     directory of unrelated clones and answers every question badly. *)
  let sandbox = temp_dir "masc-sandbox" in
  let file = Filename.concat sandbox "loose/script.ml" in
  touch file;
  match Lsp_project_root.resolve ~language:Lsp_process_manager.Ocaml ~file ~boundary:sandbox with
  | Lsp_project_root.No_project_root { markers; _ } ->
    check bool "names the markers it looked for" true (List.mem "dune-project" markers)
  | Lsp_project_root.Project_root root -> failf "rooted at %s with no marker anywhere" root
  | Lsp_project_root.Outside_boundary _ -> fail "called the file outside the sandbox"
;;

let test_marker_above_the_boundary_is_not_reached () =
  let outer = temp_dir "masc-outer" in
  touch (Filename.concat outer "dune-project");
  let sandbox = Filename.concat outer "sandbox" in
  let file = Filename.concat sandbox "a.ml" in
  touch file;
  match Lsp_project_root.resolve ~language:Lsp_process_manager.Ocaml ~file ~boundary:sandbox with
  | Lsp_project_root.No_project_root _ -> ()
  | Lsp_project_root.Project_root root -> failf "walked past the boundary to %s" root
  | Lsp_project_root.Outside_boundary _ -> fail "called the file outside the sandbox"
;;

let test_file_outside_the_boundary_says_so () =
  let sandbox = temp_dir "masc-sandbox" in
  let elsewhere = temp_dir "masc-elsewhere" in
  let file = Filename.concat elsewhere "a.ml" in
  touch file;
  match Lsp_project_root.resolve ~language:Lsp_process_manager.Ocaml ~file ~boundary:sandbox with
  | Lsp_project_root.Outside_boundary { boundary; _ } ->
    check string "names the boundary" sandbox boundary
  | Lsp_project_root.Project_root root -> failf "answered %s for a file outside" root
  | Lsp_project_root.No_project_root _ -> fail "read it as a rootless file inside"
;;

let test_markers_cover_every_language () =
  (* The variant makes this exhaustive at compile time; the assertion is that
     no language was given an empty marker list to satisfy the compiler. A
     language rooted at the boundary says so with its own constructor. *)
  List.iter
    (fun language ->
      let lang_id = Lsp_process_manager.lang_id_of_language language in
      check
        bool
        (Printf.sprintf "%s has a root rule" lang_id)
        true
        (match Lsp_process_manager.root_rule_of_language language with
         | Lsp_process_manager.Marker_files markers -> markers <> []
         | Lsp_process_manager.Boundary_root -> true);
      check
        bool
        (Printf.sprintf "%s has a command" lang_id)
        true
        (fst (Lsp_process_manager.command_of_language language) <> ""))
    Lsp_process_manager.all_languages
;;

let test_a_boundary_rooted_language_is_rooted_at_the_boundary () =
  (* A YAML document has no project file. Its server sees the checkout. *)
  let sandbox = temp_dir "masc-sandbox" in
  let file = Filename.concat sandbox "deploy/config.yaml" in
  touch file;
  match Lsp_project_root.resolve ~language:Lsp_process_manager.Yaml ~file ~boundary:sandbox with
  | Lsp_project_root.Project_root root ->
    check string "the boundary itself" (Fs_compat.realpath_lenient sandbox) root
  | Lsp_project_root.No_project_root _ -> fail "asked for markers a YAML file has none of"
  | Lsp_project_root.Outside_boundary _ -> fail "called the file outside the sandbox"
;;

(* --- what the pool answers when there is no server --------------------- *)

let test_missing_command_is_not_an_empty_answer () =
  Eio_main.run (fun env ->
    Lsp_workspace_pool.with_pool
      ~clock:(Eio.Stdenv.clock env)
      ~proc_mgr:(Eio.Stdenv.process_mgr env)
      ~servers:Lsp_process_manager.command_of_language
      (fun pool ->
      let workspace_root = temp_dir "masc-ws" in
      with_path "" (fun () ->
        match
          Lsp_workspace_pool.ensure pool ~language:Lsp_process_manager.Ocaml ~workspace_root
        with
        | Error (Lsp_workspace_pool.Server_unavailable { lang_id; command }) ->
          check string "names the language" "ocaml" lang_id;
          check string "names the command a host would install" "ocamllsp" command
        | Error (Lsp_workspace_pool.Server_failed { reason; _ }) ->
          failf "collapsed a missing command into a failure: %s" reason
        | Ok _ -> fail "started a server with an empty PATH")))
;;

(* --- one server per workspace, against a real ocamllsp ------------------ *)

let ocamllsp_present () = Executable_path.path_has_executable "ocamllsp"

let ocaml_workspace prefix =
  let root = temp_dir prefix in
  touch (Filename.concat root "dune-project");
  root
;;

let test_two_roots_do_not_share_a_server () =
  Eio_main.run (fun env ->
    Lsp_workspace_pool.with_pool
      ~clock:(Eio.Stdenv.clock env)
      ~proc_mgr:(Eio.Stdenv.process_mgr env)
      ~servers:Lsp_process_manager.command_of_language
      (fun pool ->
      let ensure workspace_root =
        match
          Lsp_workspace_pool.ensure pool ~language:Lsp_process_manager.Ocaml ~workspace_root
        with
        | Ok proc -> proc
        | Error err -> failf "%a" Lsp_workspace_pool.pp_error err
      in
      let a = ocaml_workspace "masc-ws-a" in
      let b = ocaml_workspace "masc-ws-b" in
      let first = ensure a in
      let second = ensure b in
      let again = ensure a in
      (* Asserted on the records the pool hands back, not on a log line.
         [start_locked] is the only place a record is made and it always
         spawns, so two distinct records are two children — and Eio does not
         expose a pid to check that more directly. *)
      check
        bool
        "the same root is the same server"
        true
        (first == again);
      check
        bool
        "a different root is a different server"
        true
        (first != second)))
;;

let real_server_cases =
  if ocamllsp_present ()
  then
    [ test_case "two roots do not share a server" `Slow test_two_roots_do_not_share_a_server ]
  else (
    print_endline
      "[lsp_workspace_pool] ocamllsp is not on PATH - skipping the case that needs one";
    [])
;;

(* A controlled server, not a timer: proof/check answers only after didOpen
   and wrong-owner diagnostics have been sent. The test then explicitly
   releases the matching analysis observation. *)
let analysis_server = {py|
import json, signal, sys
signal.signal(signal.SIGUSR1, lambda *_: None)
active = None
last = None
checks = []
versions = []
closes = []
references = []
hold_references = False
held_references = []
reference_checks = []
def send(value):
    body = json.dumps(dict(jsonrpc='2.0', **value)).encode()
    sys.stdout.buffer.write(('Content-Length: %d\r\n\r\n' % len(body)).encode() + body)
    sys.stdout.buffer.flush()
def state():
    return dict(versions=versions, closes=closes, references=references)
def answer(ident):
    send(dict(id=ident, result=state()))
def diagnostics(uri, version):
    params = dict(uri=uri, diagnostics=[])
    if version is not None: params['version'] = version
    send(dict(method='textDocument/publishDiagnostics', params=params))
while True:
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line: sys.exit(0)
        if line == b'\r\n': break
        key, value = line.decode().split(':', 1)
        headers[key.lower()] = value.strip()
    msg = json.loads(sys.stdin.buffer.read(int(headers['content-length'])))
    method = msg.get('method')
    params = msg.get('params') or {}
    if method == 'initialize':
        send(dict(id=msg['id'], result=dict(capabilities={})))
    elif method == 'textDocument/didOpen':
        active = dict(params['textDocument'], analyzed=False)
        last = active
        versions.append(active['version'])
        diagnostics(active['uri'] + '/other.py', active['version'])
        diagnostics(active['uri'], active['version'] - 1)
        diagnostics(active['uri'], None)
        waiting = []
        for ident, opened in checks:
            if len(versions) >= opened: answer(ident)
            else: waiting.append((ident, opened))
        checks = waiting
    elif method == 'proof/check':
        opened = params.get('after_open', 0)
        if active is None or len(versions) < opened: checks.append((msg['id'], opened))
        else: answer(msg['id'])
    elif method == 'proof/state': answer(msg['id'])
    elif method == 'proof/payload': answer(msg['id'])
    elif method == 'proof/awaitReference':
        if references: answer(msg['id'])
        else: reference_checks.append(msg['id'])
    elif method == 'proof/holdReferences': hold_references = True
    elif method == 'proof/releaseReferences':
        for value in held_references: send(value)
        held_references.clear()
    elif method == 'proof/blockInput':
        answer(msg['id'])
        signal.pause()
    elif method == 'proof/analyzed':
        if active is not None: active['analyzed'] = True
        if last is not None: diagnostics(last['uri'], last['version'])
    elif method == 'proof/crash': sys.exit(0)
    elif method == 'textDocument/references':
        references.append(dict(version=active['version'], params=params))
        lines = [0, 1] if active['analyzed'] else [0]
        value = dict(id=msg['id'], result=[dict(uri=active['uri'], range=dict(
            start=dict(line=line, character=0), end=dict(line=line, character=1))) for line in lines])
        if hold_references: held_references.append(value)
        else: send(value)
        for ident in reference_checks: answer(ident)
        reference_checks.clear()
    elif method == 'textDocument/didClose':
        closes.append(active['version'])
        active = None
    elif method == 'shutdown': send(dict(id=msg['id'], result=None))
    elif method == 'exit': sys.exit(0)
|py}

let with_analysis_server f =
  let root=temp_dir "masc-lsp-analysis" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let script=Filename.concat root "server.py" in
    let path=Filename.concat root "phrase.py" in
    Out_channel.with_open_bin script (fun channel -> output_string channel analysis_server);
    Out_channel.with_open_bin path (fun channel -> output_string channel "phrase = 1\nprint(phrase)\n");
    Eio_main.run (fun env ->
      Lsp_workspace_pool.with_pool ~clock:(Eio.Stdenv.clock env)
        ~proc_mgr:(Eio.Stdenv.process_mgr env)
        ~servers:(fun _ -> "python3",["python3";script])
        (fun pool -> Eio.Switch.run (fun sw -> f sw pool root path))))
;;

let pool_result = function
  | Ok value -> value
  | Error error -> failf "%a" Lsp_workspace_pool.pp_error error
;;
let analysis_control ?(after_open=0) pool root method_ =
  Lsp_workspace_pool.ask pool ~language:Lsp_process_manager.Python
    ~workspace_root:root ~method_ ~params:(`Assoc ["after_open",`Int after_open]) |> pool_result
;;
let release_analysis pool root =
  Lsp_workspace_pool.notify pool ~language:Lsp_process_manager.Python
    ~workspace_root:root ~method_:"proof/analyzed" ~params:(`Assoc []) |> pool_result
;;
let reference_query pool root path =
  Lsp_questions.ask pool ~language:Lsp_process_manager.Python ~workspace_root:root
    ~path ~line:1 ~character:6 ~question:Lsp_questions.References
;;
let reference_answer promise = match Eio.Promise.await promise with
  | Ok (Ok (Lsp_questions.Locations locations)) -> locations
  | Ok (Ok (Hover_text _)) -> fail "expected references"
  | Ok (Error error) -> failf "%a" Lsp_questions.pp_error error
  | Error exn -> raise exn
;;
let count_field name state = Yojson.Safe.Util.(state |> member name |> to_list |> List.length)

let test_versioned_analysis_and_cancel () = with_analysis_server (fun sw pool root path ->
  let read expected_calls =
    let query=Eio.Fiber.fork_promise ~sw (fun () -> reference_query pool root path) in
    let state=analysis_control pool root "proof/check" in
    check int "wrong URI, previous version and unversioned diagnostics cannot start references"
      expected_calls (count_field "references" state);
    release_analysis pool root;
    let locations=reference_answer query in
    check (list int) "one prepared question returns both original locations" [0;1]
      (List.map (fun (location:Lsp_questions.location) -> location.line) locations)
  in
  read 0;
  let cancellation,resolve=Eio.Promise.create () in
  let cancelled=Eio.Fiber.fork_promise ~sw (fun () ->
    Eio.Cancel.sub (fun context ->
      Eio.Promise.resolve resolve context;
      reference_query pool root path)) in
  let context=Eio.Promise.await cancellation in
  let state=analysis_control pool root "proof/check" in
  check int "waiting analysis never sends an optimistic reference query" 1
    (count_field "references" state);
  Eio.Cancel.cancel context Exit;
  check bool "read cancellation propagates" true
    (match Eio.Promise.await cancelled with
     | Error (Eio.Cancel.Cancelled _) -> true
     | Error _ | Ok _ -> false);
  release_analysis pool root;
  read 1;
  let state=analysis_control pool root "proof/state" in
  check int "one query per successfully prepared read" 2 (count_field "references" state);
  check int "success and cancellation close every opened document" 3 (count_field "closes" state);
  let versions=Yojson.Safe.Util.(state |> member "versions" |> to_list |> List.map to_int) in
  check bool "fresh versions cannot borrow a cancelled or earlier analysis" true
    (match versions with [first;cancelled;last] -> first<cancelled && cancelled<last | _ -> false))
;;

let test_analysis_process_exit () = with_analysis_server (fun sw pool root path ->
  let query=Eio.Fiber.fork_promise ~sw (fun () -> reference_query pool root path) in
  ignore (analysis_control pool root "proof/check");
  Lsp_workspace_pool.notify pool ~language:Lsp_process_manager.Python ~workspace_root:root
    ~method_:"proof/crash" ~params:(`Assoc []) |> pool_result;
  check bool "an exited server cannot publish a partial references success" true
    (match Eio.Promise.await query with
     | Ok (Error (Lsp_questions.Server (Lsp_workspace_pool.Server_failed _))) -> true
     | Ok (Error _ | Ok _) | Error _ -> false))
;;

let test_concurrent_reference_documents () = with_analysis_server (fun sw pool root first_path ->
  let second_path=Filename.concat root "other.py" in
  Out_channel.with_open_bin second_path (fun channel -> output_string channel "phrase = 2\nprint(phrase)\n");
  let first=Eio.Fiber.fork_promise ~sw (fun () -> reference_query pool root first_path) in
  let second=Eio.Fiber.fork_promise ~sw (fun () -> reference_query pool root second_path) in
  let state=analysis_control ~after_open:1 pool root "proof/check" in
  check int "another document cannot replace the active prepared References read" 1
    (count_field "versions" state);
  check int "neither question runs before its analysis" 0 (count_field "references" state);
  release_analysis pool root;
  let state=analysis_control ~after_open:2 pool root "proof/check" in
  check int "first question settles before the second prepares" 1 (count_field "references" state);
  check int "first document is closed before the second opens" 1 (count_field "closes" state);
  release_analysis pool root;
  List.iter (fun (path,query) ->
    let locations=reference_answer query in
    check bool "each answer retains its own document identity" true
      (List.length locations=2 && List.for_all
        (fun (location:Lsp_questions.location) -> String.equal location.path path) locations))
    [first_path,first;second_path,second])
;;

let peer_document root =
  let peer=Filename.concat root "peer" in
  Unix.mkdir peer 0o700;
  let path=Filename.concat peer "phrase.py" in
  Out_channel.with_open_bin path (fun channel -> output_string channel "phrase = 2\nprint(phrase)\n");
  peer,path
;;
let control_notification pool root method_ =
  Lsp_workspace_pool.notify pool ~language:Lsp_process_manager.Python ~workspace_root:root
    ~method_ ~params:(`Assoc []) |> pool_result
;;
let test_other_process_exit_preserves_request () = with_analysis_server (fun sw pool root path ->
  let peer,peer_path=peer_document root in
  control_notification pool root "proof/holdReferences";
  let original=Eio.Fiber.fork_promise ~sw (fun () -> reference_query pool root path) in
  ignore (analysis_control pool root "proof/check");
  release_analysis pool root;
  ignore (analysis_control pool root "proof/awaitReference");
  let other=Eio.Fiber.fork_promise ~sw (fun () -> reference_query pool peer peer_path) in
  ignore (analysis_control pool peer "proof/check");
  control_notification pool peer "proof/crash";
  (match Eio.Promise.await other with
   | Ok (Error (Lsp_questions.Server (Lsp_workspace_pool.Server_failed _))) -> ()
   | Ok (Error _ | Ok _) | Error _ -> fail "peer exit must fail its own analysis read");
  ignore (analysis_control pool root "proof/state");
  control_notification pool root "proof/releaseReferences";
  let locations=reference_answer original in
  check int "another process EOF cannot reject this process's pending response" 2
    (List.length locations))
;;

let test_blocked_writer_does_not_hold_other_process () = with_analysis_server (fun sw pool root _path ->
  let peer,_peer_path=peer_document root in
  ignore (analysis_control pool peer "proof/blockInput");
  let cancellation,resolve=Eio.Promise.create () in
  let writing=Eio.Fiber.fork_promise ~sw (fun () ->
    Eio.Cancel.sub (fun context ->
      Eio.Promise.resolve resolve context;
      (* Larger than the native pipe buffer; the controlled peer has stopped
         reading. This is a resource fixture, not a product content limit. *)
      Lsp_workspace_pool.ask pool ~language:Lsp_process_manager.Python
        ~workspace_root:peer ~method_:"proof/payload"
        ~params:(`Assoc ["body",`String (String.make 1_048_576 'x')]))) in
  let context=Eio.Promise.await cancellation in
  Eio.Fiber.yield ();
  check bool "the controlled peer leaves the write pending" false (Eio.Promise.is_resolved writing);
  let queued=Eio.Fiber.fork_promise ~sw (fun () ->
    Lsp_workspace_pool.ask pool ~language:Lsp_process_manager.Python
      ~workspace_root:peer ~method_:"proof/queued" ~params:(`Assoc [])) in
  Eio.Fiber.yield ();
  ignore (analysis_control pool root "proof/state");
  Eio.Cancel.cancel context Exit;
  check bool "a partial-frame cancellation propagates" true
    (match Eio.Promise.await writing with
     | Error (Eio.Cancel.Cancelled _) -> true
     | Ok _ | Error _ -> false);
  check bool "queued writer sees an owned closed transport as a typed failure" true
    (match Eio.Promise.await queued with
     | Ok (Error (Lsp_workspace_pool.Server_failed _)) -> true
     | Ok (Ok _ | Error _) | Error _ -> false);
  ignore (analysis_control pool root "proof/state"))
;;

let test_cancel_queued_writer_preserves_active_frame () = with_analysis_server (fun sw pool root _path ->
  let proc=Lsp_workspace_pool.ensure pool ~language:Lsp_process_manager.Python
      ~workspace_root:root |> pool_result in
  ignore (analysis_control pool root "proof/blockInput");
  let active=Eio.Fiber.fork_promise ~sw (fun () ->
    Lsp_workspace_pool.ask pool ~language:Lsp_process_manager.Python ~workspace_root:root
      ~method_:"proof/payload" ~params:(`Assoc ["body",`String (String.make 1_048_576 'x')])) in
  Eio.Fiber.yield ();
  check bool "the active frame is still being written" false (Eio.Promise.is_resolved active);
  let cancellation,resolve=Eio.Promise.create () in
  let queued=Eio.Fiber.fork_promise ~sw (fun () -> Eio.Cancel.sub (fun context ->
    Eio.Promise.resolve resolve context;
    Lsp_workspace_pool.ask pool ~language:Lsp_process_manager.Python ~workspace_root:root
      ~method_:"proof/state" ~params:(`Assoc []))) in
  let context=Eio.Promise.await cancellation in
  Eio.Fiber.yield ();
  Eio.Cancel.cancel context Exit;
  (match Eio.Promise.await queued with
   | Error (Eio.Cancel.Cancelled _) -> ()
   | Ok _ | Error _ -> fail "queued write cancellation must propagate");
  Eio.Process.signal proc.proc Sys.sigusr1;
  check bool "cancelling an unstarted writer cannot retire the active frame owner" true
    (match Eio.Promise.await active with Ok (Ok _) -> true | Ok (Error _) | Error _ -> false))
;;

(* #36431: an answer whose last byte and the deadline land in the same
   scheduler pass. The mock clock queues the watcher's wake ahead of the
   work's on purpose -- set_time past the deadline, then resolve -- so an
   answer that had arrived must not be reported as a timeout. Exercises the
   await_answer deadline gate the pool's ensure/ask both call, without a live
   server. *)
let test_answer_that_arrived_as_window_closed_stands () =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run
  @@ fun sw ->
  let answer, arrive = Eio.Promise.create () in
  let work =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Lsp_workspace_pool.For_testing.await_answer
        ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t)
        ~timeout:1.0
        ~what:"initialize"
        answer)
  in
  Eio_mock.Clock.set_time clock 1.0;
  Eio.Promise.resolve arrive (Ok "capabilities");
  match Eio.Promise.await_exn work with
  | Ok "capabilities" -> ()
  | Ok other -> failf "unexpected answer %S" other
  | Error _ ->
    fail "an answer that arrived as the window closed was dropped as a timeout"
;;

(* The ordinary expiry: nothing answers, and the deadline ends the wait. *)
let test_answer_that_never_arrives_is_a_timeout () =
  Eio_mock.Backend.run
  @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock 0.0;
  Eio.Switch.run
  @@ fun sw ->
  let never : (string, string) result Eio.Promise.t = fst (Eio.Promise.create ()) in
  let work =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Lsp_workspace_pool.For_testing.await_answer
        ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t)
        ~timeout:1.0
        ~what:"initialize"
        never)
  in
  Eio_mock.Clock.set_time clock 1.0;
  match Eio.Promise.await_exn work with
  | Error _ -> ()
  | Ok _ -> fail "nothing answered, yet the wait did not end as a timeout"
;;

let () =
  run
    "lsp_workspace_pool"
    [ ( "project root"
      , [ test_case "the clone, not the sandbox" `Quick test_root_is_the_clone_not_the_sandbox
        ; test_case "the nearest marker" `Quick test_root_is_the_nearest_marker
        ; test_case "no marker is not the boundary" `Quick test_no_marker_is_not_the_boundary
        ; test_case
            "a marker above the boundary is out of reach"
            `Quick
            test_marker_above_the_boundary_is_not_reached
        ; test_case
            "a file outside the boundary says so"
            `Quick
            test_file_outside_the_boundary_says_so
        ; test_case "every language has both" `Quick test_markers_cover_every_language
        ; test_case
            "a boundary-rooted language is rooted at the boundary"
            `Quick
            test_a_boundary_rooted_language_is_rooted_at_the_boundary
        ] )
    ; ( "no server"
      , [ test_case
            "a missing command is typed"
            `Quick
            test_missing_command_is_not_an_empty_answer
        ] )
    ; "live server", real_server_cases
    ; ( "document analysis"
      , [ test_case "exact version, cancellation and fresh retry" `Quick test_versioned_analysis_and_cancel
        ; test_case "process exit fails the waiting read" `Quick test_analysis_process_exit
        ; test_case "concurrent References retain their document owners" `Quick test_concurrent_reference_documents
        ; test_case "peer EOF preserves another process request" `Quick test_other_process_exit_preserves_request
        ; test_case "a blocked writer does not hold another process" `Quick test_blocked_writer_does_not_hold_other_process
        ; test_case "queued cancellation preserves the active frame" `Quick test_cancel_queued_writer_preserves_active_frame
        ] )
    ; ( "initialize deadline"
      , [ test_case
            "an answer that arrived as the window closed stands"
            `Quick
            test_answer_that_arrived_as_window_closed_stands
        ; test_case
            "an answer that never arrives is a timeout"
            `Quick
            test_answer_that_never_arrives_is_a_timeout
        ] )
    ]
;;
