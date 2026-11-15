(* #51246: [masc start] with a log directory it cannot open ends as a refused
   boot: exit 1 and one [FATAL] sentence naming the directory. It used to end
   through the command line parser: exit 125 and a backtrace. *)

let binary_env_key = "MASC_START_BINARY"

(* Test-hang backstop only: a server that opened its sink would keep running. *)
let exit_backstop_s = 120.0
let poll_interval_s = 0.05

let binary () =
  match Sys.getenv_opt binary_env_key with
  | None -> Alcotest.failf "%s is not set" binary_env_key
  | Some path when Filename.is_relative path -> Filename.concat (Sys.getcwd ()) path
  | Some path -> path
;;

let contains ~needle haystack =
  let n = String.length needle in
  let rec at i =
    i + n <= String.length haystack
    && (String.equal (String.sub haystack i n) needle || at (i + 1))
  in
  at 0
;;

let unused_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname socket with
      | Unix.ADDR_INET (_, port) -> port
      | Unix.ADDR_UNIX path -> Alcotest.failf "loopback socket bound to %s" path)
;;

let rec await_exit ~deadline pid =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | 0, _ ->
    if Unix.gettimeofday () > deadline
    then (
      Unix.kill pid Sys.sigkill;
      ignore (Unix.waitpid [] pid);
      Alcotest.fail "masc start kept running with a log directory it cannot open")
    else (
      Unix.sleepf poll_interval_s;
      await_exit ~deadline pid)
  | _, status -> status
;;

let start ~root ~base =
  let home = Filename.concat root "home" in
  Unix.mkdir home 0o700;
  let stderr_path = Filename.concat root "stderr" in
  let input = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  let output = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  let errors =
    Unix.openfile stderr_path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
  in
  let executable = binary () in
  let pid =
    Fun.protect
      ~finally:(fun () -> List.iter Unix.close [ input; output; errors ])
      (fun () ->
        Unix.create_process_env
          executable
          [| executable
           ; "start"
           ; "--base-path"
           ; base
           ; "--port"
           ; string_of_int (unused_port ())
           ; "--host"
           ; "127.0.0.1"
          |]
          [| "HOME=" ^ home; "TMPDIR=" ^ root; "PATH=/usr/bin:/bin" |]
          input
          output
          errors)
  in
  let status = await_exit ~deadline:(Unix.gettimeofday () +. exit_backstop_s) pid in
  status, In_channel.with_open_bin stderr_path In_channel.input_all
;;

let test_file_in_place_of_log_directory () =
  let root = Filename.temp_dir "masc-start-log-dir-" "" in
  let base = Filename.concat root "base" in
  let masc_dir = Filename.concat base ".masc" in
  Unix.mkdir base 0o700;
  Unix.mkdir masc_dir 0o700;
  let log_dir = Filename.concat masc_dir "logs" in
  Out_channel.with_open_bin log_dir (fun _ -> ());
  let status, stderr_text = start ~root ~base in
  (match status with
   | Unix.WEXITED code -> Alcotest.(check int) "exit code of a refused boot" 1 code
   | Unix.WSIGNALED signal -> Alcotest.failf "killed by signal %d:\n%s" signal stderr_text
   | Unix.WSTOPPED signal -> Alcotest.failf "stopped by signal %d:\n%s" signal stderr_text);
  let fatal_lines =
    String.split_on_char '\n' stderr_text
    |> List.filter (fun line -> contains ~needle:"[FATAL]" line)
  in
  (match fatal_lines with
   | [ line ] ->
     (* The server canonicalizes the base path, so compare from [.masc] on. *)
     Alcotest.(check bool)
       ("the sentence names the log directory: " ^ line)
       true
       (contains ~needle:(Filename.concat ".masc" "logs") line);
     Alcotest.(check bool)
       ("the sentence carries the OS cause: " ^ line)
       true
       (contains ~needle:(Unix.error_message Unix.ENOTDIR) line)
   | [] | _ :: _ :: _ ->
     Alcotest.failf "expected one [FATAL] line, got %d:\n%s"
       (List.length fatal_lines) stderr_text);
  Alcotest.(check bool)
    "no exception reaches the command line parser"
    false
    (contains ~needle:"uncaught exception" stderr_text)
;;

let () =
  Alcotest.run
    "start_log_dir_refusal"
    [ ( "masc start"
      , [ Alcotest.test_case
            "a file in place of the log directory refuses the boot"
            `Quick
            test_file_in_place_of_log_directory
        ] )
    ]
;;
