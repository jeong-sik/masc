(** Tests for typed Shell IR docker env passthrough.

    Keeper env bindings flow into [docker exec --env] flags. These tests cover
    the final argv boundary: structured rendering and typed rejection of
    reserved, duplicate, and invalid keys, plus a drift guard asserting every
    sandbox-owned injected key is reserved. *)

module Keeper_sandbox_runtime = Masc.Keeper_sandbox_runtime
module Sandbox_target = Masc_exec.Sandbox_target

let binding key value : Sandbox_target.env_binding = { key; value }

let env_arg_keys args =
  (* args shape: ["--env"; "K=V"; "--env"; "K2=V2"; ...] *)
  let rec loop acc = function
    | "--env" :: entry :: rest ->
      let key =
        match String.index_opt entry '=' with
        | None -> entry
        | Some idx -> String.sub entry 0 idx
      in
      loop (key :: acc) rest
    | _ :: rest -> loop acc rest
    | [] -> List.rev acc
  in
  loop [] args

let test_keeper_env_args_shape () =
  match
    Keeper_sandbox_runtime.docker_keeper_env_args
      [ binding "A" "1"; binding "B" "two words" ]
  with
  | Ok args ->
    Alcotest.(check (list string))
      "entries interleave with --env flags"
      [ "--env"; "A=1"; "--env"; "B=two words" ]
      args
  | Error error ->
    Alcotest.fail
      (Keeper_sandbox_runtime.docker_keeper_env_error_to_string error)

let test_keeper_env_args_empty () =
  match Keeper_sandbox_runtime.docker_keeper_env_args [] with
  | Ok args -> Alcotest.(check (list string)) "no entries, no flags" [] args
  | Error error ->
    Alcotest.fail
      (Keeper_sandbox_runtime.docker_keeper_env_error_to_string error)

let test_reserved_key_rejected () =
  match
    Keeper_sandbox_runtime.docker_keeper_env_args [ binding "HOME" "/evil" ]
  with
  | Error (Keeper_sandbox_runtime.Reserved_key "HOME") -> ()
  | Error error ->
    Alcotest.failf
      "unexpected error: %s"
      (Keeper_sandbox_runtime.docker_keeper_env_error_to_string error)
  | Ok _ -> Alcotest.fail "reserved HOME unexpectedly accepted"

let test_duplicate_key_rejected () =
  match
    Keeper_sandbox_runtime.docker_keeper_env_args
      [ binding "TOKEN" "first"; binding "TOKEN" "second" ]
  with
  | Error (Keeper_sandbox_runtime.Duplicate_key "TOKEN") -> ()
  | Error error ->
    Alcotest.failf
      "unexpected error: %s"
      (Keeper_sandbox_runtime.docker_keeper_env_error_to_string error)
  | Ok _ -> Alcotest.fail "duplicate TOKEN unexpectedly accepted"

let test_invalid_key_rejected () =
  match
    Keeper_sandbox_runtime.docker_keeper_env_args [ binding "1TOKEN" "value" ]
  with
  | Error (Keeper_sandbox_runtime.Invalid_key "1TOKEN") -> ()
  | Error error ->
    Alcotest.failf
      "unexpected error: %s"
      (Keeper_sandbox_runtime.docker_keeper_env_error_to_string error)
  | Ok _ -> Alcotest.fail "invalid 1TOKEN unexpectedly accepted"

let test_user_env_keys_are_reserved () =
  let emitted = env_arg_keys (Keeper_sandbox_runtime.docker_user_env_args ()) in
  Alcotest.(check bool) "user env args emit keys" true (emitted <> []);
  List.iter
    (fun key ->
      Alcotest.(check bool)
        (Printf.sprintf "%s emitted by docker_user_env_args is reserved" key)
        true
        (List.mem key Keeper_sandbox_runtime.docker_sandbox_reserved_env_keys))
    emitted

let test_config_env_keys_are_reserved () =
  let tmp = Filename.temp_file "masc-docker-env" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o700;
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir tmp with Unix.Unix_error _ -> ())
    (fun () ->
      let prior = Sys.getenv_opt "MASC_CONFIG_DIR" in
      Unix.putenv "MASC_CONFIG_DIR" tmp;
      Fun.protect
        ~finally:(fun () ->
          match prior with
          | Some v -> Unix.putenv "MASC_CONFIG_DIR" v
          | None -> Unix.putenv "MASC_CONFIG_DIR" "")
        (fun () ->
          let emitted =
            env_arg_keys
              (Keeper_sandbox_runtime.docker_config_env_args
                 ~base_path:tmp
                 ~container_root:"/workspace")
          in
          Alcotest.(check bool) "config env args emit keys" true (emitted <> []);
          List.iter
            (fun key ->
              Alcotest.(check bool)
                (Printf.sprintf "%s emitted by docker_config_env_args is reserved" key)
                true
                (List.mem key Keeper_sandbox_runtime.docker_sandbox_reserved_env_keys))
            emitted))

let () =
  Alcotest.run
    "keeper_sandbox_docker_env"
    [ ( "docker_keeper_env_args"
      , [ Alcotest.test_case "interleaved --env flags" `Quick test_keeper_env_args_shape
        ; Alcotest.test_case "empty entries" `Quick test_keeper_env_args_empty
        ; Alcotest.test_case "reserved key rejected" `Quick test_reserved_key_rejected
        ; Alcotest.test_case "duplicate key rejected" `Quick test_duplicate_key_rejected
        ; Alcotest.test_case "invalid key rejected" `Quick test_invalid_key_rejected
        ] )
    ; ( "reserved list drift guard"
      , [ Alcotest.test_case
            "docker_user_env_args keys are reserved"
            `Quick
            test_user_env_keys_are_reserved
        ; Alcotest.test_case
            "docker_config_env_args keys are reserved"
            `Quick
            test_config_env_keys_are_reserved
        ] )
    ]
