(* Phase 1 SSH remote execution lane, task 3: [Sandbox_target.Ssh] routes
   through the injected runner exactly like [Docker].  These cases mirror the
   Docker mock-runner cases in [test_exec_dispatch.ml].

   Note on the plan text: it asked for "the named error the Docker arm
   produces when no pipeline runner is injected".  No such error exists in
   [Exec_dispatch] -- a sandbox pipeline with [pipeline_runner = None]
   decomposes to per-stage [dispatch_simple] through the plain runner (the
   "pipeline-status" Docker case in [test_exec_dispatch.ml] pins that).  The
   pipeline case below pins that decomposed behavior for [Ssh] instead of a
   phantom error string. *)

let with_eio f =
  Eio_main.run @@ fun env ->
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  f ()

let has_infix ~affix s =
  let n = String.length affix in
  let rec scan i =
    if i + n > String.length s
    then false
    else if String.sub s i n = affix
    then true
    else scan (i + 1)
  in
  scan 0

let test_endpoint : Masc_exec.Sandbox_target.ssh_endpoint =
  { name = "builder-a"
  ; host = "builder-a.internal"
  ; user = "masc"
  ; port = 22
  ; identity_file = "/base/.masc/ssh/builder-a.key"
  ; known_hosts_file = "/base/.masc/ssh/known_hosts.d/builder-a"
  ; remote_root = "/srv/masc/playground/keeper-a"
  ; connect_timeout_sec = 10
  ; env_allowlist = [ "PATH" ]
  }

let simple_stage bin args ~sandbox =
  let open Masc_exec.Shell_ir in
  Simple
    { bin
    ; args = List.map (fun a -> Lit (a, default_meta)) args
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox
    }

