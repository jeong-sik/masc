(** A child's standard streams reach what the caller named, whatever numbers
    the caller's descriptors have (#47475).

    A process whose standard descriptors were closed gets 0, 1 or 2 for the
    next file or pipe it opens. Those numbers are also the targets of the
    child's wiring, so wiring done one step at a time can overwrite a source
    before reading it. Each case closes standard descriptors, which would
    take the test runner's own output with it, so it runs in a fixture: this
    executable started again with [fixture_flag]. The fixture reports through
    files and its exit code only. *)

open Alcotest

let fixture_flag = "--descriptor-fixture"

type fixture_refusal =
  | Number_not_reused
  | Spawn_refused
  | Child_failed
  | Raised
  | Unknown_mode

let exit_code = function
  | Number_not_reused -> 90
  | Spawn_refused -> 91
  | Child_failed -> 92
  | Raised -> 93
  | Unknown_mode -> 94

exception Refused of fixture_refusal

let shell script = [ "/bin/sh"; "-c"; script ]

let rec wait pid =
  try snd (Unix.waitpid [] pid) with
  | Unix.Unix_error (Unix.EINTR, _, _) -> wait pid

let require_exit_zero = function
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> raise (Refused Child_failed)

(* Opens [path] and insists it landed on [number], the descriptor the
   fixture has just closed. *)
let open_on number path =
  let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC; Unix.O_CLOEXEC ] 0o600 in
  if fd <> number then raise (Refused Number_not_reused);
  fd

let open_null () = Unix.openfile "/dev/null" [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0

let run_foreground ~stdin ~stdout ~stderr script =
  let owner = Unix_foreground_process.create () in
  Fun.protect ~finally:(fun () -> Unix_foreground_process.close owner) (fun () ->
    Unix_foreground_process.spawn owner "/bin/sh" (shell script) (Unix.environment ())
      stdin stdout stderr;
    let deadline = Monotonic_deadline.after ~seconds:60. in
    let rec await_exit () =
      match Unix_foreground_process.poll owner with
      | Some status -> status
      | None ->
        if Monotonic_deadline.passed deadline then raise (Refused Child_failed);
        (try ignore (Unix.select [] [] [] 0.01) with
         | Unix.Unix_error (Unix.EINTR, _, _) -> ());
        await_exit ()
    in
    require_exit_zero (await_exit ()))

(* The issue's own case: the output file holds fd 0, and the mapping for
   child fd 0 comes first. *)
let foreground_closed_stdin output_path =
  Unix.close Unix.stdin;
  let output = open_on Unix.stdin output_path in
  let null = open_null () in
  run_foreground ~stdin:null ~stdout:output ~stderr:null "printf RGB"

(* Each stream's source is the other stream's target. *)
let foreground_swapped ~stdout_path ~stderr_path =
  Unix.close Unix.stdout;
  Unix.close Unix.stderr;
  let on_one = open_on Unix.stdout stderr_path in
  let on_two = open_on Unix.stderr stdout_path in
  let null = open_null () in
  run_foreground ~stdin:null ~stdout:on_two ~stderr:on_one "printf OUT; printf ERR >&2"

let posix_spawn_detached_closed_stdin output_path =
  Unix.close Unix.stdin;
  let output = open_on Unix.stdin output_path in
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      match
        Posix_spawn_detached.spawn ~sw ~argv:(shell "printf RGB") ~env:(Unix.environment ())
          ~output
      with
      | Error _ -> raise (Refused Spawn_refused)
      | Ok child ->
        (match Eio.Promise.await child.Posix_spawn_detached.exited with
         | Some status -> require_exit_zero status
         | None -> raise (Refused Child_failed))))

let forked_quiet_closed_stdin output_path =
  Unix.close Unix.stdin;
  let output = open_on Unix.stdin output_path in
  match
    Process_eio_detached.spawn_detached_writing_to ~argv:(shell "printf RGB")
      ~env:(Unix.environment ()) ~cwd:"" ~output
  with
  | Error _ -> raise (Refused Spawn_refused)
  | Ok handle -> require_exit_zero (wait handle.Process_eio_detached.devnull_pid)

let read_all fd =
  let buffer = Buffer.create 16 in
  let chunk = Bytes.create 256 in
  let rec loop () =
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> Buffer.contents buffer
    | count -> Buffer.add_subbytes buffer chunk 0 count; loop ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
  in
  loop ()

