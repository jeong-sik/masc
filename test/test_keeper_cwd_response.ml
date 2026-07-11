(** Property tests for [Keeper_cwd_response].

    These pin the contract that LLM-facing JSON responses
    constructed via {!Keeper_cwd_response.to_yojson_response}
    never reveal the host abs path of a Docker-backend keeper.

    Background: PR #11080 removed [sandbox_host_root] /
    [playground_path] from [execution_context], but sibling
    [cwd] fields in [keeper_sandbox_docker] / [keeper_tool_command_runtime]
    response builders still echoed the host abs path. The Docker
    [--workdir] argument was translated via
    [docker_private_workspace_cwd], yet that translation was not
    propagated into the response JSON, so the LLM re-emitted
    [cd /Users/...] on the next turn — invalid inside the
    container.

    These tests are the layer-1 guard: they pin the audience
    semantics of the [Keeper_cwd_response] module itself. The
    layer-2/3 guards (response builders + MLI gate) live in
    follow-up PRs. *)

open Alcotest
open Masc

(* Marker host-root prefix that must never appear in a
   Docker-keeper LLM-facing response.  Using a recognizable
   constant lets the assertion fail loudly in future regressions
   even if the offending path component is renamed. *)
let host_root_marker = "/tmp/HOST_ROOT_MARKER_NEVER_LEAK"

let mk_local_sandbox () : Keeper_sandbox.t =
  { keeper_name = "test-local"
  ; sandbox_id = "keeper:test-local"
  ; backend = Local
  ; sandbox_profile = "local"
  ; network_mode = "host"
  ; host_root_rel = ".masc/playground/test-local/"
  ; host_root_abs = host_root_marker ^ "/.masc/playground/test-local"
  ; container_root = None
  ; root_arg = "."
  ; mind_arg = "mind"
  ; repos_arg = "repos"
  ; task_overlay_pattern = "repos/<repo>"
  }

let mk_docker_sandbox () : Keeper_sandbox.t =
  { keeper_name = "test-docker"
  ; sandbox_id = "keeper:test-docker"
  ; backend = Docker
  ; sandbox_profile = "docker"
  ; network_mode = "host"
  ; host_root_rel = ".masc/playground/docker/test-docker/"
  ; host_root_abs =
      host_root_marker ^ "/.masc/playground/docker/test-docker"
  ; container_root = Some "/home/keeper/playground/test-docker"
  ; root_arg = "."
  ; mind_arg = "mind"
  ; repos_arg = "repos"
  ; task_overlay_pattern = "repos/<repo>"
  }

let local_response ~host_cwd =
  Keeper_cwd_response.of_sandbox
    ~sandbox:(mk_local_sandbox ())
    ~host_cwd
    ~container_cwd_for_docker:"IGNORED_FOR_LOCAL_BACKEND"
;;

let docker_response ~host_cwd ~container_cwd =
  Keeper_cwd_response.of_sandbox
    ~sandbox:(mk_docker_sandbox ())
    ~host_cwd
    ~container_cwd_for_docker:container_cwd
;;

(* --- Local backend: passthrough semantics ------------------- *)

let test_local_backend_passthrough () =
  let host_cwd =
    host_root_marker ^ "/.masc/playground/test-local/repos/foo"
  in
  let r = local_response ~host_cwd in
  check string "keeper_visible == host_cwd" host_cwd
    (Keeper_cwd_response.keeper_visible r);
  check string "operator_host == host_cwd" host_cwd
    (Keeper_cwd_response.operator_host r)

let test_local_json_emits_host_path () =
  (* For Local backend the host path IS the keeper-visible path,
     so the JSON response will (correctly) contain it. The
     positive check here is that [to_yojson_response] returns
     exactly the host_cwd string. *)
  let host_cwd =
    host_root_marker ^ "/.masc/playground/test-local/repos/foo"
  in
  let r = local_response ~host_cwd in
  let json = Keeper_cwd_response.to_yojson_response r in
  match json with
  | `String s -> check string "JSON String == host_cwd" host_cwd s
  | _ -> fail "expected `String yojson value"

(* --- Docker backend: container path in response, host hidden  *)

let test_docker_backend_keeper_visible_is_container () =
  let host_cwd =
    host_root_marker ^ "/.masc/playground/docker/test-docker/repos/foo"
  in
  let container_cwd = "/home/keeper/playground/test-docker/repos/foo" in
  let r = docker_response ~host_cwd ~container_cwd in
  check string "keeper_visible == container_cwd" container_cwd
    (Keeper_cwd_response.keeper_visible r);
  check string "operator_host == host_cwd (retained for logs)"
    host_cwd
    (Keeper_cwd_response.operator_host r)

let test_docker_json_does_not_leak_host_root () =
  let host_cwd =
    host_root_marker ^ "/.masc/playground/docker/test-docker/repos/foo"
  in
  let container_cwd = "/home/keeper/playground/test-docker/repos/foo" in
  let r = docker_response ~host_cwd ~container_cwd in
  let json_str =
    Keeper_cwd_response.to_yojson_response r |> Yojson.Safe.to_string
  in
  check bool "JSON response does NOT contain host root marker" false
    (Astring.String.is_infix ~affix:host_root_marker json_str);
  check bool "JSON response does NOT contain host_cwd" false
    (Astring.String.is_infix ~affix:host_cwd json_str);
  check bool "JSON response contains container_cwd" true
    (Astring.String.is_infix ~affix:container_cwd json_str)

