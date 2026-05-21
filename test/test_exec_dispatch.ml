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
    let result = Masc_exec.Exec_dispatch.(resolve_arg (Lit "hello")) in
    assert (result = "hello")
  in
  test_resolve_lit

let () =
  let open Masc_exec.Shell_ir in
  Unix.putenv "MASC_TEST_P7_VAR" "world";
  let result = Masc_exec.Exec_dispatch.(resolve_arg (Var "MASC_TEST_P7_VAR")) in
  assert (result = "world")

let () =
  let open Masc_exec.Shell_ir in
  let result = Masc_exec.Exec_dispatch.(resolve_arg (Var "__MASC_NONEXISTENT_P7__")) in
  assert (result = "")

let () =
  let open Masc_exec.Shell_ir in
  Unix.putenv "MASC_TEST_P7_VAR" "world";
  let result = Masc_exec.Exec_dispatch.(resolve_arg (Concat [Lit "prefix-"; Var "MASC_TEST_P7_VAR"; Lit "-suffix"])) in
  assert (result = "prefix-world-suffix");
  Unix.putenv "MASC_TEST_P7_VAR" ""

(* --- dispatch_simple with real process --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Bin.of_string "echo" |> Result.get_ok in
  let ir =
    Simple
      { bin
      ; args = [ Lit "hello"; Lit "world" ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Masc_exec.Sandbox_target.host ()
      }
  in
  let result = Masc_exec.Exec_dispatch.dispatch ir in
  let stdout = String.trim result.stdout in
  assert (stdout = "hello world");
  assert (result.status = Unix.WEXITED 0)

(* --- dispatch_simple captures stderr --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Bin.of_string "cat" |> Result.get_ok in
  let ir =
    Simple
      { bin
      ; args = [ Lit "/nonexistent_file_p7_test" ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Masc_exec.Sandbox_target.host ()
      }
  in
  let result = Masc_exec.Exec_dispatch.dispatch ir in
  assert (result.status <> Unix.WEXITED 0);
  assert (String.length result.stderr > 0)

(* --- dispatch pipeline --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let echo_bin = Masc_exec.Bin.of_string "echo" |> Result.get_ok in
  let tr_bin = Masc_exec.Bin.of_string "tr" |> Result.get_ok in
  let host_sandbox = Masc_exec.Sandbox_target.host () in
  let stages = [
    Simple { bin = echo_bin; args = [Lit "hello world"]; env = []; cwd = None; redirects = []; sandbox = host_sandbox };
    Simple { bin = tr_bin; args = [Lit "a-z"; Lit "A-Z"]; env = []; cwd = None; redirects = []; sandbox = host_sandbox };
  ] in
  let result = Masc_exec.Exec_dispatch.dispatch (Pipeline stages) in
  let stdout = String.trim result.stdout in
  assert (stdout = "HELLO WORLD");
  assert (result.status = Unix.WEXITED 0)

(* --- host pipeline streams between stages --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let yes_bin = Masc_exec.Bin.of_string "yes" |> Result.get_ok in
  let head_bin = Masc_exec.Bin.of_string "head" |> Result.get_ok in
  let host_sandbox = Masc_exec.Sandbox_target.host () in
  let stages =
    [
      Simple { bin = yes_bin; args = []; env = []; cwd = None; redirects = []; sandbox = host_sandbox };
      Simple { bin = head_bin; args = [Lit "-n"; Lit "1"]; env = []; cwd = None; redirects = []; sandbox = host_sandbox };
    ]
  in
  let result = Masc_exec.Exec_dispatch.dispatch ~timeout_sec:2.0 (Pipeline stages) in
  assert (String.trim result.stdout = "y");
  assert (result.status <> Unix.WEXITED 124)

(* --- dispatch pipeline exit code: last nonzero wins --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let echo_bin = Masc_exec.Bin.of_string "echo" |> Result.get_ok in
  let false_bin = Masc_exec.Bin.of_string "false" |> Result.get_ok in
  let host_sandbox = Masc_exec.Sandbox_target.host () in
  let stages = [
    Simple { bin = echo_bin; args = [Lit "ok"]; env = []; cwd = None; redirects = []; sandbox = host_sandbox };
    Simple { bin = false_bin; args = []; env = []; cwd = None; redirects = []; sandbox = host_sandbox };
  ] in
  let result = Masc_exec.Exec_dispatch.dispatch (Pipeline stages) in
  assert (result.status = Unix.WEXITED 1)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let false_bin = Masc_exec.Bin.of_string "false" |> Result.get_ok in
  let echo_bin = Masc_exec.Bin.of_string "echo" |> Result.get_ok in
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
          args = [ Lit "recovered" ];
          env = [];
          cwd = None;
          redirects = [];
          sandbox = host_sandbox;
        };
    ]
  in
  let result = Masc_exec.Exec_dispatch.dispatch (Pipeline stages) in
  assert (result.status = Unix.WEXITED 1);
  assert (String.trim result.stdout = "recovered")

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let a_bin = Masc_exec.Bin.of_string "a" |> Result.get_ok in
  let b_bin = Masc_exec.Bin.of_string "b" |> Result.get_ok in
  let c_bin = Masc_exec.Bin.of_string "c" |> Result.get_ok in
  let mock_runner ~stdin_content ~argv ~env:_ ~cwd:_ ~timeout_sec:_ =
    match argv, stdin_content with
    | [ "a" ], None -> Unix.WEXITED 7, "a-out", "a-err;"
    | [ "b" ], Some "a-out" -> Unix.WEXITED 0, "b-out", "b-err;"
    | [ "c" ], Some "b-out" -> Unix.WEXITED 3, "c-out", "c-err;"
    | _ -> Unix.WEXITED 99, "", "unexpected;"
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"pipeline-status" ~runner:mock_runner
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
    Masc_exec.Exec_dispatch.dispatch
      (Pipeline [ simple a_bin; simple b_bin; simple c_bin ])
  in
  assert (result.status = Unix.WEXITED 3);
  assert (result.stdout = "c-out");
  assert (result.stderr = "a-err;b-err;c-err;")

(* --- dispatch empty pipeline --- *)

let () =
  with_eio @@ fun () ->
  let result = Masc_exec.Exec_dispatch.dispatch (Masc_exec.Shell_ir.Pipeline []) in
  assert (result.status = Unix.WEXITED 1);
  assert (result.stdout = "");
  assert (result.stderr = "empty pipeline not supported in native dispatch")

(* --- dispatch single-stage pipeline --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Bin.of_string "echo" |> Result.get_ok in
  let stage =
    Simple
      { bin
      ; args = [ Lit "single" ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Masc_exec.Sandbox_target.host ()
      }
  in
  let result = Masc_exec.Exec_dispatch.dispatch (Pipeline [ stage ]) in
  assert (result.status = Unix.WEXITED 1);
  assert (result.stdout = "");
  assert (result.stderr = "single-stage pipeline not supported in native dispatch")

(* --- dispatch nested pipeline --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let echo_bin = Masc_exec.Bin.of_string "echo" |> Result.get_ok in
  let cat_bin = Masc_exec.Bin.of_string "cat" |> Result.get_ok in
  let host_sandbox = Masc_exec.Sandbox_target.host () in
  let echo_stage =
    Simple
      { bin = echo_bin
      ; args = [ Lit "nested" ]
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
    Masc_exec.Exec_dispatch.dispatch (Pipeline [ Pipeline [ echo_stage; cat_stage ]; cat_stage ])
  in
  assert (result.status = Unix.WEXITED 1);
  assert (result.stdout = "");
  assert (result.stderr = "nested pipeline not supported in native dispatch")

(* --- dispatch_simple propagates sandbox runner (SND-05 regression) --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Bin.of_string "echo" |> Result.get_ok in
  let runner_called = ref false in
  let runner_argv = ref [] in
  let runner_env = ref [||] in
  let runner_cwd = ref (Some "should_be_none") in
  let mock_runner ~stdin_content:_ ~argv ~env ~cwd ~timeout_sec:_ =
    runner_called := true;
    runner_argv := argv;
    runner_env := env;
    runner_cwd := cwd;
    (Unix.WEXITED 0, "mock_stdout", "mock_stderr")
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"test-image" ~runner:mock_runner
  in
  let ir =
    Simple
      { bin
      ; args = [ Lit "hello"; Lit "world" ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = docker_sandbox
      }
  in
  let result = Masc_exec.Exec_dispatch.dispatch ir in
  assert (!runner_called);
  assert (!runner_argv = [ "echo"; "hello"; "world" ]);
  assert (Array.length !runner_env = 0);
  assert (!runner_cwd = None);
  assert (result.status = Unix.WEXITED 0);
  assert (result.stdout = "mock_stdout");
  assert (result.stderr = "mock_stderr");
  (* Verify the kind discriminator is surfaced correctly. *)
  (match docker_sandbox with
   | Masc_exec.Sandbox_target.Host -> assert false
   | Masc_exec.Sandbox_target.Docker { image; _ } ->
       assert (image = "test-image"))

(* --- dispatch_simple applies supported redirects deterministically --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Bin.of_string "echo" |> Result.get_ok in
  let dev_null =
    Masc_exec.Path_scope.classify ~raw:"/dev/null" ~cwd:"/tmp"
  in
  let mock_runner ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ ~timeout_sec:_ =
    Unix.WEXITED 0, "stdout", "stderr"
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"redirect-image" ~runner:mock_runner
  in
  let ir =
    Simple
      {
        bin;
        args = [];
        env = [];
        cwd = None;
        redirects =
          [
            Masc_exec.Redirect_scope.Fd_to_fd { src = 2; dst = 1 };
            Masc_exec.Redirect_scope.File
              { fd = 1; target = dev_null; mode = Masc_exec.Redirect_scope.Write };
          ];
        sandbox = docker_sandbox;
      }
  in
  let result = Masc_exec.Exec_dispatch.dispatch ir in
  assert (result.status = Unix.WEXITED 0);
  assert (result.stdout = "stderr");
  assert (result.stderr = "")

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Bin.of_string "echo" |> Result.get_ok in
  let dev_null =
    Masc_exec.Path_scope.classify ~raw:"/dev/null" ~cwd:"/tmp"
  in
  let mock_runner ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ ~timeout_sec:_ =
    Unix.WEXITED 0, "stdout", "stderr"
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"redirect-image" ~runner:mock_runner
  in
  let ir =
    Simple
      {
        bin;
        args = [];
        env = [];
        cwd = None;
        redirects =
          [
            Masc_exec.Redirect_scope.File
              { fd = 2; target = dev_null; mode = Masc_exec.Redirect_scope.Write };
          ];
        sandbox = docker_sandbox;
      }
  in
  let result = Masc_exec.Exec_dispatch.dispatch ir in
  assert (result.status = Unix.WEXITED 0);
  assert (result.stdout = "stdout");
  assert (result.stderr = "")

(* --- dispatch_simple rejects unsupported redirects before spawning --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Bin.of_string "echo" |> Result.get_ok in
  let runner_called = ref false in
  let unsupported_target =
    Masc_exec.Path_scope.classify ~raw:"/tmp/exec-dispatch-out" ~cwd:"/tmp"
  in
  let mock_runner ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ ~timeout_sec:_ =
    runner_called := true;
    Unix.WEXITED 0, "stdout", "stderr"
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"redirect-image" ~runner:mock_runner
  in
  let ir =
    Simple
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
                target = unsupported_target;
                mode = Masc_exec.Redirect_scope.Write;
              };
          ];
        sandbox = docker_sandbox;
      }
  in
  let result = Masc_exec.Exec_dispatch.dispatch ir in
  assert (not !runner_called);
  assert (result.status = Unix.WEXITED 1);
  assert (result.stdout = "");
  assert (String.length result.stderr > 0)

(* --- dispatch_pipeline propagates stdin and sandbox runner --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let printf_bin = Masc_exec.Bin.of_string "printf" |> Result.get_ok in
  let wc_bin = Masc_exec.Bin.of_string "wc" |> Result.get_ok in
  let runner_calls = ref [] in
  let mock_runner ~stdin_content ~argv ~env:_ ~cwd ~timeout_sec:_ =
    runner_calls := (argv, cwd, stdin_content) :: !runner_calls;
    match argv, stdin_content with
    | [ "printf"; "typed" ], None -> Unix.WEXITED 0, "typed", ""
    | [ "wc"; "-c" ], Some "typed" -> Unix.WEXITED 0, "5\n", ""
    | _ -> Unix.WEXITED 2, "", "unexpected mock runner call"
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"pipeline-image" ~runner:mock_runner
  in
  let cwd = Some (Masc_exec.Path_scope.classify ~raw:"/tmp/pipeline" ~cwd:"/tmp/pipeline") in
  let stages =
    [
      Simple
        {
          bin = printf_bin;
          args = [ Lit "typed" ];
          env = [];
          cwd;
          redirects = [];
          sandbox = docker_sandbox;
        };
      Simple
        {
          bin = wc_bin;
          args = [ Lit "-c" ];
          env = [];
          cwd;
          redirects = [];
          sandbox = docker_sandbox;
        };
    ]
  in
  let result = Masc_exec.Exec_dispatch.dispatch (Pipeline stages) in
  assert (result.status = Unix.WEXITED 0);
  assert (String.trim result.stdout = "5");
  match List.rev !runner_calls with
  | [ ([ "printf"; "typed" ], Some first_cwd, None)
    ; ([ "wc"; "-c" ], Some second_cwd, Some "typed") ] ->
      assert (first_cwd = "/tmp/pipeline");
      assert (second_cwd = "/tmp/pipeline")
  | _ -> assert false

(* --- dispatch_simple exception from runner is caught --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Bin.of_string "echo" |> Result.get_ok in
  let mock_runner ~stdin_content:_ ~argv:_ ~env:_ ~cwd:_ ~timeout_sec:_ =
    failwith "mock docker failure"
  in
  let docker_sandbox =
    Masc_exec.Sandbox_target.docker ~image:"fail-image" ~runner:mock_runner
  in
  let ir =
    Simple
      { bin
      ; args = [ Lit "x" ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = docker_sandbox
      }
  in
  let result = Masc_exec.Exec_dispatch.dispatch ir in
  assert (result.status = Unix.WEXITED 1);
  assert (result.stdout = "");
  assert (String.length result.stderr > 0)

let () =
  Printf.printf "p7_exec_dispatch: all tests passed.\n"
