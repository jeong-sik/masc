(** Tests for keeper_shell docker routing (RFC-0006 Phase B-3b).

    Verifies that the [should_route_read] branch fires for [cat] and
    [ls] when symmetric_sandbox + docker_read are both on for a
    hardened keeper. The docker process itself is not invoked because
    the test environment sets [MASC_KEEPER_SANDBOX_DOCKER_IMAGE=""],
    so the response must surface the structured "docker image is not
    configured" error from [Keeper_docker_read] — proof that control
    reached the docker route. *)

module Coord = Masc_mcp.Coord
module Keeper_exec_shell = Masc_mcp.Keeper_exec_shell
module Keeper_registry = Masc_mcp.Keeper_registry
module Keeper_types = Masc_mcp.Keeper_types
module Keeper_alerting_path = Masc_mcp.Keeper_alerting_path
module Fs_compat = Fs_compat
module Json = Yojson.Safe.Util

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
  let dir = Filename.temp_file "keeper_shell_docker_route_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter
          (fun name -> rm (Filename.concat path name))
          (Sys.readdir path);
        Unix.rmdir path
    | _ -> Unix.unlink path
    | exception Unix.Unix_error _ -> ()
  in
  try rm dir with _ -> ()

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let make_meta ~name ~sandbox =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String ("agent-" ^ name));
        ("trace_id", `String ("trace-" ^ name));
        ("goal", `String "shell docker route test");
        ("allowed_paths", `List [ `String "*" ]);
        ( "sandbox_profile",
          `String (Keeper_types.sandbox_profile_to_string sandbox) );
      ]
  in
  match Keeper_types.meta_of_json json with
  | Ok meta -> meta
  | Error e -> Alcotest.fail e

let with_eio_fs f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  f ()

let setup ~sandbox f =
  with_eio_fs @@ fun () ->
  let base = temp_dir () in
  ensure_dir (Filename.concat base ".masc");
  let config = Coord.default_config base in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Keeper_registry.clear ();
  let meta = make_meta ~name:"minjae" ~sandbox in
  let playground =
    Filename.concat base
      (Keeper_alerting_path.playground_path_of_keeper meta.name)
  in
  ensure_dir playground;
  f ~config ~meta ~playground

let parse_field raw field =
  Yojson.Safe.from_string raw |> Json.member field

let parse_string_field raw field =
  parse_field raw field |> Json.to_string_option

let response_mentions raw field needle =
  match parse_string_field raw field with
  | None -> false
  | Some s ->
      let len = String.length needle in
      let n = String.length s in
      let rec loop i =
        if i + len > n then false
        else if String.sub s i len = needle then true
        else loop (i + 1)
      in
      loop 0

(* ── Tests ───────────────────────────────────────────────────────── *)

let test_cat_routes_through_docker () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  with_env "MASC_KEEPER_DOCKER_READ" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  setup ~sandbox:Keeper_types.Docker_hardened
  @@ fun ~config ~meta ~playground ->
  let host_path = Filename.concat playground "mind/x" in
  ensure_dir (Filename.dirname host_path);
  ignore (Fs_compat.save_file_atomic host_path "matrix");
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~config ~meta
      ~args:(`Assoc [ ("op", `String "cat"); ("path", `String host_path) ])
  in
  Alcotest.(check bool)
    "cat surfaces docker image config error (docker route fired)"
    true
    (response_mentions raw "error" "docker image")

let test_ls_routes_through_docker () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  with_env "MASC_KEEPER_DOCKER_READ" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  setup ~sandbox:Keeper_types.Docker_hardened
  @@ fun ~config ~meta ~playground ->
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~config ~meta
      ~args:(`Assoc [ ("op", `String "ls"); ("path", `String playground) ])
  in
  Alcotest.(check bool)
    "ls surfaces docker image config error (docker route fired)"
    true
    (response_mentions raw "error" "docker image")

let test_cat_legacy_keeper_skips_docker () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  with_env "MASC_KEEPER_DOCKER_READ" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  setup ~sandbox:Keeper_types.Legacy_local
  @@ fun ~config ~meta ~playground ->
  let host_path = Filename.concat playground "mind/x" in
  ensure_dir (Filename.dirname host_path);
  ignore (Fs_compat.save_file_atomic host_path "matrix");
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~config ~meta
      ~args:(`Assoc [ ("op", `String "cat"); ("path", `String host_path) ])
  in
  Alcotest.(check bool)
    "legacy keeper does not surface docker image error"
    false
    (response_mentions raw "error" "docker image")

let test_cat_flag_off_skips_docker () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  with_env "MASC_KEEPER_DOCKER_READ" "false" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  setup ~sandbox:Keeper_types.Docker_hardened
  @@ fun ~config ~meta ~playground ->
  let host_path = Filename.concat playground "mind/x" in
  ensure_dir (Filename.dirname host_path);
  ignore (Fs_compat.save_file_atomic host_path "matrix");
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~config ~meta
      ~args:(`Assoc [ ("op", `String "cat"); ("path", `String host_path) ])
  in
  Alcotest.(check bool)
    "DOCKER_READ off → no docker route, no image error"
    false
    (response_mentions raw "error" "docker image")

let () =
  Alcotest.run "Keeper_shell_docker_route"
    [
      ( "docker_route_fires",
        [
          Alcotest.test_case "cat routes through docker for hardened+flags"
            `Quick test_cat_routes_through_docker;
          Alcotest.test_case "ls routes through docker for hardened+flags"
            `Quick test_ls_routes_through_docker;
        ] );
      ( "docker_route_skipped",
        [
          Alcotest.test_case "legacy keeper skips docker route" `Quick
            test_cat_legacy_keeper_skips_docker;
          Alcotest.test_case "DOCKER_READ flag off skips docker route"
            `Quick test_cat_flag_off_skips_docker;
        ] );
    ]
