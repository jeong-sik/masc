open Alcotest

type http_result =
  { status : int option
  ; body : string
  ; curl_exit : int
  ; stderr : string
  }

let read_all ic =
  let buf = Buffer.create 1024 in
  (try
     while true do
       Buffer.add_channel buf ic 4096
     done
   with
   | End_of_file -> ());
  Buffer.contents buf
;;

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let len = in_channel_length ic in
       really_input_string ic len)
;;

let trim_cr s =
  let n = String.length s in
  if n > 0 && s.[n - 1] = '\r' then String.sub s 0 (n - 1) else s
;;

let parse_status header_raw =
  let lines = String.split_on_char '\n' header_raw |> List.map trim_cr in
  let rec find_http = function
    | [] -> None
    | line :: rest ->
      if String.length line >= 5 && String.sub line 0 5 = "HTTP/"
      then (
        match String.split_on_char ' ' line with
        | _proto :: code :: _ ->
          (try Some (int_of_string code) with
           | _ -> None)
        | _ -> None)
      else find_http rest
  in
  find_http lines
;;

let run_curl ~port ~path () =
  let header_file = Filename.temp_file "board-api-header-" ".txt" in
  let body_file = Filename.temp_file "board-api-body-" ".txt" in
  let url = Printf.sprintf "http://127.0.0.1:%d%s" port path in
  let args =
    [| "curl"
     ; "-sS"
     ; "--http1.1"
     ; "--max-time"
     ; "3"
     ; "-X"
     ; "GET"
     ; "-o"
     ; body_file
     ; "-D"
     ; header_file
     ; url
    |]
  in
  let ic, oc, ec = Unix.open_process_args_full "curl" args (Unix.environment ()) in
  close_out_noerr oc;
  let _stdout = read_all ic in
  let stderr = read_all ec in
  let curl_exit =
    match Unix.close_process_full (ic, oc, ec) with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED code -> 128 + code
    | Unix.WSTOPPED code -> 256 + code
  in
  let status = parse_status (read_file header_file) in
  let body = read_file body_file in
  (try Sys.remove header_file with
   | _ -> ());
  (try Sys.remove body_file with
   | _ -> ());
  { status; body; curl_exit; stderr }
;;

let contains_substr needle haystack =
  let n = String.length needle in
  let h = String.length haystack in
  let rec loop i =
    if i + n > h
    then false
    else if String.sub haystack i n = needle
    then true
    else loop (i + 1)
  in
  n = 0 || loop 0
;;

let find_main_eio_exe () =
  let env_override = Sys.getenv_opt "MASC_MAIN_EIO_EXE" in
  let candidates =
    match env_override with
    | Some p -> [ p ]
    | None ->
      let build_roots = [ "."; ".."; "../.."; "../../.."; "../../../.." ] in
      let build_candidates =
        List.map
          (fun root -> Filename.concat root "_build/default/bin/main_eio.exe")
          build_roots
      in
      [ "./bin/main_eio.exe"
      ; "../bin/main_eio.exe"
      ; "../../bin/main_eio.exe"
      ; "../../../bin/main_eio.exe"
      ; "../../../../bin/main_eio.exe"
      ]
      @ build_candidates
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None ->
    fail
      "main_eio executable not found. Set MASC_MAIN_EIO_EXE or build with `dune build \
       bin/main_eio.exe`."
;;

let find_free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
       Unix.setsockopt socket Unix.SO_REUSEADDR true;
       match Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) with
       | () ->
         (match Unix.getsockname socket with
          | Unix.ADDR_INET (_, port) -> Some port
          | _ -> fail "unexpected socket address")
       | exception Unix.Unix_error ((Unix.EPERM | Unix.EACCES), "bind", _) -> None)
;;

let wait_for_health ~port ~timeout_s =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    if Unix.gettimeofday () > deadline
    then false
    else (
      let res = run_curl ~port ~path:"/health" () in
      match res.status with
      | Some 200 when contains_substr "\"state_ready\":true" res.body -> true
      | _ ->
        Unix.sleepf 0.1;
        loop ())
  in
  loop ()
