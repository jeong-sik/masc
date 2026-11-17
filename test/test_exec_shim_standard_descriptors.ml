(** A shim started with a standard descriptor closed does not run its
    payload (#52033).

    The shim reads its request from fd 0, writes payload output and the
    trailer to fds 1 and 2, and wires its payload with one dup2 per standard
    descriptor. A process whose standard descriptor was closed gets that
    number for its next pipe or file, and the payload then runs without the
    stream whose number its own pipe took. Each
    case closes standard descriptors, which would take the test runner's own
    output with it, so it runs in a fixture: this executable started again
    with [fixture_flag]. The fixture reports through files and its exit code
    only. *)

open Alcotest

let fixture_flag = "--standard-descriptor-fixture"

let shim = ref ""

let all_descriptors =
  [ Exec_shim.Standard_input; Exec_shim.Standard_output; Exec_shim.Standard_error ]

let name = function
  | Exec_shim.Standard_input -> "stdin"
  | Exec_shim.Standard_output -> "stdout"
  | Exec_shim.Standard_error -> "stderr"

let file_descr = function
  | Exec_shim.Standard_input -> Unix.stdin
  | Exec_shim.Standard_output -> Unix.stdout
  | Exec_shim.Standard_error -> Unix.stderr

(* ---- the fixture side ---- *)

type fixture_refusal =
  | Unknown_descriptor
  | Unknown_mode
  | Raised

let fixture_exit_code = function
  | Unknown_descriptor -> 90
  | Unknown_mode -> 91
  | Raised -> 92

exception Refused of fixture_refusal

let descriptors_named names =
  List.map
    (fun text ->
      match List.find_opt (fun d -> String.equal (name d) text) all_descriptors with
      | Some descriptor -> descriptor
      | None -> raise (Refused Unknown_descriptor))
    names

let close_all descriptors = List.iter (fun d -> Unix.close (file_descr d)) descriptors

(* The report file is opened while every standard descriptor is still open,
   so it cannot take a number the fixture is about to close. *)
let report_closed report_path names =
  let descriptors = descriptors_named names in
  let report = open_out_bin report_path in
  close_all descriptors;
  output_string report
    (String.concat " " (List.map name (Exec_shim.closed_standard_descriptors ())));
  close_out report

(* The fixture becomes the shim, so the fixture's exit code is the shim's. *)
let exec_shim shim_path names =
  close_all (descriptors_named names);
  Unix.execv shim_path [| shim_path |]

let fixture mode args =
  match mode, args with
  | "report", report_path :: names -> report_closed report_path names
  | "exec-shim", shim_path :: names -> exec_shim shim_path names
  | _, _ -> raise (Refused Unknown_mode)

let run_fixture mode args =
  let code =
    match fixture mode args with
    | () -> 0
    | exception Refused refusal -> fixture_exit_code refusal
    | exception _ -> fixture_exit_code Raised
  in
  Unix._exit code

(* ---- the test side ---- *)

let rec wait pid =
  try snd (Unix.waitpid [] pid) with
  | Unix.Unix_error (Unix.EINTR, _, _) -> wait pid

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun entry -> remove_tree (Filename.concat path entry)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_temp_dir f =
  let dir = Unix.realpath (Filename.temp_dir "masc-shim-standard-fd-" "") in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)

type fixture_stdin =
  | Null
  | Frame_held_open of string
      (** The frame in a pipe whose write end this process keeps until the
          fixture exits: the shim reads end of input on fd 0 as the host
          cancelling the run and kills the payload. *)

let rec write_all fd text offset =
  if offset < String.length text
  then
    write_all fd text
      (offset + Unix.write_substring fd text offset (String.length text - offset))

(* The fixture's stdout and stderr go to /dev/null: the shim's trailer is
   not what these cases read. *)
