(** Tests for keeper_shell docker routing (RFC-0006 Phase B-3b+).

    Verifies that the [should_route_read] branch fires for path-based
    readonly keeper_shell ops when symmetric_sandbox + docker_read are
    both on for a hardened keeper. The docker process itself is not
    invoked because the test environment sets
    [MASC_KEEPER_SANDBOX_DOCKER_IMAGE=""], so the response must
    surface the structured "docker image is not configured" error from
    [Keeper_docker_read] — proof that control reached the docker
    route. *)

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

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) @@ fun () ->
  output_string oc content

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

let with_fake_docker script f =
  let dir = temp_dir () in
  let docker_path = Filename.concat dir "docker" in
  write_file docker_path script;
  Unix.chmod docker_path 0o755;
  let path =
    match Sys.getenv_opt "PATH" with
    | Some prior when String.trim prior <> "" -> dir ^ ":" ^ prior
    | _ -> dir
  in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) @@ fun () ->
  with_env "PATH" path f

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

let parse_bool_field raw field =
  parse_field raw field |> Json.to_bool_option

let parse_status_exit_code raw =
  match parse_field raw "status" |> Json.member "code" |> Json.to_int_option with
  | Some code -> code
  | None -> Alcotest.failf "missing status.code in %s" raw

let assert_docker_route_fires ~config ~meta ~playground =
  let host_path = Filename.concat playground "mind/demo.txt" in
  ensure_dir (Filename.dirname host_path);
  ignore (Fs_compat.save_file_atomic host_path "alpha\nbeta\ngamma\n");
  let cases =
    [
      ("cat", `Assoc [ ("op", `String "cat"); ("path", `String host_path) ]);
      ("ls", `Assoc [ ("op", `String "ls"); ("path", `String playground) ]);
      ( "rg",
        `Assoc
          [
            ("op", `String "rg");
            ("pattern", `String "alpha");
            ("path", `String playground);
          ] );
      ( "find",
        `Assoc
          [
            ("op", `String "find");
            ("pattern", `String "*.txt");
            ("path", `String playground);
          ] );
      ( "head",
        `Assoc
          [
            ("op", `String "head");
            ("lines", `Int 1);
            ("path", `String host_path);
          ] );
      ( "tail",
        `Assoc
          [
            ("op", `String "tail");
            ("lines", `Int 1);
            ("path", `String host_path);
          ] );
      ("wc", `Assoc [ ("op", `String "wc"); ("path", `String host_path) ]);
      ("tree", `Assoc [ ("op", `String "tree"); ("path", `String playground) ]);
    ]
  in
  List.iter
    (fun (op, args) ->
      let raw =
        Keeper_exec_shell.handle_keeper_shell ~config ~meta ~args
      in
      Alcotest.(check bool)
        (Printf.sprintf "%s surfaces docker image config error (docker route fired)" op)
        true
        (response_mentions raw "error" "docker image"))
    cases

(* ── Tests ───────────────────────────────────────────────────────── *)

let test_readonly_ops_route_through_docker () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  with_env "MASC_KEEPER_DOCKER_READ" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  assert_docker_route_fires ~config ~meta ~playground

let test_cat_legacy_keeper_skips_docker () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  with_env "MASC_KEEPER_DOCKER_READ" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "" @@ fun () ->
  setup ~sandbox:Keeper_types.Local
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
  setup ~sandbox:Keeper_types.Docker
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

let fake_docker_rg_no_match_script =
  "#!/bin/sh\n\
if [ \"$1\" = \"info\" ]; then\n\
  printf '[]\\n'\n\
  exit 0\n\
fi\n\
if [ \"$1\" != \"run\" ]; then\n\
  printf 'unexpected docker invocation\\n' >&2\n\
  exit 2\n\
fi\n\
shift\n\
while [ \"$#\" -gt 0 ]; do\n\
  if [ \"$1\" = \"alpine:test\" ]; then\n\
    shift\n\
    break\n\
  fi\n\
  shift\n\
done\n\
if [ \"$1\" = \"rg\" ]; then\n\
  exit 1\n\
fi\n\
printf '%s\\n' \"$*\"\n\
exit 0\n"

let test_rg_no_match_remains_successful_in_docker_route () =
  with_env "MASC_KEEPER_SYMMETRIC_SANDBOX" "true" @@ fun () ->
  with_env "MASC_KEEPER_DOCKER_READ" "true" @@ fun () ->
  with_env "MASC_KEEPER_SANDBOX_DOCKER_IMAGE" "alpine:test" @@ fun () ->
  with_fake_docker fake_docker_rg_no_match_script @@ fun () ->
  setup ~sandbox:Keeper_types.Docker
  @@ fun ~config ~meta ~playground ->
  let host_path = Filename.concat playground "mind/demo.txt" in
  ensure_dir (Filename.dirname host_path);
  ignore (Fs_compat.save_file_atomic host_path "alpha\nbeta\ngamma\n");
  let raw =
    Keeper_exec_shell.handle_keeper_shell ~config ~meta
      ~args:
        (`Assoc
            [
              ("op", `String "rg");
              ("pattern", `String "missing");
              ("path", `String playground);
            ])
  in
  Alcotest.(check (option bool)) "rg no-match stays ok" (Some true)
    (parse_bool_field raw "ok");
  Alcotest.(check int) "rg keeps exit=1 status" 1
    (parse_status_exit_code raw);
  Alcotest.(check int) "rg no-match returns empty matches" 0
    (parse_field raw "matches" |> Json.to_list |> List.length)

let () =
  Alcotest.run "Keeper_shell_docker_route"
    [
      ( "docker_route_fires",
        [
          Alcotest.test_case
            "path-based readonly ops route through docker for hardened+flags"
            `Quick test_readonly_ops_route_through_docker;
        ] );
      ( "docker_route_skipped",
        [
          Alcotest.test_case "legacy keeper skips docker route" `Quick
            test_cat_legacy_keeper_skips_docker;
          Alcotest.test_case "DOCKER_READ flag off skips docker route"
            `Quick test_cat_flag_off_skips_docker;
        ] );
      ( "docker_route_contract",
        [
          Alcotest.test_case "rg no-match remains successful" `Quick
            test_rg_no_match_remains_successful_in_docker_route;
        ] );
    ]