(* With all three closed, the capture pipes themselves take 0, 1 and 2. *)
let forked_pipes_closed_standard report_path =
  let report = open_out_bin report_path in
  Unix.close Unix.stdin;
  Unix.close Unix.stdout;
  Unix.close Unix.stderr;
  match
    Process_eio_detached.spawn_detached ~argv:(shell "printf OUT; printf ERR >&2")
      ~env:(Unix.environment ()) ~cwd:""
  with
  | Error _ -> raise (Refused Spawn_refused)
  | Ok handle ->
    let out = read_all handle.Process_eio_detached.stdout_fd in
    let err = read_all handle.Process_eio_detached.stderr_fd in
    let exited =
      match wait handle.Process_eio_detached.pid with
      | Unix.WEXITED code -> code
      | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> -1
    in
    Printf.fprintf report "stdout=%s stderr=%s exit=%d" out err exited;
    close_out report

let fixture mode paths =
  match mode, paths with
  | "foreground-closed-stdin", [ output ] -> foreground_closed_stdin output
  | "foreground-swapped", [ stdout_path; stderr_path ] ->
    foreground_swapped ~stdout_path ~stderr_path
  | "posix-spawn-detached-closed-stdin", [ output ] -> posix_spawn_detached_closed_stdin output
  | "forked-quiet-closed-stdin", [ output ] -> forked_quiet_closed_stdin output
  | "forked-pipes-closed-standard", [ report ] -> forked_pipes_closed_standard report
  | _, _ -> raise (Refused Unknown_mode)

let run_fixture mode paths =
  let code =
    match fixture mode paths with
    | () -> 0
    | exception Refused refusal -> exit_code refusal
    | exception _ -> exit_code Raised
  in
  Unix._exit code

(* ---- the test side ---- *)

let read_file path = In_channel.with_open_bin path In_channel.input_all

let with_temp_files count f =
  let paths = List.init count (fun _ -> Filename.temp_file "masc-spawn-fd" ".out") in
  Fun.protect
    ~finally:(fun () -> List.iter (fun path -> try Sys.remove path with Sys_error _ -> ()) paths)
    (fun () -> f paths)

let fixture_exit mode paths =
  let argv = Array.of_list (Sys.executable_name :: fixture_flag :: mode :: paths) in
  let pid = Unix.create_process Sys.executable_name argv Unix.stdin Unix.stdout Unix.stderr in
  match wait pid with
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED signal -> failf "fixture %s was signalled (%d)" mode signal
  | Unix.WSTOPPED signal -> failf "fixture %s stopped (%d)" mode signal

let single_output mode () =
  with_temp_files 1 (fun paths ->
    check int "fixture exit" 0 (fixture_exit mode paths);
    check string "the child's stdout reached the named file" "RGB" (read_file (List.hd paths)))

let test_foreground_swapped () =
  with_temp_files 2 (fun paths ->
    check int "fixture exit" 0 (fixture_exit "foreground-swapped" paths);
    check (list string) "stdout file, stderr file" [ "OUT"; "ERR" ] (List.map read_file paths))

let test_forked_pipes_closed_standard () =
  with_temp_files 1 (fun paths ->
    check int "fixture exit" 0 (fixture_exit "forked-pipes-closed-standard" paths);
    check string "both pipes carried their own stream" "stdout=OUT stderr=ERR exit=0"
      (read_file (List.hd paths)))

let () =
  match Array.to_list Sys.argv with
  | _ :: flag :: mode :: paths when String.equal flag fixture_flag -> run_fixture mode paths
  | _ ->
    run "spawn_descriptor_mapping"
      [ ( "posix_spawn"
        , [ test_case "foreground: output file on a closed fd 0" `Quick
              (single_output "foreground-closed-stdin")
          ; test_case "foreground: stdout and stderr swapped" `Quick test_foreground_swapped
          ; test_case "detached: output file on a closed fd 0" `Quick
              (single_output "posix-spawn-detached-closed-stdin")
          ] )
      ; ( "fork"
        , [ test_case "quiet: output file on a closed fd 0" `Quick
              (single_output "forked-quiet-closed-stdin")
          ; test_case "pipes: all three standard descriptors closed" `Quick
              test_forked_pipes_closed_standard
          ] )
      ]