let fixture_exit ?(env = Unix.environment ()) ~stdin mode args =
  let argv = Array.of_list (Sys.executable_name :: fixture_flag :: mode :: args) in
  let null = Unix.openfile "/dev/null" [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
  let child_stdin, held =
    match stdin with
    | Null -> null, None
    | Frame_held_open frame ->
      let read_end, write_end = Unix.pipe ~cloexec:true () in
      write_all write_end frame 0;
      read_end, Some (read_end, write_end)
  in
  let release () =
    Unix.close null;
    Option.iter (fun (read_end, write_end) -> Unix.close read_end; Unix.close write_end) held
  in
  Fun.protect ~finally:release (fun () ->
    let pid = Unix.create_process_env Sys.executable_name argv env child_stdin null null in
    match wait pid with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED signal -> failf "fixture %s was signalled (%d)" mode signal
    | Unix.WSTOPPED signal -> failf "fixture %s stopped (%d)" mode signal)

let reported_closed closed () =
  with_temp_dir (fun dir ->
    let report = Filename.concat dir "report" in
    check int "fixture exit" 0
      (fixture_exit ~stdin:Null "report" (report :: List.map name closed));
    check (list string) "the closed descriptors, in descriptor order" (List.map name closed)
      (match In_channel.with_open_bin report In_channel.input_all with
       | "" -> []
       | text -> String.split_on_char ' ' text))

(* A shim config whose root is [dir], and one Effect request whose payload
   leaves [marker] in it. *)
let marker_request ~stdin dir =
  let config = Filename.concat dir "shim.conf" in
  Out_channel.with_open_bin config (fun channel ->
    Out_channel.output_string channel
      (Printf.sprintf "remote_root=%s\nscratch_root=%s\n" dir dir));
  Unix.chmod config 0o644;
  let request =
    Exec_ssh_protocol.
      { v = newest
      ; argv = [ "/bin/sh"; "-c"; ": > marker" ]
      ; env = []
      ; cwd = dir
      ; remote_root = dir
      ; timeout_sec = 60.0
      ; stdin
      ; mode = Effect
      ; acceptance_frame = false
      }
  in
  let frame =
    match Exec_ssh_protocol.encode_request request ~stdin:"" with
    | Ok frame -> frame
    | Error message -> fail message
  in
  let env =
    Array.append
      [| Printf.sprintf "%s=%s" Exec_ssh_protocol.shim_config_env_var config |]
      (Unix.environment ())
  in
  frame, env, Filename.concat dir "marker"

let shim_run ?(stdin = Exec_ssh_protocol.Framed 0L) closed =
  with_temp_dir (fun dir ->
    let frame, env, marker = marker_request ~stdin dir in
    let code =
      fixture_exit ~env ~stdin:(Frame_held_open frame) "exec-shim" (!shim :: List.map name closed)
    in
    code, Sys.file_exists marker)

let shim_refuses closed () =
  let code, payload_ran = shim_run closed in
  check bool "the payload did not run" false payload_ran;
  check int "the shim exits without running" Exec_shim.closed_standard_descriptor_exit_code code

let test_shim_runs_with_all_open () =
  let code, payload_ran = shim_run [] in
  check int "the shim exits after the payload's trailer" 0 code;
  check bool "the payload ran" true payload_ran

let test_interactive_preserves_standard_descriptor_refusal () =
  let code, payload_ran =
    shim_run ~stdin:Exec_ssh_protocol.Interactive [ Exec_shim.Standard_error ] in
  check bool "interactive input cannot bypass the closed descriptor refusal"
    false payload_ran;
  check int "the same refusal occurs before reading the interactive request"
    Exec_shim.closed_standard_descriptor_exit_code code

let test_interactive_runs_with_all_open () =
  let code, payload_ran = shim_run ~stdin:Exec_ssh_protocol.Interactive [] in
  check int "the interactive shim exits after the payload" 0 code;
  check bool "a payload may finish while the interactive transport is open" true payload_ran

let () =
  match Array.to_list Sys.argv with
  | _ :: flag :: mode :: args when String.equal flag fixture_flag -> run_fixture mode args
  | program :: shim_path :: rest ->
    shim := Unix.realpath shim_path;
    run ~argv:(Array.of_list (program :: rest)) "exec_shim_standard_descriptors"
      [ ( "closed_standard_descriptors"
        , [ test_case "a closed stderr is named" `Quick
              (reported_closed [ Exec_shim.Standard_error ])
          ; test_case "a closed stdout is named" `Quick
              (reported_closed [ Exec_shim.Standard_output ])
          ; test_case "closed stdin and stderr are both named" `Quick
              (reported_closed [ Exec_shim.Standard_input; Exec_shim.Standard_error ])
          ; test_case "nothing is named while all three are open" `Quick (reported_closed [])
          ] )
      ; ( "shim"
        , [ test_case "does not run the payload with stderr closed" `Quick
              (shim_refuses [ Exec_shim.Standard_error ])
          ; test_case "does not run the payload with stdout closed" `Quick
              (shim_refuses [ Exec_shim.Standard_output ])
          ; test_case "runs the payload with all three open" `Quick test_shim_runs_with_all_open
          ; test_case "interactive input preserves closed descriptor refusal" `Quick
              test_interactive_preserves_standard_descriptor_refusal
          ; test_case "interactive payload runs with all three open" `Quick
              test_interactive_runs_with_all_open
          ] )
      ]
  | _ -> failwith "usage: test_exec_shim_standard_descriptors.exe MASC_EXEC_SHIM [alcotest args]"
