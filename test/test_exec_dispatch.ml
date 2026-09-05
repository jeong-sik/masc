let with_eio f =
  Eio_main.run @@ fun env ->
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  f ()

(* --- resolve_arg --- *)

let () =
  let open Masc_exec.Shell_ir in
  let test_resolve_lit =
    let result = Masc_exec.Exec_dispatch.(resolve_arg (Lit ("hello", default_meta))) in
    assert (result = "hello")
  in
  test_resolve_lit

let () =
  let open Masc_exec.Shell_ir in
  Unix.putenv "MASC_TEST_P7_VAR" "world";
  let result = Masc_exec.Exec_dispatch.(resolve_arg (Var ("MASC_TEST_P7_VAR", default_meta))) in
  assert (result = "world")

let () =
  let open Masc_exec.Shell_ir in
  let result =
    Masc_exec.Exec_dispatch.(resolve_arg (Var ("__MASC_NONEXISTENT_P7__", default_meta)))
  in
  assert (result = "")

let () =
  let open Masc_exec.Shell_ir in
  Unix.putenv "MASC_TEST_P7_VAR" "world";
  let result =
    Masc_exec.Exec_dispatch.(
      resolve_arg
        (Concat
           [ Lit ("prefix-", default_meta)
           ; Var ("MASC_TEST_P7_VAR", default_meta)
           ; Lit ("-suffix", default_meta)
           ]))
  in
  assert (result = "prefix-world-suffix");
  Unix.putenv "MASC_TEST_P7_VAR" ""

