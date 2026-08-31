(** SSOT invariants for keeper sandbox / playground path resolution.

    Two things are pinned here:

    - the concrete on-disk layout a keeper's roots resolve to, as literal
      strings, plus rejection of the retired [sandbox_profile] aliases;
    - {!Masc.Keeper_sandbox.visible_path_of_host}, the one host -> keeper
      projection, and specifically that it fails closed. Five separate
      implementations of that mapping used to exist and each answered an
      unmappable path with a substitute string; #10650 measured ~890 failed
      docker execs a day from one of them.

    Earlier revisions of this file also asserted that
    [host_root_abs_of_meta] equals [base_path / allowed_root_rel_of_meta].
    Those were removed rather than repaired: [allowed_root_rel_of_meta]
    delegates directly to [host_root_rel_of_meta], so the assertion reduced
    to [concat b (f x) = concat b (f x)] and could not fail. Removed with
    them were a purity check on a pure function and two "distinct inputs
    give distinct roots" cases that the literal-layout assertions below
    already subsume.

    Note for anyone reading a green run as evidence of history: every case
    in this file failed at the fixture, before reaching its assertion, from
    whenever [sandbox_profile] left the persisted meta schema until
    2026-07-28. The fixture built its meta by putting that field in the
    meta JSON, and the closed schema rejects unknown fields. *)

module Workspace = Masc.Workspace
module Keeper_types = Keeper_types
module Keeper_sandbox = Masc.Keeper_sandbox
module Keeper_sandbox_docker = Masc.Keeper_sandbox_docker

let temp_dir () =
  let path = Filename.temp_file "masc-path-ssot-" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

(* [sandbox_profile] is deliberately not a field of the persisted meta JSON:
   the parser always seeds it from the default and the real value is resolved
   from the keeper TOML. This fixture used to pass it inside the JSON, which
   the closed current schema now rejects outright ("fields outside the
   current schema: sandbox_profile"), so every case in this file failed
   before reaching its assertion. Set the record field instead. *)
let make_meta ~name ~sandbox =
  (* Only [name] is supplied. [agent_name] and [trace_id] are derived, and
     the fixture builds both from the canonical rules — spelling them by
     hand here produced "agent_name does not match canonical keeper
     identity". *)
  let json = `Assoc [ ("name", `String name) ] in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> { m with Masc.Keeper_meta_contract.sandbox_profile = sandbox }
  | Error e -> Alcotest.fail e

let make_config () =
  let base = temp_dir () in
  Unix.mkdir (Filename.concat base ".masc") 0o755;
  Workspace.default_config base

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if not (String.equal parent path) then mkdir_p parent;
    Unix.mkdir path 0o755)

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let write_keeper_toml ~config ~name ~sandbox_profile =
  let dir =
    Filename.concat
      (Filename.concat
         (Filename.concat config.Workspace.base_path ".masc")
         "config")
      "keepers"
  in
  mkdir_p dir;
  write_file
    (Filename.concat dir (name ^ ".toml"))
    (Printf.sprintf "[keeper]\nsandbox_profile = %S\n" sandbox_profile)

let test_config_agent_projection_docker () =
  let config = make_config () in
  write_keeper_toml ~config ~name:"alpha" ~sandbox_profile:"docker";
  let agent_name = "keeper-alpha-agent" in
  Alcotest.(check string)
    "config-backed backend"
    "docker"
    (Keeper_sandbox.backend_of_config_agent ~config ~agent_name
     |> Keeper_sandbox.backend_to_string);
  Alcotest.(check string)
    "config-backed host root rel"
    ".masc/playground/docker/alpha/"
    (Keeper_sandbox.host_root_rel_of_config_agent ~config ~agent_name);
  let visible =
    Filename.concat
      (Keeper_sandbox.container_root agent_name)
      "repos/masc/lib/foo.ml"
  in
  let expected =
    Filename.concat
      config.Workspace.base_path
      ".masc/playground/docker/alpha/repos/masc/lib/foo.ml"
  in
  Alcotest.(check string)
    "sandbox-visible path maps to backend-scoped host path"
    expected
    (Keeper_sandbox.host_path_of_visible_path ~config ~agent_name visible)

let test_config_agent_projection_local () =
  let config = make_config () in
  let agent_name = "keeper-alpha-agent" in
  Alcotest.(check string)
    "missing config defaults to local backend"
    "local"
    (Keeper_sandbox.backend_of_config_agent ~config ~agent_name
     |> Keeper_sandbox.backend_to_string);
  Alcotest.(check string)
    "local host root rel"
    ".masc/playground/alpha/"
    (Keeper_sandbox.host_root_rel_of_config_agent ~config ~agent_name)