;;

let wait_pid_exit ~pid ~timeout_s =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
      if Unix.gettimeofday () > deadline
      then false
      else (
        Unix.sleepf 0.05;
        loop ())
    | _pid, _status -> true
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> true
  in
  loop ()
;;

let merge_env_overrides overrides =
  let override_keys = List.map fst overrides in
  let is_override_key entry =
    match String.index_opt entry '=' with
    | None -> false
    | Some idx ->
      let key = String.sub entry 0 idx in
      List.mem key override_keys
  in
  let base =
    Unix.environment ()
    |> Array.to_list
    |> List.filter (fun entry -> not (is_override_key entry))
  in
  let injected = List.map (fun (k, v) -> k ^ "=" ^ v) overrides in
  Array.of_list (base @ injected)
;;

let with_server f =
  let exe = find_main_eio_exe () in
  let port =
    match find_free_port () with
    | Some p -> p
    | None -> Alcotest.skip ()
  in
  let log_file = Filename.temp_file "board-api-e2e-" ".log" in
  let base_path = Filename.temp_file "board-api-base-" "" in
  (try Sys.remove base_path with
   | _ -> ());
  Unix.mkdir base_path 0o755;
  let log_fd =
    Unix.openfile log_file [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ] 0o644
  in
  let env =
    merge_env_overrides
      [ "MASC_AUTONOMY_ENABLED", "0"
      ; "GRAPHQL_API_KEY", ""
      ; "GRAPHQL_URL", "http://127.0.0.1:9/graphql"
      ; "MASC_POSTGRES_URL", ""
      ; "DATABASE_URL", ""
      ; "SUPABASE_DB_URL", ""
      ; "SB_PG_URL", ""
      ; "MASC_BOARD_BACKEND", "jsonl"
      ]
  in
  let argv = [| exe; "--port"; string_of_int port; "--base-path"; base_path |] in
  let pid = Unix.create_process_env exe argv env Unix.stdin log_fd log_fd in
  Unix.close log_fd;
  let cleanup () =
    (try Unix.kill pid Sys.sigterm with
     | _ -> ());
    if not (wait_pid_exit ~pid ~timeout_s:2.0)
    then (
      try Unix.kill pid Sys.sigkill with
      | _ -> ());
    ignore (wait_pid_exit ~pid ~timeout_s:1.0)
  in
  if not (wait_for_health ~port ~timeout_s:20.0)
  then (
    cleanup ();
    let logs = read_file log_file in
    fail (Printf.sprintf "server failed to become ready on port %d\n%s" port logs));
  Fun.protect ~finally:cleanup (fun () -> f ~port)
;;

let test_board_missing_post_returns_404 () =
  with_server
  @@ fun ~port ->
  let rec get_until_ready retries_left =
    let res = run_curl ~port ~path:"/api/v1/board/post-not-exists-12345" () in
    match res.status, retries_left with
    | Some 503, retries
      when retries > 0 && contains_substr "Server is starting up, not ready yet" res.body
      ->
      Unix.sleepf 0.5;
      get_until_ready (retries - 1)
    | None, retries when retries > 0 && res.curl_exit = 28 ->
      Unix.sleepf 0.5;
      get_until_ready (retries - 1)
    | _ -> res
  in
  let res = get_until_ready 40 in
  (match res.status with
   | Some code -> check int "missing post returns 404" 404 code
   | None ->
     fail
       (Printf.sprintf
          "missing HTTP status (curl_exit=%d, stderr=%s)"
          res.curl_exit
          res.stderr));
  check
    bool
    "error payload contains message"
    true
    (contains_substr "Post not found" res.body)
;;

let () =
  run
    "board_api_e2e"
    [ ( "board"
      , [ test_case "missing post returns 404" `Slow test_board_missing_post_returns_404 ]
      )
    ]
;;
