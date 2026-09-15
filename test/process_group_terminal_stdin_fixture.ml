(* Runs argv through masc's capturing process runner and prints how the child
   ended. [eio] initialises the Eio process layer first; [unix] leaves it
   uninitialised so the runner takes its Unix fallback. Both place the child in
   its own process group. test_process_group_terminal_stdin.py starts this
   under a pseudo-terminal. *)
let () =
  match Array.to_list Sys.argv with
  | _ :: mode :: (_ :: _ as argv) ->
    Eio_main.run (fun env ->
      (match mode with
       | "eio" ->
         Process_eio.init
           ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
           ~proc_mgr:(Eio.Stdenv.process_mgr env)
           ~clock:(Eio.Stdenv.clock env)
       | "unix" -> ()
       | other -> Printf.eprintf "unknown mode %s\n" other; exit 2);
      match Process_eio.run_argv_with_status_split_or_refusal argv with
      | Ok (Unix.WEXITED code, stdout, _) -> Printf.printf "exited %d %s\n%!" code (String.trim stdout)
      | Ok (Unix.WSIGNALED signal, _, _) -> Printf.printf "signaled %d\n%!" signal
      | Ok (Unix.WSTOPPED signal, _, _) -> Printf.printf "stopped %d\n%!" signal
      | Error refusal ->
        Printf.printf "refused %s\n%!" (Process_eio.spawn_refusal_to_string refusal))
  | _ -> prerr_endline "usage: process_group_terminal_stdin_fixture eio|unix argv..."; exit 2
