open Alcotest

type http_result = {
  status: int option;
  body: string;
  curl_exit: int;
  stderr: string;
}

let read_all ic =
  let buf = Buffer.create 1024 in
  (try
     while true do
       Buffer.add_channel buf ic 4096
     done
   with End_of_file -> ());
  Buffer.contents buf

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let len = in_channel_length ic in
      really_input_string ic len)

let trim_cr s =
  let n = String.length s in
  if n > 0 && s.[n - 1] = '\r' then String.sub s 0 (n - 1) else s

let parse_status header_raw =
  let lines = String.split_on_char '\n' header_raw |> List.map trim_cr in
  let rec find_http = function
    | [] -> None
    | line :: rest ->
        if String.length line >= 5 && String.sub line 0 5 = "HTTP/" then
          (match String.split_on_char ' ' line with
          | _proto :: code :: _ -> (try Some (int_of_string code) with _ -> None)
          | _ -> None)
        else
          find_http rest
  in
  find_http lines

let run_curl ~port ~path ?body ~method_name () =
  let header_file = Filename.temp_file "trpg-actor-api-header-" ".txt" in
  let body_file = Filename.temp_file "trpg-actor-api-body-" ".txt" in
  let url = Printf.sprintf "http://127.0.0.1:%d%s" port path in
  let args =
    [
      "curl";
      "-sS";
      "--http1.1";
      "--max-time";
      "3";
      "-X";
      method_name;
      "-o";
      body_file;
      "-D";
      header_file;
    ]
    @
    ((match body with
     | Some payload -> [ "-H"; "Content-Type: application/json"; "--data"; payload ]
     | None -> [])
    @ [ url ])
  in
  let (ic, oc, ec) =
    Unix.open_process_args_full "curl" (Array.of_list args) (Unix.environment ())
  in
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
  (try Sys.remove header_file with _ -> ());
  (try Sys.remove body_file with _ -> ());
  { status; body; curl_exit; stderr }

let contains_substr needle haystack =
  let n = String.length needle in
  let h = String.length haystack in
  let rec loop i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else loop (i + 1)
  in
  n = 0 || loop 0

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
        [
          "./bin/main_eio.exe";
          "../bin/main_eio.exe";
          "../../bin/main_eio.exe";
          "../../../bin/main_eio.exe";
          "../../../../bin/main_eio.exe";
        ]
        @ build_candidates
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None ->
      fail
        "main_eio executable not found. Set MASC_MAIN_EIO_EXE or build with `dune build bin/main_eio.exe`."

let find_free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.setsockopt socket Unix.SO_REUSEADDR true;
      match Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)) with
      | () -> (
          match Unix.getsockname socket with
          | Unix.ADDR_INET (_, port) -> Some port
          | _ -> fail "unexpected socket address")
      | exception Unix.Unix_error ((Unix.EPERM | Unix.EACCES), "bind", _) -> None)

let wait_for_health ~port ~timeout_s =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    if Unix.gettimeofday () > deadline then false
    else
      let res = run_curl ~port ~path:"/health" ~method_name:"GET" () in
      match res.status with
      | Some 200 -> true
      | _ ->
          Unix.sleepf 0.1;
          loop ()
  in
  loop ()

let wait_pid_exit ~pid ~timeout_s =
  let deadline = Unix.gettimeofday () +. timeout_s in
  let rec loop () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
        if Unix.gettimeofday () > deadline then false
        else (
          Unix.sleepf 0.05;
          loop ())
    | _pid, _status -> true
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> true
  in
  loop ()

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
    Unix.environment () |> Array.to_list
    |> List.filter (fun entry -> not (is_override_key entry))
  in
  let injected = List.map (fun (k, v) -> k ^ "=" ^ v) overrides in
  Array.of_list (base @ injected)

let with_server f =
  let exe = find_main_eio_exe () in
  let port =
    match find_free_port () with
    | Some p -> p
    | None -> Alcotest.skip ()
  in
  let log_file = Filename.temp_file "trpg-actor-api-e2e-" ".log" in
  let base_path = Filename.temp_file "trpg-actor-api-base-" "" in
  (try Sys.remove base_path with _ -> ());
  Unix.mkdir base_path 0o755;
  let log_fd =
    Unix.openfile log_file [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ] 0o644
  in
  let env =
    merge_env_overrides
      [
        ("MASC_LODGE_ENABLED", "0");
        ("MASC_LODGE_DAEMON_ENABLED", "0");
        ("GRAPHQL_API_KEY", "");
        ("GRAPHQL_URL", "http://127.0.0.1:9/graphql");
      ]
  in
  let argv =
    [| exe; "--port"; string_of_int port; "--base-path"; base_path |]
  in
  let pid = Unix.create_process_env exe argv env Unix.stdin log_fd log_fd in
  Unix.close log_fd;
  let cleanup () =
    (try Unix.kill pid Sys.sigterm with _ -> ());
    if not (wait_pid_exit ~pid ~timeout_s:2.0) then
      (try Unix.kill pid Sys.sigkill with _ -> ());
    ignore (wait_pid_exit ~pid ~timeout_s:1.0)
  in
  if not (wait_for_health ~port ~timeout_s:20.0) then (
    cleanup ();
    let logs = read_file log_file in
    fail (Printf.sprintf "server failed to become ready on port %d\n%s" port logs));
  Fun.protect ~finally:cleanup (fun () -> f ~port)

