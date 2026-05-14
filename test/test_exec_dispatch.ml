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

(* --- native_dispatch_enabled --- *)

let () =
  Unix.putenv "MASC_BASH_NATIVE_DISPATCH" "0";
  assert (not (Masc_exec.Exec_dispatch.native_dispatch_enabled ()));
  Unix.putenv "MASC_BASH_NATIVE_DISPATCH" "1";
  assert (Masc_exec.Exec_dispatch.native_dispatch_enabled ());
  Unix.putenv "MASC_BASH_NATIVE_DISPATCH" "";
  assert (Masc_exec.Exec_dispatch.native_dispatch_enabled ())

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

(* --- dispatch empty pipeline --- *)

let () =
  with_eio @@ fun () ->
  let result = Masc_exec.Exec_dispatch.dispatch (Masc_exec.Shell_ir.Pipeline []) in
  assert (result.status = Unix.WEXITED 0);
  assert (result.stdout = "")

(* --- dispatch_simple propagates sandbox runner (SND-05 regression) --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Bin.of_string "echo" |> Result.get_ok in
  let runner_called = ref false in
  let runner_argv = ref [] in
  let runner_env = ref [||] in
  let runner_cwd = ref (Some "should_be_none") in
  let mock_runner ~argv ~env ~cwd ~timeout_sec:_ =
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

(* --- dispatch_simple exception from runner is caught --- *)

let () =
  with_eio @@ fun () ->
  let open Masc_exec.Shell_ir in
  let bin = Masc_exec.Bin.of_string "echo" |> Result.get_ok in
  let mock_runner ~argv:_ ~env:_ ~cwd:_ ~timeout_sec:_ =
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
