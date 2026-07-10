open Masc
module C = Env_config_core

let with_env name value f =
  let prev = Sys.getenv_opt name in
  Unix.putenv name value;
  let finally () =
    match prev with
    | Some v -> Unix.putenv name v
    | None -> Unix.putenv name ""
  in
  Fun.protect ~finally f

let check_bool label expected actual =
  Alcotest.(check bool) label expected actual

let test_empty_env () =
  with_env C.code_exempt_keepers_env_key "" @@ fun () ->
  check_bool "empty string -> no keepers exempt" false
    (C.code_exempt_keeper ~keeper_name:"rondo")

let test_space_separated () =
  with_env C.code_exempt_keepers_env_key "rondo garnet base" @@ fun () ->
  check_bool "rondo is exempt" true
    (C.code_exempt_keeper ~keeper_name:"rondo");
  check_bool "garnet is exempt" true
    (C.code_exempt_keeper ~keeper_name:"garnet");
  check_bool "base is exempt" true
    (C.code_exempt_keeper ~keeper_name:"base");
  check_bool "sangsu is not exempt" false
    (C.code_exempt_keeper ~keeper_name:"sangsu")

let test_multiple_spaces () =
  with_env C.code_exempt_keepers_env_key "  rondo   garnet  " @@ fun () ->
  check_bool "rondo is exempt with spaces" true
    (C.code_exempt_keeper ~keeper_name:"rondo");
  check_bool "garnet is exempt with spaces" true
    (C.code_exempt_keeper ~keeper_name:"garnet");
  check_bool "empty is not exempt" false
    (C.code_exempt_keeper ~keeper_name:"")

let test_duplicates () =
  with_env C.code_exempt_keepers_env_key "rondo rondo garnet" @@ fun () ->
  check_bool "rondo is exempt" true
    (C.code_exempt_keeper ~keeper_name:"rondo");
  check_bool "garnet is exempt" true
    (C.code_exempt_keeper ~keeper_name:"garnet")

let test_unset_env () =
  (* Ensure env key is cleared *)
  with_env C.code_exempt_keepers_env_key "" @@ fun () ->
  check_bool "unset/empty -> not exempt" false
    (C.code_exempt_keeper ~keeper_name:"rondo")

let () =
  let open Alcotest in
  run "env_config_code_exempt_keepers"
    [
      ( "exemptions",
        [
          test_case "empty env value" `Quick test_empty_env;
          test_case "space separated list" `Quick test_space_separated;
          test_case "multiple spaces handling" `Quick test_multiple_spaces;
          test_case "duplicates in list" `Quick test_duplicates;
          test_case "unset env" `Quick test_unset_env;
        ] );
    ]
