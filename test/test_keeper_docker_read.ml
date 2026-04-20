(** Tests for Keeper_docker_read.

    RFC-0006 Phase B-2: docker-routed reads for hardened keepers.
    These tests cover the pure path-mapping and flag-gating logic;
    the actual [docker run] call is exercised only in environments
    where docker is available, gated through env-set integration
    tests. *)

module Coord = Masc_mcp.Coord
module Keeper_docker_read = Masc_mcp.Keeper_docker_read
module Keeper_types = Masc_mcp.Keeper_types
module Keeper_alerting_path = Masc_mcp.Keeper_alerting_path
module Keeper_sandbox = Masc_mcp.Keeper_sandbox

(* ── Helpers ─────────────────────────────────────────────────────── *)

let with_env key value f =
  let prior = try Some (Sys.getenv key) with Not_found -> None in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let temp_dir () =
  let d = Filename.temp_file "keeper_docker_read_" "" in
  Unix.unlink d;
  Unix.mkdir d 0o755;
  d

let cleanup_dir dir =
  let rec rm path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
        Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error _ -> ()
  in
  try rm dir with _ -> ()

let make_meta ~name ~sandbox =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "docker read test");
        ( "sandbox_profile",
          `String (Keeper_types.sandbox_profile_to_string sandbox) );
      ]
  in
  match Keeper_types.meta_of_json json with
  | Ok m -> m
  | Error e -> Alcotest.fail e

(* ── should_route_read flag matrix ───────────────────────────────── *)

let test_legacy_keeper_never_routes () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  with_env "MASC_KEEPER_DOCKER_READ" "true" @@ fun () ->
  let meta = make_meta ~name:"alice" ~sandbox:Keeper_types.Legacy_local in
  Alcotest.(check bool) "legacy keeper never routes through docker"
    false
    (Keeper_docker_read.should_route_read ~meta)

let test_hardened_with_only_symmetric_does_not_route () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  with_env "MASC_KEEPER_DOCKER_READ" "false" @@ fun () ->
  let meta =
    make_meta ~name:"minjae" ~sandbox:Keeper_types.Docker_hardened
  in
  Alcotest.(check bool) "B-1 alone does not enable B-2 routing"
    false
    (Keeper_docker_read.should_route_read ~meta)

let test_hardened_with_only_docker_read_does_not_route () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "false" @@ fun () ->
  with_env "MASC_KEEPER_DOCKER_READ" "true" @@ fun () ->
  let meta =
    make_meta ~name:"minjae" ~sandbox:Keeper_types.Docker_hardened
  in
  Alcotest.(check bool)
    "DOCKER_READ alone (without SYMMETRIC_SANDBOX) does not route"
    false
    (Keeper_docker_read.should_route_read ~meta)

let test_hardened_with_both_flags_routes () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  with_env "MASC_KEEPER_DOCKER_READ" "true" @@ fun () ->
  let meta =
    make_meta ~name:"minjae" ~sandbox:Keeper_types.Docker_hardened
  in
  Alcotest.(check bool) "hardened + both flags → docker route"
    true
    (Keeper_docker_read.should_route_read ~meta)

let test_docker_with_git_also_routes () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  with_env "MASC_KEEPER_DOCKER_READ" "true" @@ fun () ->
  let meta =
    make_meta ~name:"poe" ~sandbox:Keeper_types.Docker_with_git
  in
  Alcotest.(check bool) "docker_with_git also routes" true
    (Keeper_docker_read.should_route_read ~meta)

(* ── container_path_of_host pure mapping ─────────────────────────── *)

let setup_config name =
  let base = temp_dir () in
  Unix.mkdir (Filename.concat base ".masc") 0o755;
  let config = Coord.default_config base in
  let meta =
    make_meta ~name ~sandbox:Keeper_types.Docker_hardened
  in
  base, config, meta

let test_container_path_root_maps () =
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let host_root =
    Filename.concat (Keeper_alerting_path.project_root_of_config config)
      (Keeper_alerting_path.playground_path_of_keeper meta.name)
  in
  let croot = Keeper_sandbox.container_root meta.name in
  match
    Keeper_docker_read.container_path_of_host ~config ~meta
      ~host_path:host_root
  with
  | Ok mapped ->
      Alcotest.(check string) "host playground root maps to container root"
        croot mapped
  | Error e -> Alcotest.fail e

let test_container_path_nested_maps_with_suffix () =
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let host_root =
    Filename.concat (Keeper_alerting_path.project_root_of_config config)
      (Keeper_alerting_path.playground_path_of_keeper meta.name)
  in
  let host_path = Filename.concat host_root "mind/scratch.md" in
  let croot = Keeper_sandbox.container_root meta.name in
  match
    Keeper_docker_read.container_path_of_host ~config ~meta ~host_path
  with
  | Ok mapped ->
      Alcotest.(check string)
        "host nested path maps with suffix"
        (Filename.concat croot "mind/scratch.md")
        mapped
  | Error e -> Alcotest.fail e

let test_container_path_outside_playground_errors () =
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let outside = "/etc/passwd" in
  match
    Keeper_docker_read.container_path_of_host ~config ~meta
      ~host_path:outside
  with
  | Ok mapped ->
      Alcotest.failf
        "expected error for outside-playground path, got Ok %s" mapped
  | Error _ -> ()

(* ── Integration: read_file_in_container error paths
   (exercised without invoking docker) ──────────────────────────── *)

let test_read_outside_playground_returns_mapping_error () =
  with_env "MASC_KEEPER_DOCKER_READ" "true" @@ fun () ->
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  match
    Keeper_docker_read.read_file_in_container ~config ~meta
      ~host_path:"/etc/passwd" ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Ok _ -> Alcotest.fail "expected mapping error for /etc/passwd"
  | Error msg ->
      Alcotest.(check bool) "error mentions playground" true
        (let needle = "playground" in
         let nlen = String.length needle in
         let mlen = String.length msg in
         let rec loop i =
           if i + nlen > mlen then false
           else if String.sub msg i nlen = needle then true
           else loop (i + 1)
         in
         loop 0)

let test_read_empty_image_config_errors () =
  with_env "MASC_KEEPER_DOCKER_READ" "true" @@ fun () ->
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  let base, config, meta = setup_config "minjae" in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  let host_root =
    Filename.concat (Keeper_alerting_path.project_root_of_config config)
      (Keeper_alerting_path.playground_path_of_keeper meta.name)
  in
  let host_path = Filename.concat host_root "mind/x" in
  match
    Keeper_docker_read.read_file_in_container ~config ~meta ~host_path
      ~max_bytes:4096 ~timeout_sec:5.0 ()
  with
  | Ok _ -> Alcotest.fail "expected image-config error"
  | Error msg ->
      Alcotest.(check bool) "error mentions docker image" true
        (let needle = "docker image" in
         let nlen = String.length needle in
         let mlen = String.length msg in
         let rec loop i =
           if i + nlen > mlen then false
           else if String.sub msg i nlen = needle then true
           else loop (i + 1)
         in
         loop 0)

let () =
  Alcotest.run "Keeper_docker_read"
    [
      ( "should_route_read",
        [
          Alcotest.test_case "legacy never routes" `Quick
            test_legacy_keeper_never_routes;
          Alcotest.test_case "B-1 alone does not enable B-2" `Quick
            test_hardened_with_only_symmetric_does_not_route;
          Alcotest.test_case "DOCKER_READ alone does not route" `Quick
            test_hardened_with_only_docker_read_does_not_route;
          Alcotest.test_case "hardened + both flags routes" `Quick
            test_hardened_with_both_flags_routes;
          Alcotest.test_case "docker_with_git also routes" `Quick
            test_docker_with_git_also_routes;
        ] );
      ( "container_path_of_host",
        [
          Alcotest.test_case "playground root maps to container root"
            `Quick test_container_path_root_maps;
          Alcotest.test_case "nested host path maps with suffix" `Quick
            test_container_path_nested_maps_with_suffix;
          Alcotest.test_case "outside playground errors" `Quick
            test_container_path_outside_playground_errors;
        ] );
      ( "read_file_in_container",
        [
          Alcotest.test_case "outside playground returns mapping error"
            `Quick test_read_outside_playground_returns_mapping_error;
          Alcotest.test_case "empty image configuration errors" `Quick
            test_read_empty_image_config_errors;
        ] );
    ]