let expect_status expected res label =
  match res.status with
  | Some code -> check int label expected code
  | None ->
      fail
        (Printf.sprintf
           "missing HTTP status (curl_exit=%d, stderr=%s)"
           res.curl_exit res.stderr)

let test_spawn_auto_actor_id_and_profile_fields () =
  with_server @@ fun ~port ->
  let spawn_auto =
    run_curl ~port ~path:"/api/v1/trpg/actors/spawn" ~method_name:"POST"
      ~body:(Yojson.Safe.to_string (`Assoc [ ("room_id", `String "room-api-auto") ]))
      ()
  in
  expect_status 201 spawn_auto "spawn auto returns 201";
  let auto_json = Yojson.Safe.from_string spawn_auto.body in
  let auto_actor_id = auto_json |> Yojson.Safe.Util.member "actor_id" |> Yojson.Safe.Util.to_string in
  check string "auto actor_id defaults to player seed" "player" auto_actor_id;
  check bool "state has auto actor_id" true
    ((auto_json |> Yojson.Safe.Util.member "state" |> Yojson.Safe.Util.member "party"
    |> Yojson.Safe.Util.member auto_actor_id)
    <> `Null);

  let spawn_profile_body =
    `Assoc
      [
        ("room_id", `String "room-api-profile");
        ("name", `String "Night Fox");
        ("role", `String "npc");
        ("portrait", `String "https://example.com/night-fox.png");
        ("background", `String "폐허 수색 전문가");
        ("stats", `Assoc [ ("dex", `Int 16); ("luck", `Int 7) ]);
        ("hp", `Int 18);
        ("max_hp", `Int 24);
      ]
  in
  let spawn_profile =
    run_curl ~port ~path:"/api/v1/trpg/actors/spawn" ~method_name:"POST"
      ~body:(Yojson.Safe.to_string spawn_profile_body) ()
  in
  expect_status 201 spawn_profile "spawn profile returns 201";
  let profile_json = Yojson.Safe.from_string spawn_profile.body in
  let actor_id = profile_json |> Yojson.Safe.Util.member "actor_id" |> Yojson.Safe.Util.to_string in
  let actor_state =
    profile_json |> Yojson.Safe.Util.member "state" |> Yojson.Safe.Util.member "party"
    |> Yojson.Safe.Util.member actor_id
  in
  check string "name preserved" "Night Fox"
    (actor_state |> Yojson.Safe.Util.member "name" |> Yojson.Safe.Util.to_string);
  check string "portrait preserved" "https://example.com/night-fox.png"
    (actor_state |> Yojson.Safe.Util.member "portrait" |> Yojson.Safe.Util.to_string);
  check string "background preserved" "폐허 수색 전문가"
    (actor_state |> Yojson.Safe.Util.member "background" |> Yojson.Safe.Util.to_string);
  check int "stats.dex preserved" 16
    (actor_state |> Yojson.Safe.Util.member "stats" |> Yojson.Safe.Util.member "dex"
   |> Yojson.Safe.Util.to_int);
  check int "stats.luck preserved" 7
    (actor_state |> Yojson.Safe.Util.member "stats" |> Yojson.Safe.Util.member "luck"
   |> Yojson.Safe.Util.to_int)

let test_spawn_validation_errors () =
  with_server @@ fun ~port ->
  let bad_stats =
    run_curl ~port ~path:"/api/v1/trpg/actors/spawn" ~method_name:"POST"
      ~body:
        (Yojson.Safe.to_string
           (`Assoc
             [
               ("room_id", `String "room-api-invalid");
               ("name", `String "Broken");
               ("stats", `String "oops");
             ]))
      ()
  in
  expect_status 400 bad_stats "stats type error returns 400";
  check bool "stats type error message" true
    (contains_substr "stats must be object" bad_stats.body);

  let bad_hp =
    run_curl ~port ~path:"/api/v1/trpg/actors/spawn" ~method_name:"POST"
      ~body:
        (Yojson.Safe.to_string
           (`Assoc
             [
               ("room_id", `String "room-api-invalid");
               ("name", `String "Broken");
               ("hp", `Int (-1));
             ]))
      ()
  in
  expect_status 400 bad_hp "negative hp returns 400";
  check bool "negative hp message" true
    (contains_substr "hp must be >= 0" bad_hp.body);

  let bad_max_hp =
    run_curl ~port ~path:"/api/v1/trpg/actors/spawn" ~method_name:"POST"
      ~body:
        (Yojson.Safe.to_string
           (`Assoc
             [
               ("room_id", `String "room-api-invalid");
               ("name", `String "Broken");
               ("max_hp", `Int 0);
             ]))
      ()
  in
  expect_status 400 bad_max_hp "zero max_hp returns 400";
  check bool "zero max_hp message" true
    (contains_substr "max_hp must be > 0" bad_max_hp.body)

let () =
  run "trpg_actor_api_e2e"
    [
      ( "trpg_actor_api",
        [
          test_case
            "spawn auto id and profile fields"
            `Slow
            test_spawn_auto_actor_id_and_profile_fields;
          test_case "spawn validation errors" `Slow test_spawn_validation_errors;
        ] );
    ]