(* --- of_sandbox dispatches on backend ----------------------- *)

let test_of_sandbox_local_dispatch () =
  let sandbox = mk_local_sandbox () in
  let host_cwd = sandbox.host_root_abs ^ "/repos/x" in
  let r =
    Keeper_cwd_response.of_sandbox ~sandbox ~host_cwd
      ~container_cwd_for_docker:"IGNORED_FOR_LOCAL_BACKEND"
  in
  check string "Local of_sandbox returns host path" host_cwd
    (Keeper_cwd_response.keeper_visible r);
  let json_str =
    Keeper_cwd_response.to_yojson_response r |> Yojson.Safe.to_string
  in
  check bool
    "ignored container_cwd_for_docker value never appears in JSON"
    false
    (Astring.String.is_infix ~affix:"IGNORED_FOR_LOCAL_BACKEND" json_str)

let test_of_sandbox_docker_dispatch () =
  let sandbox = mk_docker_sandbox () in
  let host_cwd = sandbox.host_root_abs ^ "/repos/x" in
  let container_cwd =
    "/home/keeper/playground/test-docker/repos/x"
  in
  let r =
    Keeper_cwd_response.of_sandbox ~sandbox ~host_cwd
      ~container_cwd_for_docker:container_cwd
  in
  check string "Docker of_sandbox returns container path"
    container_cwd
    (Keeper_cwd_response.keeper_visible r);
  let json_str =
    Keeper_cwd_response.to_yojson_response r |> Yojson.Safe.to_string
  in
  check bool "Docker JSON does not contain host marker" false
    (Astring.String.is_infix ~affix:host_root_marker json_str)

(* --- Property: docker JSON never contains host_cwd ---------- *)

let test_property_docker_response_never_leaks_host () =
  let cases =
    [
      ( "/tmp/HOST/repos/a"
      , "/home/keeper/playground/k/repos/a" )
    ; ( "/Users/dancer/me/.masc/playground/docker/k/repos/long/path"
      , "/home/keeper/playground/k/repos/long/path" )
    ; "/var/HOST_ROOT/x", "/home/keeper/playground/k/x"
    ; ( host_root_marker ^ "/edge/case/with spaces"
      , "/home/keeper/playground/k/edge/case/with spaces" )
    ]
  in
  List.iter
    (fun (host_cwd, container_cwd) ->
      let r = docker_response ~host_cwd ~container_cwd in
      let json_str =
        Keeper_cwd_response.to_yojson_response r
        |> Yojson.Safe.to_string
      in
      check bool
        (Printf.sprintf "host '%s' does not leak in JSON" host_cwd)
        false
        (Astring.String.is_infix ~affix:host_cwd json_str);
      check bool
        (Printf.sprintf "container '%s' does appear in JSON"
           container_cwd)
        true
        (Astring.String.is_infix ~affix:container_cwd json_str))
    cases

(* --- profile_independent_cwd fallback ---------------- *)

let test_profile_independent_cwd_empty_root () =
  let r = Keeper_cwd_response.profile_independent_cwd ~container_root:"" ~host_cwd:"/home/keeper/repos" in
  Alcotest.(check (option string)) "empty container_root returns None" None r

let test_profile_independent_cwd_exact_match () =
  let cwd = Keeper_cwd_response.profile_independent_cwd ~container_root:"/home/keeper" ~host_cwd:"/home/keeper" in
  Alcotest.(check (option string)) "exact match returns Some" (Some "/home/keeper") cwd

let test_profile_independent_cwd_prefix_match () =
  let cwd = Keeper_cwd_response.profile_independent_cwd ~container_root:"/home/keeper" ~host_cwd:"/home/keeper/playground/test/repos/foo" in
  Alcotest.(check (option string)) "prefix match returns Some" (Some "/home/keeper/playground/test/repos/foo") cwd

let test_profile_independent_cwd_no_match () =
  let r = Keeper_cwd_response.profile_independent_cwd ~container_root:"/home/docker" ~host_cwd:"/other/profile/path" in
  Alcotest.(check (option string)) "no match returns None" None r

let () =
  run "keeper_cwd_response"
    [
      ( "local-backend"
      , [
          test_case "local backend: passthrough" `Quick
            test_local_backend_passthrough
        ; test_case "local JSON emits host path (== visible)" `Quick
            test_local_json_emits_host_path
        ; test_case "of_sandbox dispatches Local to host path" `Quick
            test_of_sandbox_local_dispatch
        ] )
    ; ( "docker-backend"
      , [
          test_case
            "docker backend: keeper_visible is container path"
            `Quick
            test_docker_backend_keeper_visible_is_container
        ; test_case "docker JSON does not leak host root marker"
            `Quick test_docker_json_does_not_leak_host_root
        ; test_case "of_sandbox dispatches Docker to container path"
            `Quick test_of_sandbox_docker_dispatch
        ] )
    ; ( "no-host-leak-property"
      , [
          test_case
            "docker response JSON never contains host_cwd substring"
            `Quick test_property_docker_response_never_leaks_host
        ] )
    ; ( "profile-independent-cwd"
      , [
          test_case "empty container_root returns None" `Quick
            test_profile_independent_cwd_empty_root
        ; test_case "exact match returns Some" `Quick
            test_profile_independent_cwd_exact_match
        ; test_case "prefix match returns Some" `Quick
            test_profile_independent_cwd_prefix_match
        ; test_case "no match returns None" `Quick
            test_profile_independent_cwd_no_match
        ] )
    ]
