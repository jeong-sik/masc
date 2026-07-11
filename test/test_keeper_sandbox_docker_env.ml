(** Tests for typed Shell IR docker env passthrough.

    Keeper env entries flow into [docker exec --env] flags
    ([Keeper_turn_sandbox_runtime.run_exec_with_status_split ~env] /
    [exec_pipeline_stage.env]). These tests cover the pure policy layer:
    the sandbox-reserved key gate ([reserved_env_collision]) and the
    [--env] argv shaping ([docker_keeper_env_args]), plus a drift guard
    asserting every key the sandbox exec boundary injects is listed in
    [docker_sandbox_reserved_env_keys]. *)

module Keeper_sandbox_runtime = Masc.Keeper_sandbox_runtime
module Keeper_sandbox_shell_ir_target = Masc.Keeper_sandbox_shell_ir_target

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

let test_no_collision_on_plain_keys () =
  Alcotest.(check (option string))
    "unreserved keys pass"
    None
    (Keeper_sandbox_shell_ir_target.reserved_env_collision
       [| "DUNE_CACHE=disabled"; "GIT_PAGER=cat"; "PATH_EXTRA=/x" |])

let test_collision_on_reserved_key () =
  Alcotest.(check (option string))
    "HOME is reserved"
    (Some "HOME")
    (Keeper_sandbox_shell_ir_target.reserved_env_collision [| "HOME=/evil" |])

let test_collision_reports_first_reserved_key () =
  Alcotest.(check (option string))
    "first reserved entry wins"
    (Some "MASC_CONFIG_DIR")
    (Keeper_sandbox_shell_ir_target.reserved_env_collision
       [| "DUNE_CACHE=enabled"; "MASC_CONFIG_DIR=/elsewhere"; "USER=root" |])

let test_collision_on_bare_key () =
  (* An entry without '=' is treated as its own key: [docker exec --env K]
     forwards the docker CLI process's own K, which for reserved keys is
     just as much a shadow as an explicit value. *)
  Alcotest.(check (option string))
    "bare reserved token collides"
    (Some "SHELL")
    (Keeper_sandbox_shell_ir_target.reserved_env_collision [| "SHELL" |])

let test_empty_env_never_collides () =
  Alcotest.(check (option string))
    "empty env passes"
    None
    (Keeper_sandbox_shell_ir_target.reserved_env_collision [||])

let test_keeper_env_args_shape () =
  Alcotest.(check (list string))
    "entries interleave with --env flags"
    [ "--env"; "A=1"; "--env"; "B=two words" ]
    (Keeper_sandbox_runtime.docker_keeper_env_args [ "A=1"; "B=two words" ])

let test_keeper_env_args_empty () =
  Alcotest.(check (list string))
    "no entries, no flags"
    []
    (Keeper_sandbox_runtime.docker_keeper_env_args [])

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
    [ ( "reserved_env_collision"
      , [ Alcotest.test_case "unreserved keys pass" `Quick test_no_collision_on_plain_keys
        ; Alcotest.test_case "reserved key collides" `Quick test_collision_on_reserved_key
        ; Alcotest.test_case
            "first reserved key reported"
            `Quick
            test_collision_reports_first_reserved_key
        ; Alcotest.test_case "bare reserved token collides" `Quick test_collision_on_bare_key
        ; Alcotest.test_case "empty env passes" `Quick test_empty_env_never_collides
        ] )
    ; ( "docker_keeper_env_args"
      , [ Alcotest.test_case "interleaved --env flags" `Quick test_keeper_env_args_shape
        ; Alcotest.test_case "empty entries" `Quick test_keeper_env_args_empty
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
