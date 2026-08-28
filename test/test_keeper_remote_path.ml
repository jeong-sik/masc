open Alcotest
open Masc

let endpoint : Exec_ssh_endpoint.t =
  { name = "build-box"
  ; host = "builder.local"
  ; user = "masc"
  ; port = 22
  ; identity_file = ".masc/ssh/build-box.key"
  ; known_hosts_file = ".masc/ssh/known_hosts.d/build-box"
  ; remote_root = "/srv/masc/playground"
  ; connect_timeout_sec = 10
  ; max_concurrent_sessions = 8
  ; env_allowlist = []
  ; capabilities = []
  }
;;

let base_path = "/workspace"
let host_file = "/workspace/.masc/playground/keeper-a/src/main.ml"
let remote_file = "/srv/masc/playground/keeper-a/src/main.ml"

let test_host_to_remote () =
  check (result string string) "absolute host path" (Ok remote_file)
    (Keeper_remote_path.host_to_remote ~base_path ~endpoint ~keeper:"keeper-a"
       host_file);
  check (result string string) "relative logical path" (Ok remote_file)
    (Keeper_remote_path.host_to_remote ~base_path ~endpoint ~keeper:"keeper-a"
       "src/main.ml")
;;

let test_remote_to_logical () =
  check string "relative logical path" "src/main.ml"
    (Keeper_remote_path.remote_to_logical ~endpoint ~keeper:"keeper-a"
       remote_file);
  check string "root" "."
    (Keeper_remote_path.remote_to_logical ~endpoint ~keeper:"keeper-a"
       "/srv/masc/playground/keeper-a");
  check string "outside unchanged" "/etc/passwd"
    (Keeper_remote_path.remote_to_logical ~endpoint ~keeper:"keeper-a"
       "/etc/passwd")
;;

let test_jail_and_endpoint_isolation () =
  let outside = "/workspace/.masc/playground/keeper-b/src/main.ml" in
  let outside_result =
    Keeper_remote_path.host_to_remote ~base_path ~endpoint ~keeper:"keeper-a"
      outside
  in
  (match outside_result with
   | Ok path -> failf "outside path translated to %s" path
   | Error error ->
     check bool "named jail error" true
       (String.starts_with ~prefix:"remote_ssh_path_jail_violation:" error));
  let endpoint_b = { endpoint with remote_root = "/srv/other/playground" } in
  check (result string string) "different endpoint root"
    (Ok "/srv/other/playground/keeper-a/src/main.ml")
    (Keeper_remote_path.host_to_remote ~base_path ~endpoint:endpoint_b
       ~keeper:"keeper-a" host_file)
;;

let test_rewrite_output_and_chunk_boundary () =
  let expected = "error: " ^ host_file ^ ":12\n" in
  check string "absolute remote output becomes host logical" expected
    (Keeper_remote_path.rewrite_output ~base_path ~endpoint ~keeper:"keeper-a"
       ("error: " ^ remote_file ^ ":12\n"));
  check string "sibling prefix untouched"
    "/srv/masc/playground/keeper-a-copy/main.ml"
    (Keeper_remote_path.rewrite_output ~base_path ~endpoint ~keeper:"keeper-a"
       "/srv/masc/playground/keeper-a-copy/main.ml");
  let out = Buffer.create 64 in
  let stream =
    Keeper_remote_path.stream ~base_path ~endpoint ~keeper:"keeper-a"
      ~emit:(Buffer.add_string out)
  in
  Keeper_remote_path.rewrite_stream_chunk stream "error: /srv/masc/play";
  Keeper_remote_path.rewrite_stream_chunk stream "ground/keeper-a/src/main.ml";
  Keeper_remote_path.finish_stream stream;
  check string "chunk-boundary rewrite"
    ("error: " ^ host_file)
    (Buffer.contents out)
;;

let () =
  run "keeper_remote_path"
    [ ( "mapping"
      , [ test_case "host to remote" `Quick test_host_to_remote
        ; test_case "remote to logical" `Quick test_remote_to_logical
        ; test_case "jail + endpoint isolation" `Quick
            test_jail_and_endpoint_isolation
        ; test_case "output rewrite + chunk boundary" `Quick
            test_rewrite_output_and_chunk_boundary
        ] )
    ]
