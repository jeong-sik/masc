(* A voice command that never started, and the reason it is given.

   The process runner these commands used answers a program that is not there
   with exit 127, and answers every other failure before the process -- a
   permission denied, a working directory that would not open -- with the same
   127. The transport read 127 as "not installed". Measured 2026-09-13 through
   voice-verify: a whisper command pointed at a file with no execute bit was
   reported as "... is not installed", and reinstalling does not change that.

   Both cases here spawn for real, so what is checked is what the runner
   reports, not what a constructed value would say. *)

let endpoint command =
  { Voice_config.id = "whisper-local"
  ; kind = Voice_config.Whisper_cli
  ; base_url = None
  ; mcp_url = None
  ; health_url = None
  ; api_key_env = None
  ; enabled = true
  ; timeout_seconds = None
  ; default_voice = None
  ; command = Some command
  }

let with_temp_dir f =
  let dir = Filename.temp_file "masc-voice-refusal-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      Array.iter (fun name -> Sys.remove (Filename.concat dir name)) (Sys.readdir dir);
      Unix.rmdir dir)
    (fun () -> f dir)

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  go 0

let transcribe ~command =
  Voice_bridge_transport.transcribe_via_command
    (endpoint command)
    ~audio_file:"/nonexistent/utterance.wav"
    ~model:"/nonexistent/model.bin"

let with_process_runtime f =
  Eio_main.run
  @@ fun env ->
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  f ()

let test_a_command_that_is_not_there_is_not_installed () =
  with_process_runtime
  @@ fun () ->
  match transcribe ~command:"masc-test-no-such-transcriber" with
  | Ok transcript -> Alcotest.failf "a missing command answered %S" transcript
  | Error reason ->
    Alcotest.(check string)
      "named as not installed"
      "masc-test-no-such-transcriber is not installed"
      reason

let test_a_file_without_an_execute_bit_is_not_called_uninstalled () =
  with_process_runtime
  @@ fun () ->
  with_temp_dir
  @@ fun dir ->
  let path = Filename.concat dir "whisper-cli" in
  let channel = open_out path in
  output_string channel "#!/bin/sh\necho heard\n";
  close_out channel;
  (* No execute bit for anyone. execve refuses this even for root, so the case
     holds in a CI container that runs as root. *)
  Unix.chmod path 0o644;
  match transcribe ~command:path with
  | Ok transcript -> Alcotest.failf "a non-executable file answered %S" transcript
  | Error reason ->
    Alcotest.(check bool)
      (Printf.sprintf "not sent to reinstall what is there (%s)" reason)
      false
      (contains ~needle:"not installed" reason);
    Alcotest.(check bool)
      "says it could not start"
      true
      (contains ~needle:"could not start" reason);
    Alcotest.(check bool)
      "and keeps the runner's reason"
      true
      (contains ~needle:(Unix.error_message Unix.EACCES) reason)

let () =
  Alcotest.run
    "voice command refusal"
    [ ( "a command that did not start"
      , [ Alcotest.test_case "a command that is not there is not installed" `Quick
            test_a_command_that_is_not_there_is_not_installed
        ; Alcotest.test_case "a file without an execute bit is not called uninstalled"
            `Quick test_a_file_without_an_execute_bit_is_not_called_uninstalled
        ] )
    ]
