(* One executable in three roles, driven by test_start_supervisor_terminal.py.

   [supervise BASE PORT] does what [masc start] does: it asks
   Masc_server_lifecycle whether it has a controlling terminal and, if so,
   supervises a server started with Masc_server_lifecycle.start. That server
   is this executable again, in the [start] role, because start runs
   [<masc_bin> start ...].

   [start ...] stands in for the server. It says whether it has a terminal,
   lets a child read /dev/tty as a Keeper's login prompt did on 2026-09-24,
   then writes lines until SIGTERM and exits with [server_exit_code].

   [serve-here] runs the same server role without detaching it: the start
   that #38700 reported, kept as the control. *)

let server_exit_code = 7

(* What a child that reads the terminal says. Without a controlling terminal
   the redirection fails and the shell goes on; with one, from a background
   group, the read stops the whole group. *)
let read_terminal =
  "if IFS= read -r line < /dev/tty; then echo 'server child: read the terminal'; \
   else echo 'server child: no terminal'; fi"

let line_bytes = 1024
let line_interval_s = 0.02

let say text =
  print_string text;
  print_char '\n';
  flush stdout

(* The handler only records the signal; the write loop answers it, so the
   handler never writes to a channel the loop may be holding. *)
let terminated = Atomic.make false

let serve () =
  Sys.set_signal Sys.sigterm (Sys.Signal_handle (fun (_ : int) -> Atomic.set terminated true));
  say (Printf.sprintf "server pid %d" (Unix.getpid ()));
  (match Unix.openfile "/dev/tty" [ Unix.O_RDONLY; Unix.O_NOCTTY ] 0 with
   | fd ->
     Unix.close fd;
     say "server terminal: present"
   | exception Unix.Unix_error (error, _, _) ->
     say ("server terminal: none (" ^ Unix.error_message error ^ ")"));
  let child =
    Unix.create_process "/bin/sh" [| "/bin/sh"; "-c"; read_terminal |] Unix.stdin Unix.stdout
      Unix.stderr
  in
  let rec wait_child () =
    try snd (Unix.waitpid [] child)
    with Unix.Unix_error (Unix.EINTR, _, _) -> wait_child ()
  in
  (match wait_child () with
   | Unix.WEXITED 0 -> ()
   | status -> say ("server child ended: " ^ Process_exit_text.of_status status));
  say "server ready";
  let filler = String.make line_bytes 'x' in
  let rec write_lines n =
    if Atomic.get terminated then (
      say "server got SIGTERM";
      exit server_exit_code);
    say (Printf.sprintf "server line %d %s" n filler);
    Unix.sleepf line_interval_s;
    write_lines (n + 1)
  in
  write_lines 0

let supervise base_path port =
  match Masc_server_lifecycle.controlling_terminal () with
  | Masc_server_lifecycle.No_controlling_terminal ->
    say "no terminal: serving here";
    exit 0
  | Masc_server_lifecycle.Controlling_terminal -> (
    say "supervising";
    match
      Masc_server_lifecycle.supervise ~masc_bin:Sys.executable_name ~flags:[] ~base_path
        ~host:"127.0.0.1" ~port ~env:(Unix.environment ()) ~into:Unix.stdout
        ~notices:Unix.stderr
    with
    | Ok ended -> exit (Masc_server_lifecycle.exit_code ended)
    | Error message ->
      prerr_endline ("supervise refused: " ^ message);
      exit 2)

let () =
  match Array.to_list Sys.argv with
  | _ :: "supervise" :: base_path :: port :: [] -> (
    match int_of_string_opt port with
    | Some port -> supervise base_path port
    | None ->
      prerr_endline ("not a port: " ^ port);
      exit 2)
  | _ :: "start" :: (_ : string list) | _ :: "serve-here" :: [] -> serve ()
  | _ ->
    prerr_endline "usage: start_supervisor_terminal_fixture supervise BASE PORT | serve-here";
    exit 2