(* ── Invariant: one projection, and it is fail-closed ─────────────────

   These pin the behaviour that the five superseded host->container
   implementations disagreed on. Each of them answered an unmappable path
   with a string rather than an error, and every one of those strings names
   a directory the keeper is then told to work in:

     - return the host path unchanged  (#10650: ~890 failed docker execs/day)
     - collapse to the sandbox root    (drops the /repos/<name> segment)
     - scan repos/ for a plausible segment and synthesise a path

   A regression to any of them turns [Error] into [Ok] here. *)

let visible_or_fail ~msg = function
  | Ok visible -> Keeper_sandbox.Path.visible_to_string visible
  | Error e ->
    Alcotest.failf "%s: %s" msg (Keeper_sandbox.Path.conversion_error_to_string e)

let docker_sandbox ~config ~name =
  write_keeper_toml ~config ~name ~sandbox_profile:"docker";
  let meta = make_meta ~name ~sandbox:Keeper_types_profile_sandbox.Docker in
  (Keeper_sandbox.of_meta ~config ~meta, meta)

let test_projection_docker_maps_root_and_subpath () =
  let config = make_config () in
  let sandbox, meta = docker_sandbox ~config ~name:"alpha" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let container_root = Keeper_sandbox.container_root meta.name in
  Alcotest.(check string)
    "sandbox root projects to container root"
    container_root
    (Keeper_sandbox.visible_path_of_host
       sandbox
       (Keeper_sandbox.Path.of_host_abs host_root)
     |> visible_or_fail ~msg:"root");
  Alcotest.(check string)
    "subpath keeps its suffix"
    (Filename.concat container_root "repos/masc/lib/foo.ml")
    (Keeper_sandbox.visible_path_of_host
       sandbox
       (Keeper_sandbox.Path.of_host_abs
          (Filename.concat host_root "repos/masc/lib/foo.ml"))
     |> visible_or_fail ~msg:"subpath")

let test_projection_docker_rejects_outside_root () =
  let config = make_config () in
  let sandbox, _meta = docker_sandbox ~config ~name:"alpha" in
  let outside = "/Users/dancer/me/workspace/yousleepwhen/masc/lib/keeper" in
  match
    Keeper_sandbox.visible_path_of_host
      sandbox
      (Keeper_sandbox.Path.of_host_abs outside)
  with
  | Error (Keeper_sandbox.Path.Outside_sandbox_root { path; _ }) ->
    Alcotest.(check string) "error carries the rejected path" outside path
  | Error other ->
    Alcotest.failf
      "expected Outside_sandbox_root, got %s"
      (Keeper_sandbox.Path.conversion_error_to_string other)
  | Ok visible ->
    (* Naming the two historical substitutes makes a regression report which
       fallback came back rather than only that one did. *)
    Alcotest.failf
      "unmappable path was answered with %S instead of an error"
      (Keeper_sandbox.Path.visible_to_string visible)

(* A sibling directory whose name merely starts with the sandbox root's name
   must not be treated as being inside it. *)
let test_projection_docker_requires_segment_boundary () =
  let config = make_config () in
  let sandbox, meta = docker_sandbox ~config ~name:"alpha" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let sibling =
    Env_config_core.strip_trailing_slashes host_root ^ "-scratch/notes.md"
  in
  match
    Keeper_sandbox.visible_path_of_host
      sandbox
      (Keeper_sandbox.Path.of_host_abs sibling)
  with
  | Error _ -> ()
  | Ok visible ->
    Alcotest.failf
      "prefix-adjacent sibling leaked into the sandbox as %S"
      (Keeper_sandbox.Path.visible_to_string visible)

(* Remote_ssh keepers keep a host bookkeeping bundle, so the projection is the
   identity. Containment is a separate question, decided by
   Keeper_alerting_path, and must not be smuggled in here. *)
let test_projection_local_is_identity () =
  let config = make_config () in
  let meta = make_meta ~name:"alpha" ~sandbox:Keeper_types_profile_sandbox.Remote_ssh in
  let sandbox = Keeper_sandbox.of_meta ~config ~meta in
  let outside = "/tmp/anywhere/at/all.ml" in
  Alcotest.(check string)
    "local projection returns its input"
    outside
    (Keeper_sandbox.visible_path_of_host
       sandbox
       (Keeper_sandbox.Path.of_host_abs outside)
     |> visible_or_fail ~msg:"local")

(* [visible_path_of_raw] is the boundary parse for a cwd decoded from a
   keeper tool call. Keepers send both coordinate systems today, so both must
   land on the same visible answer. *)
let test_raw_accepts_either_coordinate_system () =
  let config = make_config () in
  let sandbox, meta = docker_sandbox ~config ~name:"alpha" in
  let host_root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let container_root = Keeper_sandbox.container_root meta.name in
  let expected = Filename.concat container_root "repos/masc" in
  Alcotest.(check string)
    "an already-visible path is kept"
    expected
    (Keeper_sandbox.visible_path_of_raw sandbox expected
     |> visible_or_fail ~msg:"already visible");
  Alcotest.(check string)
    "a host path is projected to the same answer"
    expected
    (Keeper_sandbox.visible_path_of_raw
       sandbox
       (Filename.concat host_root "repos/masc")
     |> visible_or_fail ~msg:"host spelling")

(* [config.base_path] and an incoming host cwd routinely spell the same
   location differently: one side through a symlink (/tmp vs /private/tmp
   on macOS), the other realpath-resolved as [Unix.getcwd] returns it.
   The superseded factory converter canonicalized both operands before
   comparing; a lexical-only comparison reports the equivalent path as
   [Outside_sandbox_root], and the factory's fallback then substitutes
   the sandbox root — dropping the [repos/<repo>] segment. Both
   directions are pinned, and deliberately before the playground
   directories exist on disk. *)
let test_projection_docker_resolves_symlinked_spelling () =
  let real_base = temp_dir () in
  Unix.mkdir (Filename.concat real_base ".masc") 0o755;
  let link_parent = temp_dir () in
  let linked_base = Filename.concat link_parent "workspace-link" in
  Unix.symlink real_base linked_base;
  let playground_rel = ".masc/playground/docker/alpha" in
  let check_projection ~msg ~base_spelling ~cwd_spelling =
    let config = Workspace.default_config base_spelling in
    let sandbox, meta = docker_sandbox ~config ~name:"alpha" in
    let container_root = Keeper_sandbox.container_root meta.name in
    let host_cwd =
      Filename.concat (Filename.concat cwd_spelling playground_rel) "repos/masc"
    in
    Alcotest.(check string)
      msg
      (Filename.concat container_root "repos/masc")
      (Keeper_sandbox.visible_path_of_host
         sandbox
         (Keeper_sandbox.Path.of_host_abs host_cwd)
       |> visible_or_fail ~msg)
  in
  check_projection
    ~msg:"realpath-spelled cwd projects into the symlink-configured root"
    ~base_spelling:linked_base
    ~cwd_spelling:(Unix.realpath real_base);
  check_projection
    ~msg:"symlink-spelled cwd projects into the realpath-configured root"
    ~base_spelling:(Unix.realpath real_base)
    ~cwd_spelling:linked_base

let test_config_agent_projection_rejects_legacy_alias () =
  let config = make_config () in
  write_keeper_toml ~config ~name:"alpha" ~sandbox_profile:"docker_hardened";
  Alcotest.check_raises
    "legacy sandbox_profile aliases are rejected"
    (Keeper_sandbox_config.Invalid_keeper_sandbox_config
       (Printf.sprintf
          "%s: invalid sandbox_profile %S (allowed: local, docker, microvm, remote_ssh)"
          (Keeper_sandbox_config.keeper_toml_path
             ~base_path:config.Workspace.base_path
             ~agent_name:"keeper-alpha-agent")
          "docker_hardened"))
    (fun () ->
       ignore
         (Keeper_sandbox_config.sandbox_profile_of_agent
            ~base_path:config.Workspace.base_path
            ~agent_name:"keeper-alpha-agent"))

let () =
  Alcotest.run "Keeper Path SSOT" [
    ( "config-backed sandbox contract",
      [
        Alcotest.test_case "docker projection" `Quick
          test_config_agent_projection_docker;
        Alcotest.test_case "local projection" `Quick
          test_config_agent_projection_local;
        Alcotest.test_case "legacy profile rejected" `Quick
          test_config_agent_projection_rejects_legacy_alias;
      ] );
    ( "keeper-visible projection",
      [
        Alcotest.test_case "docker root and subpath" `Quick
          test_projection_docker_maps_root_and_subpath;
        Alcotest.test_case "outside root is an error, not a substitute" `Quick
          test_projection_docker_rejects_outside_root;
        Alcotest.test_case "prefix-adjacent sibling is outside" `Quick
          test_projection_docker_requires_segment_boundary;
        Alcotest.test_case "local projection is the identity" `Quick
          test_projection_local_is_identity;
        Alcotest.test_case "raw cwd accepts either coordinate system" `Quick
          test_raw_accepts_either_coordinate_system;
        Alcotest.test_case "symlinked spellings project identically" `Quick
          test_projection_docker_resolves_symlinked_spelling;
      ] );
  ]
