(* Runs argv as a child of one of masc's spawn paths and prints how the child
   ended. [mgr] starts it with [Posix_spawn_process_mgr.mgr], the manager the
   server starts official-client CLIs with, and hands it this fixture's own
   stdin. [eio] initialises the Eio process layer and goes through the
   capturing runner; [unix] leaves the layer uninitialised so the runner takes
   its Unix fallback. test_process_group_terminal_stdin.py starts this under a
   pseudo-terminal. *)

(* Every case rests on this line: the fixture itself has a controlling
   terminal. Without one no child could open it either, and a pass would
   prove nothing. *)
let print_parent_terminal () =
  match Unix.openfile "/dev/tty" [ Unix.O_RDONLY ] 0 with
  | fd ->
    Unix.close fd;
    print_endline "parent opens its terminal"
  | exception Unix.Unix_error (error, _, _) ->
    Printf.printf "parent has no terminal: %s\n%!" (Unix.error_message error)

let run_through_the_server_manager env argv =
  Eio.Switch.run (fun sw ->
    let mgr = Posix_spawn_process_mgr.mgr in
    let stdout_r, stdout_w = Eio.Process.pipe ~sw mgr in
    let proc =
      Eio.Process.spawn ~sw mgr ~stdin:(Eio.Stdenv.stdin env) ~stdout:stdout_w argv
    in
    Eio.Flow.close stdout_w;
    let stdout = Eio.Buf_read.(parse_exn take_all) stdout_r ~max_size:max_int in
    match Eio.Process.await proc with
    | `Exited code -> Printf.printf "exited %d %s\n%!" code (String.trim stdout)
    | `Signaled signal -> Printf.printf "signaled %d\n%!" signal)

let run_through_the_runner argv =
  match Process_eio.run_argv_with_status_split_or_refusal argv with
  | Ok (Unix.WEXITED code, stdout, _) -> Printf.printf "exited %d %s\n%!" code (String.trim stdout)
  | Ok (Unix.WSIGNALED signal, _, _) -> Printf.printf "signaled %d\n%!" signal
  | Ok (Unix.WSTOPPED signal, _, _) -> Printf.printf "stopped %d\n%!" signal
  | Error refusal ->
    Printf.printf "refused %s\n%!" (Process_eio.spawn_refusal_to_string refusal)

let () =
  match Array.to_list Sys.argv with
  | _ :: mode :: (_ :: _ as argv) ->
    Eio_main.run (fun env ->
      print_parent_terminal ();
      match mode with
      | "mgr" -> run_through_the_server_manager env argv
      | "eio" ->
        Process_eio.init
          ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
          ~proc_mgr:(Eio.Stdenv.process_mgr env)
          ~clock:(Eio.Stdenv.clock env);
        run_through_the_runner argv
      | "unix" -> run_through_the_runner argv
      | other -> Printf.eprintf "unknown mode %s\n" other; exit 2)
  | _ -> prerr_endline "usage: process_group_terminal_stdin_fixture mgr|eio|unix argv..."; exit 2