(* --- dispatch_simple with real process --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Exec_program.of_string "echo" |> Result.get_ok in
  let ir =
      { bin
      ; args = [ Lit ("hello", default_meta); Lit ("world", default_meta) ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Masc_exec.Sandbox_target.host ()
      }
  in
  let result = Masc_exec.Exec_dispatch.dispatch_simple ir in
  let stdout = String.trim result.stdout in
  assert (stdout = "hello world");
  assert (result.status = Unix.WEXITED 0)

let () =
  let executable = Filename.temp_file "masc-exact-argv0-" ".sh" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists executable then Unix.unlink executable)
    (fun () ->
       let output = open_out executable in
       Fun.protect
         ~finally:(fun () -> close_out_noerr output)
         (fun () -> output_string output "#!/bin/sh\nprintf '%s' exact-argv0\n");
       Unix.chmod executable 0o700;
       with_eio @@ fun () ->
       let open Masc_exec.Shell_ir in
       let bin = Masc_exec.Exec_program.of_string executable |> Result.get_ok in
       let ir =
         { bin
         ; args = []
         ; env = []
         ; cwd = None
         ; redirects = []
         ; sandbox = Masc_exec.Sandbox_target.host ()
         }
       in
       let result = Masc_exec.Exec_dispatch.dispatch_simple ir in
       assert (result.status = Unix.WEXITED 0);
       assert (String.equal result.stdout "exact-argv0"))

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Exec_program.of_string "sh" |> Result.get_ok in
  let ir =
      { bin
      ; args = [ Lit ("-c", default_meta); Lit ("printf %s \"$MASC_TEST_BASE_HOST_ENV\"", default_meta) ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Masc_exec.Sandbox_target.host ()
      }
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch_simple
      ~base_host_env:[| "PATH=/bin:/usr/bin"; "MASC_TEST_BASE_HOST_ENV=from-base" |]
      ir
  in
  assert (result.stdout = "from-base");
  assert (result.status = Unix.WEXITED 0)

(* --- dispatch_simple captures stderr --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Exec_program.of_string "cat" |> Result.get_ok in
  let ir =
      { bin
      ; args = [ Lit ("/nonexistent_file_p7_test", default_meta) ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Masc_exec.Sandbox_target.host ()
      }
  in
  let result = Masc_exec.Exec_dispatch.dispatch_simple ir in
  assert (result.status <> Unix.WEXITED 0);
  assert (String.length result.stderr > 0)

(* --- dispatch pipeline --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let echo_bin = Masc_exec.Exec_program.of_string "echo" |> Result.get_ok in
  let tr_bin = Masc_exec.Exec_program.of_string "tr" |> Result.get_ok in
  let host_sandbox = Masc_exec.Sandbox_target.host () in
  let stages = [
    Simple { bin = echo_bin; args = [Lit ("hello world", default_meta)]; env = []; cwd = None; redirects = []; sandbox = host_sandbox };
    Simple { bin = tr_bin; args = [Lit ("a-z", default_meta); Lit ("A-Z", default_meta)]; env = []; cwd = None; redirects = []; sandbox = host_sandbox };
  ] in
  let result = Masc_exec.Exec_dispatch.dispatch_pipeline stages in
  let stdout = String.trim result.stdout in
  assert (stdout = "HELLO WORLD");
  assert (result.status = Unix.WEXITED 0)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let sh_bin = Masc_exec.Exec_program.of_string "sh" |> Result.get_ok in
  let cat_bin = Masc_exec.Exec_program.of_string "cat" |> Result.get_ok in
  let host_sandbox = Masc_exec.Sandbox_target.host () in
  let stages =
    [
      Simple
        { bin = sh_bin
        ; args =
            [ Lit ("-c", default_meta)
            ; Lit ("printf %s \"$MASC_TEST_PIPE_BASE_HOST_ENV\"", default_meta)
            ]
        ; env = []
        ; cwd = None
        ; redirects = []
        ; sandbox = host_sandbox
        };
      Simple
        { bin = cat_bin
        ; args = []
        ; env = []
        ; cwd = None
        ; redirects = []
        ; sandbox = host_sandbox
        };
    ]
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch_pipeline
      ~base_host_env:
        [| "PATH=/bin:/usr/bin"; "MASC_TEST_PIPE_BASE_HOST_ENV=from-pipeline-base" |]
      stages
  in
  assert (result.stdout = "from-pipeline-base");
  assert (result.status = Unix.WEXITED 0)

(* --- host pipeline streams between stages --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let yes_bin = Masc_exec.Exec_program.of_string "yes" |> Result.get_ok in
  let head_bin = Masc_exec.Exec_program.of_string "head" |> Result.get_ok in
  let host_sandbox = Masc_exec.Sandbox_target.host () in
  let stages =
    [
      Simple { bin = yes_bin; args = []; env = []; cwd = None; redirects = []; sandbox = host_sandbox };
      Simple { bin = head_bin; args = [Lit ("-n", default_meta); Lit ("1", default_meta)]; env = []; cwd = None; redirects = []; sandbox = host_sandbox };
    ]
  in
  let result = Masc_exec.Exec_dispatch.dispatch_pipeline stages in
  assert (String.trim result.stdout = "y");
  assert (result.status <> Process_eio.timed_out_status)

(* --- dispatch forwards pipeline captured output chunks --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let sh_bin = Masc_exec.Exec_program.of_string "sh" |> Result.get_ok in
  let cat_bin = Masc_exec.Exec_program.of_string "cat" |> Result.get_ok in
  let host_sandbox = Masc_exec.Sandbox_target.host () in
  let sh_stage =
    Simple
      {
        bin = sh_bin;
        args =
          [
            Lit ("-c", default_meta);
            Lit ("printf out; printf err >&2", default_meta);
          ];
        env = [];
        cwd = None;
        redirects = [];
        sandbox = host_sandbox;
      }
  in
  let cat_stage =
    Simple
      {
        bin = cat_bin;
        args = [];
        env = [];
        cwd = None;
        redirects = [];
        sandbox = host_sandbox;
      }
  in
  let chunks = ref [] in
  let result =
    Masc_exec.Exec_dispatch.dispatch
      ~on_output_chunk:(fun chunk -> chunks := chunk :: !chunks)
      (Pipeline [ sh_stage; cat_stage ])
  in
  assert (result.status = Unix.WEXITED 0);
  assert (result.stdout = "out");
  assert (result.stderr = "err");
  assert (List.mem (`Stdout "out") !chunks);
  assert (List.mem (`Stderr "err") !chunks)

(* --- decomposed pipeline: streamed final-stage timeout must not re-emit ---

   Regression for the dangling-else in the decomposed-chain timeout branch:
   the [else] bound to [if not is_final] instead of [if stage_streamed], so a
   streamed final stage that timed out (exit 124) re-emitted its already
   streamed stdout through [emit_pipeline_stage_result ~emit_stdout:true].
   Stage 1 carries a redirect to force the decomposed path. *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let sh_bin = Masc_exec.Exec_program.of_string "sh" |> Result.get_ok in
  let host_sandbox = Masc_exec.Sandbox_target.host () in
  let upstream_stage =
    Simple
      {
        bin = sh_bin;
        args =
          [ Lit ("-c", default_meta); Lit ("printf upstream", default_meta) ];
        env = [];
        cwd = None;
        redirects = [ Masc_exec.Redirect_scope.Fd_to_fd { src = 2; dst = 1 } ];
        sandbox = host_sandbox;
      }
  in
  let timeout_stage =
    Simple
      {
        bin = sh_bin;
        args =
          [
            Lit ("-c", default_meta);
            Lit ("cat >/dev/null; printf visible; exit 124", default_meta);
          ];
        env = [];
        cwd = None;
        redirects = [];
        sandbox = host_sandbox;
      }
  in
  let chunks = ref [] in
  let result =
    Masc_exec.Exec_dispatch.dispatch_pipeline
      ~on_output_chunk:(fun chunk -> chunks := chunk :: !chunks)
      [ upstream_stage; timeout_stage ]
  in
  assert (result.status = Process_eio.timed_out_status);
  assert (result.stdout = "visible");
  let streamed_stdout =
    List.rev !chunks
    |> List.filter_map (function
         | `Stdout c -> Some c
         | `Stderr _ -> None)
    |> String.concat ""
  in
  (* Old parse re-emitted the captured stdout after the live stream:
     "visiblevisible". *)
  assert (streamed_stdout = "visible")

(* --- dispatch pipeline exit code: last nonzero wins --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let echo_bin = Masc_exec.Exec_program.of_string "echo" |> Result.get_ok in
  let false_bin = Masc_exec.Exec_program.of_string "false" |> Result.get_ok in
  let host_sandbox = Masc_exec.Sandbox_target.host () in
  let stages = [
    Simple { bin = echo_bin; args = [Lit ("ok", default_meta)]; env = []; cwd = None; redirects = []; sandbox = host_sandbox };
    Simple { bin = false_bin; args = []; env = []; cwd = None; redirects = []; sandbox = host_sandbox };
  ] in
  let result = Masc_exec.Exec_dispatch.dispatch_pipeline stages in
  assert (result.status = Unix.WEXITED 1)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let false_bin = Masc_exec.Exec_program.of_string "false" |> Result.get_ok in
  let echo_bin = Masc_exec.Exec_program.of_string "echo" |> Result.get_ok in
  let host_sandbox = Masc_exec.Sandbox_target.host () in
  let stages =
    [
      Simple
        {
          bin = false_bin;
          args = [];
          env = [];
          cwd = None;
          redirects = [];
          sandbox = host_sandbox;
        };
      Simple
        {
          bin = echo_bin;
          args = [ Lit ("recovered", default_meta) ];
          env = [];
          cwd = None;
          redirects = [];
          sandbox = host_sandbox;
        };
    ]
  in
  let result = Masc_exec.Exec_dispatch.dispatch_pipeline stages in
  assert (result.status = Unix.WEXITED 1);
  assert (String.trim result.stdout = "recovered")

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let sh_bin = Masc_exec.Exec_program.of_string "sh" |> Result.get_ok in
  let host_sandbox = Masc_exec.Sandbox_target.host () in
  let stage script =
    Simple
      {
        bin = sh_bin;
        args = [ Lit ("-c", default_meta); Lit (script, default_meta) ];
        env = [];
        cwd = None;
        redirects = [];
        sandbox = host_sandbox;
      }
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch_pipeline
         [
           stage "echo left >&2; exit 7";
           stage "echo right >&2; exit 3";
         ]
  in
  assert (result.status = Unix.WEXITED 3);
  assert (result.stderr = "left\nright\n")

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let a_bin = Masc_exec.Exec_program.of_string "a" |> Result.get_ok in
  let b_bin = Masc_exec.Exec_program.of_string "b" |> Result.get_ok in
  let c_bin = Masc_exec.Exec_program.of_string "c" |> Result.get_ok in
  let mock_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content ~argv ~env:_ ~cwd:_ =
    match argv, stdin_content with
    | [ "a" ], None ->
        Masc_exec.Sandbox_target.Ran { status = Unix.WEXITED 7; stdout = "a-out"; stderr = "a-err;" }
    | [ "b" ], Some "a-out" ->
        Masc_exec.Sandbox_target.Ran { status = Unix.WEXITED 0; stdout = "b-out"; stderr = "b-err;" }
    | [ "c" ], Some "b-out" ->
        Masc_exec.Sandbox_target.Ran { status = Unix.WEXITED 3; stdout = "c-out"; stderr = "c-err;" }
    | _ ->
        Masc_exec.Sandbox_target.Ran { status = Unix.WEXITED 99; stdout = ""; stderr = "unexpected;" }
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"pipeline-status" ~runner:mock_runner ()
  in
  let simple bin =
    Simple
      {
        bin;
        args = [];
        env = [];
        cwd = None;
        redirects = [];
        sandbox = docker_sandbox;
      }
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch_pipeline [ simple a_bin; simple b_bin; simple c_bin ]
  in
  assert (result.status = Unix.WEXITED 3);
  assert (result.stdout = "c-out");
  assert (result.stderr = "a-err;b-err;c-err;")

(* --- dispatch empty pipeline --- *)

let () =
  with_eio @@ fun () ->
  let result = Masc_exec.Exec_dispatch.dispatch_pipeline [] in
  assert (result.status = Unix.WEXITED 1);
  assert (result.stdout = "");
  assert (result.stderr = "empty pipeline not supported in native dispatch")

(* --- dispatch single-stage pipeline --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Exec_program.of_string "echo" |> Result.get_ok in
  let stage =
    Simple
      { bin
      ; args = [ Lit ("single", default_meta) ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Masc_exec.Sandbox_target.host ()
      }
  in
  let result = Masc_exec.Exec_dispatch.dispatch_pipeline [ stage ] in
  assert (result.status = Unix.WEXITED 1);
  assert (result.stdout = "");
  assert (result.stderr = "single-stage pipeline not supported in native dispatch")

(* --- dispatch nested pipeline --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let echo_bin = Masc_exec.Exec_program.of_string "echo" |> Result.get_ok in
  let cat_bin = Masc_exec.Exec_program.of_string "cat" |> Result.get_ok in
  let host_sandbox = Masc_exec.Sandbox_target.host () in
  let echo_stage =
    Simple
      { bin = echo_bin
      ; args = [ Lit ("nested", default_meta) ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = host_sandbox
      }
  in
  let cat_stage =
    Simple
      { bin = cat_bin
      ; args = []
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = host_sandbox
      }
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch
      (Pipeline [ Pipeline [ echo_stage; cat_stage ]; cat_stage ])
  in
  assert (result.status = Unix.WEXITED 1);
  assert (result.stdout = "");
  (* The message names what is missing rather than what is unsupported: a
     stage that is itself a pipeline or a sequence needs a subshell. *)
  let mentions_subshell haystack =
    let needle = "subshell" in
    let n = String.length needle in
    let rec scan i =
      if i + n > String.length haystack
      then false
      else if String.sub haystack i n = needle
      then true
      else scan (i + 1)
    in
    scan 0
  in
  assert (mentions_subshell result.stderr)

(* --- dispatch_simple propagates sandbox runner (SND-05 regression) --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Exec_program.of_string "echo" |> Result.get_ok in
  let runner_called = ref false in
  let runner_argv = ref [] in
  let runner_env = ref [||] in
  let runner_cwd = ref (Some "should_be_none") in
  let mock_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv ~env ~cwd =
    runner_called := true;
    runner_argv := argv;
    runner_env := env;
    runner_cwd := cwd;
    Masc_exec.Sandbox_target.Ran
      { status = Unix.WEXITED 0; stdout = "mock_stdout"; stderr = "mock_stderr" }
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"test-image" ~runner:mock_runner ()
  in
  let ir =
      { bin
      ; args = [ Lit ("hello", default_meta); Lit ("world", default_meta) ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = docker_sandbox
      }
  in
  let result = Masc_exec.Exec_dispatch.dispatch_simple ir in
  assert (!runner_called);
  assert (!runner_argv = [ "echo"; "hello"; "world" ]);
  assert (Array.length !runner_env = 0);
  assert (!runner_cwd = None);
  assert (result.status = Unix.WEXITED 0);
  assert (result.stdout = "mock_stdout");
  assert (result.stderr = "mock_stderr");
  (* Verify the kind discriminator is surfaced correctly. *)
  (match docker_sandbox with
   | Masc_exec.Sandbox_target.Host
   | Masc_exec.Sandbox_target.Micro_vm _
   | Masc_exec.Sandbox_target.Ssh _
   | Masc_exec.Sandbox_target.Delegated _ -> assert false
   | Masc_exec.Sandbox_target.Docker { image; _ } ->
       assert (image = "test-image"))

(* --- dispatch_simple applies supported redirects deterministically --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Exec_program.of_string "echo" |> Result.get_ok in
  let dev_null =
    Masc_exec.Path_scope.classify ~raw:"/dev/null" ~cwd:"/tmp"
  in
  let mock_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ =
    Masc_exec.Sandbox_target.Ran
      { status = Unix.WEXITED 0; stdout = "stdout"; stderr = "stderr" }
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"redirect-image" ~runner:mock_runner ()
  in
  let ir =
      {
        bin;
        args = [];
        env = [];
        cwd = None;
        redirects =
          [
            Masc_exec.Redirect_scope.Fd_to_fd { src = 2; dst = 1 };
            Masc_exec.Redirect_scope.File
              { fd = 1
              ; target = Masc_exec.Redirect_scope.In_command_namespace dev_null
              ; mode = Masc_exec.Redirect_scope.Write
              };
          ];
        sandbox = docker_sandbox;
      }
  in
  let result = Masc_exec.Exec_dispatch.dispatch_simple ir in
  assert (result.status = Unix.WEXITED 0);
  assert (result.stdout = "stderr");
  assert (result.stderr = "")

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Exec_program.of_string "echo" |> Result.get_ok in
  let dev_null =
    Masc_exec.Path_scope.classify ~raw:"/dev/null" ~cwd:"/tmp"
  in
  let mock_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ =
    Masc_exec.Sandbox_target.Ran
      { status = Unix.WEXITED 0; stdout = "stdout"; stderr = "stderr" }
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"redirect-image" ~runner:mock_runner ()
  in
  let ir =
      {
        bin;
        args = [];
        env = [];
        cwd = None;
        redirects =
          [
            Masc_exec.Redirect_scope.File
              { fd = 2
              ; target = Masc_exec.Redirect_scope.In_command_namespace dev_null
              ; mode = Masc_exec.Redirect_scope.Write
              };
          ];
        sandbox = docker_sandbox;
      }
  in
  let result = Masc_exec.Exec_dispatch.dispatch_simple ir in
  assert (result.status = Unix.WEXITED 0);
  assert (result.stdout = "stdout");
  assert (result.stderr = "")

(* --- dispatch_simple rejects unsupported redirects before spawning --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Exec_program.of_string "echo" |> Result.get_ok in
  let runner_called = ref false in
  let unsupported_target =
    Masc_exec.Path_scope.classify ~raw:"/tmp/exec-dispatch-out" ~cwd:"/tmp"
  in
  let mock_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ =
    runner_called := true;
    Masc_exec.Sandbox_target.Ran
      { status = Unix.WEXITED 0; stdout = "stdout"; stderr = "stderr" }
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"redirect-image" ~runner:mock_runner ()
  in
  let ir =
      {
        bin;
        args = [];
        env = [];
        cwd = None;
        redirects =
          [
            Masc_exec.Redirect_scope.File
              {
                fd = 1;
                target = Masc_exec.Redirect_scope.In_command_namespace unsupported_target;
                mode = Masc_exec.Redirect_scope.Write;
              };
          ];
        sandbox = docker_sandbox;
      }
  in
  let result = Masc_exec.Exec_dispatch.dispatch_simple ir in
  assert (not !runner_called);
  assert (result.status = Unix.WEXITED 1);
  assert (result.stdout = "");
  assert (String.length result.stderr > 0)

(* --- dispatch_pipeline propagates stdin and sandbox runner --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let printf_bin = Masc_exec.Exec_program.of_string "printf" |> Result.get_ok in
  let wc_bin = Masc_exec.Exec_program.of_string "wc" |> Result.get_ok in
  let runner_calls = ref [] in
  let mock_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content ~argv ~env:_ ~cwd =
    runner_calls := (argv, cwd, stdin_content) :: !runner_calls;
    match argv, stdin_content with
    | [ "printf"; "typed" ], None ->
        Masc_exec.Sandbox_target.Ran { status = Unix.WEXITED 0; stdout = "typed"; stderr = "" }
    | [ "wc"; "-c" ], Some "typed" ->
        Masc_exec.Sandbox_target.Ran { status = Unix.WEXITED 0; stdout = "5\n"; stderr = "" }
    | _ ->
        Masc_exec.Sandbox_target.Ran
          { status = Unix.WEXITED 2; stdout = ""; stderr = "unexpected mock runner call" }
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"pipeline-image" ~runner:mock_runner ()
  in
  let cwd = Some (Masc_exec.Path_scope.classify ~raw:"/tmp/pipeline" ~cwd:"/tmp/pipeline") in
  let stages =
    [
      Simple
        {
          bin = printf_bin;
          args = [ Lit ("typed", default_meta) ];
          env = [];
          cwd;
          redirects = [];
          sandbox = docker_sandbox;
        };
      Simple
        {
          bin = wc_bin;
          args = [ Lit ("-c", default_meta) ];
          env = [];
          cwd;
          redirects = [];
          sandbox = docker_sandbox;
        };
    ]
  in
  let result = Masc_exec.Exec_dispatch.dispatch_pipeline stages in
  assert (result.status = Unix.WEXITED 0);
  assert (String.trim result.stdout = "5");
  match List.rev !runner_calls with
  | [ ([ "printf"; "typed" ], Some first_cwd, None)
    ; ([ "wc"; "-c" ], Some second_cwd, Some "typed") ] ->
	      assert (first_cwd = "/tmp/pipeline");
	      assert (second_cwd = "/tmp/pipeline")
	  | _ -> assert false

(* Per-caller timeout was removed; this test no longer models a deadline
   decrement. We keep the streaming check (slow → typed → ok) to confirm
   that the pipeline runner still threads the previous stage's stdout into
   the next call regardless of how long the stage takes. *)
let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let slow_bin = Masc_exec.Exec_program.of_string "slow" |> Result.get_ok in
  let next_bin = Masc_exec.Exec_program.of_string "next" |> Result.get_ok in
  let runner_calls = ref [] in
  let mock_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content ~argv ~env:_ ~cwd:_ =
    runner_calls := (argv, stdin_content) :: !runner_calls;
    match argv, stdin_content with
    | [ "slow" ], None ->
        Unix.sleepf 0.12;
        Masc_exec.Sandbox_target.Ran { status = Unix.WEXITED 0; stdout = "typed"; stderr = "" }
    | [ "next" ], Some "typed" ->
        Masc_exec.Sandbox_target.Ran { status = Unix.WEXITED 0; stdout = "ok"; stderr = "" }
    | _ ->
        Masc_exec.Sandbox_target.Ran
          { status = Unix.WEXITED 2; stdout = ""; stderr = "unexpected mock runner call" }
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"pipeline-image" ~runner:mock_runner ()
  in
  let stage bin =
    Simple
      {
        bin;
        args = [];
        env = [];
        cwd = None;
        redirects = [];
        sandbox = docker_sandbox;
      }
  in
  let result =
    Masc_exec.Exec_dispatch.dispatch_pipeline [ stage slow_bin; stage next_bin ]
  in
  assert (result.status = Unix.WEXITED 0);
  assert (result.stdout = "ok");
  match List.rev !runner_calls with
  | [ ([ "slow" ], None); ([ "next" ], Some "typed") ] -> ()
  | _ -> assert false

(* --- dispatch_pipeline prefers Docker streaming pipeline runner --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let printf_bin = Masc_exec.Exec_program.of_string "printf" |> Result.get_ok in
  let wc_bin = Masc_exec.Exec_program.of_string "wc" |> Result.get_ok in
  let simple_runner_called = ref false in
  let pipeline_runner_calls = ref [] in
  let simple_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ =
    simple_runner_called := true;
    Masc_exec.Sandbox_target.Ran
      { status = Unix.WEXITED 3; stdout = ""; stderr = "simple runner should not be used" }
  in
  let pipeline_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stages =
    pipeline_runner_calls := stages :: !pipeline_runner_calls;
    Masc_exec.Sandbox_target.Ran
      { status = Unix.WEXITED 0; stdout = "5\n"; stderr = "pipeline-stderr" }
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker
      ~image:"pipeline-image"
      ~runner:simple_runner
      ~pipeline_runner
      ()
  in
  let cwd =
    Some
      (Masc_exec.Path_scope.classify ~raw:"/tmp/pipeline" ~cwd:"/tmp/pipeline")
  in
  let stages =
    [
      Simple
        {
          bin = printf_bin;
          args = [ Lit ("typed", default_meta) ];
          env = [];
          cwd;
          redirects = [];
          sandbox = docker_sandbox;
        };
      Simple
        {
          bin = wc_bin;
          args = [ Lit ("-c", default_meta) ];
          env = [];
          cwd;
          redirects = [];
          sandbox = docker_sandbox;
        };
    ]
  in
  let result = Masc_exec.Exec_dispatch.dispatch_pipeline stages in
  assert (not !simple_runner_called);
  assert (result.status = Unix.WEXITED 0);
  assert (String.trim result.stdout = "5");
  assert (result.stderr = "pipeline-stderr");
  match !pipeline_runner_calls with
  | [ [ first; second ] ] ->
      assert (first.Masc_exec.Sandbox_target.argv = [ "printf"; "typed" ]);
      assert (second.Masc_exec.Sandbox_target.argv = [ "wc"; "-c" ]);
      assert (first.cwd = Some "/tmp/pipeline");
      assert (second.cwd = Some "/tmp/pipeline")
  | _ -> assert false

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let printf_bin = Masc_exec.Exec_program.of_string "printf" |> Result.get_ok in
  let wc_bin = Masc_exec.Exec_program.of_string "wc" |> Result.get_ok in
  let first_simple_calls = ref [] in
  let second_simple_calls = ref [] in
  let first_pipeline_called = ref false in
  let second_pipeline_called = ref false in
  let first_simple_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content ~argv ~env:_ ~cwd:_ =
    first_simple_calls := (argv, stdin_content) :: !first_simple_calls;
    match argv, stdin_content with
    | [ "printf"; "typed" ], None ->
        Masc_exec.Sandbox_target.Ran { status = Unix.WEXITED 0; stdout = "typed"; stderr = "" }
    | _ ->
        Masc_exec.Sandbox_target.Ran
          { status = Unix.WEXITED 2; stdout = ""; stderr = "unexpected first runner call" }
  in
  let second_simple_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content ~argv ~env:_ ~cwd:_ =
    second_simple_calls := (argv, stdin_content) :: !second_simple_calls;
    match argv, stdin_content with
    | [ "wc"; "-c" ], Some "typed" ->
        Masc_exec.Sandbox_target.Ran { status = Unix.WEXITED 0; stdout = "5\n"; stderr = "" }
    | _ ->
        Masc_exec.Sandbox_target.Ran
          { status = Unix.WEXITED 2; stdout = ""; stderr = "unexpected second runner call" }
  in
  let first_pipeline_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stages:_ =
    first_pipeline_called := true;
    Masc_exec.Sandbox_target.Ran
      { status = Unix.WEXITED 3; stdout = ""; stderr = "first pipeline runner should not be used" }
  in
  let second_pipeline_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stages:_ =
    second_pipeline_called := true;
    Masc_exec.Sandbox_target.Ran
      { status = Unix.WEXITED 3; stdout = ""; stderr = "second pipeline runner should not be used" }
  in
  let first_docker_sandbox =
    Masc_exec.Sandbox_target.docker
      ~image:"pipeline-image"
      ~runner:first_simple_runner
      ~pipeline_runner:first_pipeline_runner
      ()
  in
  let second_docker_sandbox =
    Masc_exec.Sandbox_target.docker
      ~image:"pipeline-image"
      ~runner:second_simple_runner
      ~pipeline_runner:second_pipeline_runner
      ()
  in
  let stages =
    [
      Simple
        {
          bin = printf_bin;
          args = [ Lit ("typed", default_meta) ];
          env = [];
          cwd = None;
          redirects = [];
          sandbox = first_docker_sandbox;
        };
      Simple
        {
          bin = wc_bin;
          args = [ Lit ("-c", default_meta) ];
          env = [];
          cwd = None;
          redirects = [];
          sandbox = second_docker_sandbox;
        };
    ]
  in
  let result = Masc_exec.Exec_dispatch.dispatch_pipeline stages in
  assert (not !first_pipeline_called);
  assert (not !second_pipeline_called);
  assert (result.status = Unix.WEXITED 0);
  assert (String.trim result.stdout = "5");
  assert (!first_simple_calls = [ [ "printf"; "typed" ], None ]);
  assert (!second_simple_calls = [ [ "wc"; "-c" ], Some "typed" ])

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let printf_bin = Masc_exec.Exec_program.of_string "printf" |> Result.get_ok in
  let wc_bin = Masc_exec.Exec_program.of_string "wc" |> Result.get_ok in
  let dev_null =
    Masc_exec.Path_scope.classify ~raw:"/dev/null" ~cwd:"/tmp"
  in
  let simple_runner_calls = ref [] in
  let pipeline_runner_called = ref false in
  let simple_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content ~argv ~env:_ ~cwd:_ =
    simple_runner_calls := (argv, stdin_content) :: !simple_runner_calls;
    match argv, stdin_content with
    | [ "printf"; "typed" ], None ->
        Masc_exec.Sandbox_target.Ran { status = Unix.WEXITED 0; stdout = "typed"; stderr = "hidden" }
    | [ "wc"; "-c" ], Some "typed" ->
        Masc_exec.Sandbox_target.Ran { status = Unix.WEXITED 0; stdout = "5\n"; stderr = "" }
    | _ ->
        Masc_exec.Sandbox_target.Ran
          { status = Unix.WEXITED 2; stdout = ""; stderr = "unexpected mock runner call" }
  in
  let pipeline_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stages:_ =
    pipeline_runner_called := true;
    Masc_exec.Sandbox_target.Ran
      { status = Unix.WEXITED 3; stdout = ""; stderr = "pipeline runner should not be used for redirects" }
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker
      ~image:"pipeline-image"
      ~runner:simple_runner
      ~pipeline_runner
      ()
  in
  let stages =
    [
      Simple
        {
          bin = printf_bin;
          args = [ Lit ("typed", default_meta) ];
          env = [];
          cwd = None;
          redirects =
            [
              Masc_exec.Redirect_scope.File
                { fd = 2
              ; target = Masc_exec.Redirect_scope.In_command_namespace dev_null
              ; mode = Masc_exec.Redirect_scope.Write
              };
            ];
          sandbox = docker_sandbox;
        };
      Simple
        {
          bin = wc_bin;
          args = [ Lit ("-c", default_meta) ];
          env = [];
          cwd = None;
          redirects = [];
          sandbox = docker_sandbox;
        };
    ]
  in
  let result = Masc_exec.Exec_dispatch.dispatch_pipeline stages in
  assert (not !pipeline_runner_called);
  assert (result.status = Unix.WEXITED 0);
  assert (String.trim result.stdout = "5");
  assert (result.stderr = "");
  match List.rev !simple_runner_calls with
  | [ ([ "printf"; "typed" ], None); ([ "wc"; "-c" ], Some "typed") ] -> ()
  | _ -> assert false

(* --- dispatch_simple exception from runner is caught --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Exec_program.of_string "echo" |> Result.get_ok in
  let mock_runner ~on_stdout_chunk:_ ~on_stderr_chunk:_ ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ =
    failwith "mock docker failure"
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"fail-image" ~runner:mock_runner ()
  in
  let ir =
      { bin
      ; args = [ Lit ("x", default_meta) ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = docker_sandbox
      }
  in
  let result = Masc_exec.Exec_dispatch.dispatch_simple ir in
  assert (result.status = Unix.WEXITED 1);
  assert (result.stdout = "");
  assert (String.length result.stderr > 0)

(* --- Keeper shell adapter validates and dispatches neutral IR. --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Exec_program.of_string "echo" |> Result.get_ok in
  let ir =
    Simple
      { bin
      ; args = [ Lit ("adapter", default_meta) ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Masc_exec.Sandbox_target.host ()
      }
  in
  match
    Keeper_tooling.Execute_shell_ir.dispatch
      ~workdir:"/tmp"
      ~sandbox:(Masc_exec.Sandbox_target.host ())
      ir
  with
  | Ok result ->
    assert (result.status = Unix.WEXITED 0);
    assert (String.trim result.stdout = "adapter")
  | Error _ -> assert false

(* Witness, not inference. A redirect surface has advertised something its
   executor could not do before -- a file mode that errored out before the
   process was ever spawned -- so a literal stdin is proved by a child that
   read it and said so. [cat] with no arguments reads stdin: if the bytes do
   not reach it, the output is empty or the read blocks, and either fails. *)
let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Exec_program.of_string "cat" |> Result.get_ok in
  let content = "hello from a heredoc\n" in
  let ir =
    Simple
      { bin
      ; args = []
      ; env = []
      ; cwd = None
      ; redirects = [ Masc_exec.Redirect_scope.Literal { bytes = content } ]
      ; sandbox = Masc_exec.Sandbox_target.host ()
      }
  in
  match
    Keeper_tooling.Execute_shell_ir.dispatch
      ~workdir:"/tmp"
      ~sandbox:(Masc_exec.Sandbox_target.host ())
      ~timeout_sec:10.
      ir
  with
  | Ok result ->
    if result.status <> Unix.WEXITED 0
    then failwith "cat must exit zero when its stdin is a literal";
    if result.stdout <> content
    then
      failwith
        (Printf.sprintf
           "the literal must reach the child verbatim: wanted %S, got %S"
           content
           result.stdout)
  | Error _ -> failwith "a literal stdin must not be refused"
;;

(* [shell_command_gate.mli] says the facade refuses a nested pipeline so
   callers need no flatten policy of their own.  That was true of
   [lower_typed_pipeline], whose input is a [simple list] and cannot nest, and
   false of [gate_typed], which takes any [Shell_ir.t].  Measured 2026-08-24:
   [Pipeline [Pipeline [a; b]; c]] handed to [Execute_shell_ir.dispatch] ran.
   [Unsupported_nested_pipeline] existed, had a tag, and was produced nowhere. *)
let () =
  with_eio @@ fun () ->
  let module Adapter = Keeper_tooling.Execute_shell_ir in
  let module Gate = Masc_exec_command_gate.Shell_command_gate in
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Exec_program.of_string "echo" |> Result.get_ok in
  let stage text =
    Simple
      { bin
      ; args = [ Lit (text, default_meta) ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Masc_exec.Sandbox_target.host ()
      }
  in
  let refusal_tag = function
    | Adapter.Too_complex reason -> "too_complex:" ^ Adapter.too_complex_reason_tag reason
    | Adapter.Cannot_parse reason -> "cannot_parse:" ^ Adapter.parse_reason_tag reason
    | Adapter.Gate_reject diagnostic -> "gate_reject:" ^ diagnostic
    | Adapter.Path_reject diagnostic -> "path_reject:" ^ diagnostic
  in
  let dispatch ir =
    Adapter.dispatch
      ~workdir:"/tmp"
      ~sandbox:(Masc_exec.Sandbox_target.host ())
      ir
  in
  (match dispatch (Pipeline [ Pipeline [ stage "a"; stage "b" ]; stage "c" ]) with
   | Error (Adapter.Too_complex Gate.Unsupported_nested_pipeline) -> ()
   | Error other ->
     failwith
       (Printf.sprintf
          "a nested pipeline must be refused as unsupported_nested_pipeline, got %s"
          (refusal_tag other))
   | Ok _ -> failwith "a nested pipeline must not reach dispatch");
  (* [Pipeline] documents "length >= 2" and the type does not hold it, so the
     gate is where a one-stage pipeline stops. *)
  (match dispatch (Pipeline [ stage "alone" ]) with
   | Error (Adapter.Cannot_parse Gate.Parse_error) -> ()
   | Error other ->
     failwith
       (Printf.sprintf
          "a one-stage pipeline must be refused as cannot_parse, got %s"
          (refusal_tag other))
   | Ok _ -> failwith "a one-stage pipeline must not reach dispatch");
  (* A flat pipeline is untouched by any of this. *)
  match dispatch (Pipeline [ stage "a"; stage "b" ]) with
  | Ok _ -> ()
  | Error other ->
    failwith (Printf.sprintf "a flat pipeline must still run, got %s" (refusal_tag other))
;;
let () =
  Printf.printf "p7_exec_dispatch: all tests passed.\n"