(* --- dispatch_simple routes Ssh through the injected runner --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Exec_program.of_string "echo" |> Result.get_ok in
  let runner_calls = ref [] in
  let mock_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content ~argv ~env ~cwd =
    runner_calls := (argv, env, cwd, stdin_content) :: !runner_calls;
    (Unix.WEXITED 0, "out", "err")
  in
  let ssh_sandbox =
    Masc_exec.Sandbox_target.ssh ~endpoint:test_endpoint ~runner:mock_runner ()
  in
  let ir =
    { bin
    ; args = [ Lit ("hello", default_meta); Lit ("world", default_meta) ]
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = ssh_sandbox
    }
  in
  let result = Masc_exec.Exec_dispatch.dispatch_simple ~stdin_content:"typed" ir in
  (match !runner_calls with
   | [ (argv, env, cwd, stdin_content) ] ->
       assert (argv = [ "echo"; "hello"; "world" ]);
       assert (Array.length env = 0);
       assert (cwd = None);
       assert (stdin_content = Some "typed")
   | _ -> assert false);
  assert (result.status = Unix.WEXITED 0);
  assert (result.stdout = "out");
  assert (result.stderr = "err");
  (* The endpoint record rides along as data for keeper-side labeling. *)
  (match ssh_sandbox with
   | Masc_exec.Sandbox_target.Ssh { endpoint; _ } ->
       assert (endpoint.name = "builder-a");
       assert (endpoint.host = "builder-a.internal");
       assert (endpoint.port = 22)
   | Masc_exec.Sandbox_target.Host
   | Masc_exec.Sandbox_target.Docker _
   | Masc_exec.Sandbox_target.Micro_vm _
   | Masc_exec.Sandbox_target.Delegated _ ->
       assert false)

(* --- dispatch_simple refuses an untranslated redirect before spawning --- *)

(* Mirrors the Docker refusal in test_exec_dispatch_file_redirect.ml: an
   [In_command_namespace] target names a path on the remote host, and opening
   it here would touch whatever this host happens to have at that path, so
   dispatch refuses and the runner never runs. *)
let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Exec_program.of_string "echo" |> Result.get_ok in
  let runner_called = ref false in
  let remote_target =
    Masc_exec.Path_scope.classify ~raw:"/tmp/exec-dispatch-ssh-out" ~cwd:"/tmp"
  in
  let mock_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ =
    runner_called := true;
    Unix.WEXITED 0, "stdout", "stderr"
  in
  let ssh_sandbox =
    Masc_exec.Sandbox_target.ssh ~endpoint:test_endpoint ~runner:mock_runner ()
  in
  let ir =
    { bin
    ; args = []
    ; env = []
    ; cwd = None
    ; redirects =
        [ Masc_exec.Redirect_scope.File
            { fd = 1
            ; target = Masc_exec.Redirect_scope.In_command_namespace remote_target
            ; mode = Masc_exec.Redirect_scope.Write
            }
        ]
    ; sandbox = ssh_sandbox
    }
  in
  let result = Masc_exec.Exec_dispatch.dispatch_simple ir in
  assert (not !runner_called);
  assert (result.status = Unix.WEXITED 1);
  assert (result.stdout = "");
  assert (has_infix ~affix:"remote_ssh_redirect_unavailable" result.stderr)

(* --- pipeline with pipeline_runner = None decomposes per stage --- *)

let () =
  with_eio @@ fun () ->
  let printf_bin = Masc_exec.Exec_program.of_string "printf" |> Result.get_ok in
  let wc_bin = Masc_exec.Exec_program.of_string "wc" |> Result.get_ok in
  let runner_calls = ref [] in
  let mock_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content ~argv ~env:_ ~cwd:_ =
    runner_calls := (argv, stdin_content) :: !runner_calls;
    match argv, stdin_content with
    | [ "printf"; "typed" ], None -> Unix.WEXITED 0, "typed", ""
    | [ "wc"; "-c" ], Some "typed" -> Unix.WEXITED 0, "5\n", ""
    | _ -> Unix.WEXITED 2, "", "unexpected mock runner call"
  in
  let ssh_sandbox =
    Masc_exec.Sandbox_target.ssh ~endpoint:test_endpoint ~runner:mock_runner ()
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch_pipeline
      [ simple_stage printf_bin [ "typed" ] ~sandbox:ssh_sandbox
      ; simple_stage wc_bin [ "-c" ] ~sandbox:ssh_sandbox
      ]
  in
  assert (result.status = Unix.WEXITED 0);
  assert (String.trim result.stdout = "5");
  match List.rev !runner_calls with
  | [ ([ "printf"; "typed" ], None); ([ "wc"; "-c" ], Some "typed") ] -> ()
  | _ -> assert false

(* --- pipeline with pipeline_runner = Some prefers it (Docker parity) --- *)

let () =
  with_eio @@ fun () ->
  let printf_bin = Masc_exec.Exec_program.of_string "printf" |> Result.get_ok in
  let wc_bin = Masc_exec.Exec_program.of_string "wc" |> Result.get_ok in
  let simple_runner_called = ref false in
  let pipeline_runner_calls = ref [] in
  let simple_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ =
    simple_runner_called := true;
    Unix.WEXITED 3, "", "simple runner should not be used"
  in
  let pipeline_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stages =
    pipeline_runner_calls := stages :: !pipeline_runner_calls;
    Unix.WEXITED 0, "5\n", "pipeline-stderr"
  in
  let ssh_sandbox =
    Masc_exec.Sandbox_target.ssh
      ~endpoint:test_endpoint
      ~runner:simple_runner
      ~pipeline_runner
      ()
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch_pipeline
      [ simple_stage printf_bin [ "typed" ] ~sandbox:ssh_sandbox
      ; simple_stage wc_bin [ "-c" ] ~sandbox:ssh_sandbox
      ]
  in
  assert (not !simple_runner_called);
  assert (result.status = Unix.WEXITED 0);
  assert (String.trim result.stdout = "5");
  assert (result.stderr = "pipeline-stderr");
  match !pipeline_runner_calls with
  | [ [ first; second ] ] ->
      assert (first.Masc_exec.Sandbox_target.argv = [ "printf"; "typed" ]);
      assert (second.Masc_exec.Sandbox_target.argv = [ "wc"; "-c" ])
  | _ -> assert false

let () =
  Printf.printf "test_exec_dispatch_ssh: all tests passed.\n"
