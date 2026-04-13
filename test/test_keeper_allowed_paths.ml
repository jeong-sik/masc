(** Test suite for Keeper_alerting_path.effective_allowed_paths.
    Verifies computed defaults, wildcard handling, and scope-based behavior. *)

open Alcotest
module KAP = Masc_mcp.Keeper_alerting_path
module KES = Masc_mcp.Keeper_exec_shared
module KT = Masc_mcp.Keeper_types

let make_meta ?(execution_scope = "observe_only") ?(allowed_paths = [])
    ~name () =
  let json = `Assoc [
    ("name", `String name);
    ("agent_name", `String ("agent-" ^ name));
    ("trace_id", `String ("trace-" ^ name));
    ("goal", `String "test");
    ("execution_scope", `String execution_scope);
    ("allowed_paths", `List (List.map (fun s -> `String s) allowed_paths));
  ] in
  match KT.meta_of_json json with
  | Ok meta -> meta
  | Error err -> fail ("make_meta: " ^ err)

let playground_bundle name =
  [ KAP.playground_path_of_keeper name;
    KAP.playground_mind_path name;
    KAP.playground_repos_path name ]

(* After #6527 iter 4, `.worktrees/` is no longer a workspace default.
   New worktrees land inside the keeper's own
   `.masc/playground/<keeper>/repos/<clone>/.worktrees/...` and are
   already covered by the playground bundle paths above. *)
let with_temp_dir prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect ~finally:(fun () ->
    let rec rm dir =
      if Sys.file_exists dir then
        if Sys.is_directory dir then begin
          Sys.readdir dir
          |> Array.iter (fun name -> rm (Filename.concat dir name));
          Unix.rmdir dir
        end else
          Sys.remove dir
    in
    rm path
  ) (fun () -> f path)
let workspace_defaults name =
  [ Printf.sprintf ".masc/keepers/%s/" name;
    ".masc/traces/";
    "lib/"; "test/"; "config/"; "bin/"; "scripts/"; "docs/" ]

let workspace_write_defaults name =
  [ Printf.sprintf ".masc/keepers/%s/" name;
    ".masc/traces/" ]

(* ── observe_only scope ── *)

let test_observe_only_empty_paths () =
  let meta = make_meta ~execution_scope:"observe_only" ~name:"t" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "observe_only + [] = playground bundle"
    (playground_bundle "t") effective

let test_observe_only_explicit_paths () =
  let meta = make_meta ~execution_scope:"observe_only"
      ~allowed_paths:["src/"; "lib/"] ~name:"t" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "observe_only + explicit = playground bundle + explicit"
    (playground_bundle "t" @ ["src/"; "lib/"]) effective

(* ── workspace scope ── *)

let test_workspace_empty_paths_computed_default () =
  let meta = make_meta ~execution_scope:"workspace"
      ~name:"sangsu" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "workspace + [] = playground bundle + computed default"
    (playground_bundle "sangsu" @ workspace_defaults "sangsu") effective

let test_workspace_explicit_paths () =
  let meta = make_meta ~execution_scope:"workspace"
      ~allowed_paths:["src/"; "docs/"] ~name:"t" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "workspace + explicit = playground bundle + ws defaults + explicit"
    (playground_bundle "t" @ workspace_defaults "t" @ ["src/"; "docs/"]) effective

let test_workspace_write_paths_keep_playground_and_state_only () =
  let meta = make_meta ~execution_scope:"workspace"
      ~name:"sangsu" () in
  let effective = KAP.effective_write_allowed_paths ~meta in
  check (list string) "workspace write defaults exclude repo roots"
    (playground_bundle "sangsu" @ workspace_write_defaults "sangsu") effective

let test_workspace_write_paths_preserve_explicit_overrides () =
  let meta = make_meta ~execution_scope:"workspace"
      ~allowed_paths:["workspace/yousleepwhen/oas/"] ~name:"t" () in
  let effective = KAP.effective_write_allowed_paths ~meta in
  check (list string) "explicit write override preserved"
    (playground_bundle "t" @ workspace_write_defaults "t"
     @ ["workspace/yousleepwhen/oas/"]) effective

let test_workspace_star_wildcard () =
  let meta = make_meta ~execution_scope:"workspace"
      ~allowed_paths:["*"] ~name:"t" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "workspace + [*] = [] (full access)" [] effective

(* ── local scope ── *)

let test_local_empty_paths () =
  let meta = make_meta ~execution_scope:"local" ~name:"t" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "local + [] = playground bundle"
    (playground_bundle "t") effective

(* ── wildcard handling ── *)

let test_star_wildcard_any_scope () =
  let scopes = ["observe_only"; "workspace"; "local"; "unknown"] in
  List.iter (fun scope ->
    let meta = make_meta ~execution_scope:scope ~allowed_paths:["*"] ~name:"t" () in
    let effective = KAP.effective_allowed_paths ~meta in
    check (list string) (scope ^ " + [*] = []") [] effective
  ) scopes

let test_explicit_paths_any_scope () =
  let paths = ["lib/keeper/"; "test/"] in
  let non_ws_expected = playground_bundle "t" @ ["lib/keeper/"; "test/"] in
  (* non-workspace scopes: playground bundle + explicit only *)
  List.iter (fun scope ->
    let meta = make_meta ~execution_scope:scope ~allowed_paths:paths ~name:"t" () in
    let effective = KAP.effective_allowed_paths ~meta in
    check (list string) (scope ^ " + explicit = playground bundle + explicit")
      non_ws_expected effective
  ) ["observe_only"; "local"];
  (* workspace scope: playground bundle + workspace defaults + explicit *)
  let ws_meta = make_meta ~execution_scope:"workspace"
      ~allowed_paths:paths ~name:"t" () in
  let ws_effective = KAP.effective_allowed_paths ~meta:ws_meta in
  check (list string) "workspace + explicit = playground bundle + ws defaults + explicit"
    (playground_bundle "t" @ workspace_defaults "t" @ ["lib/keeper/"; "test/"]) ws_effective

(* ── keeper name in computed default ── *)

let test_computed_default_uses_keeper_name () =
  let meta = make_meta ~execution_scope:"workspace"
      ~name:"cdal-formalist" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "name embedded in path"
    (playground_bundle "cdal-formalist" @
     workspace_defaults "cdal-formalist") effective

(* ── playground path ── *)

let test_playground_path_sanitizes_name () =
  let path = KAP.playground_path_of_keeper "my keeper/../../etc" in
  check string "special chars sanitized"
    ".masc/playground/my_keeper_.._.._etc/" path

let test_playground_always_present () =
  let scopes = ["observe_only"; "workspace"; "local"] in
  List.iter (fun scope ->
    let meta = make_meta ~execution_scope:scope ~name:"abc" () in
    let effective = KAP.effective_allowed_paths ~meta in
    check bool (scope ^ " has playground")
      true (List.mem ".masc/playground/abc/" effective)
  ) scopes

let test_ensure_playground_bundle_creates_subdirs () =
  let dir = Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "keeper_playground_bundle_%d" (Random.bits ())) in
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () ->
    let rec rm path =
      if Sys.file_exists path then
        if Sys.is_directory path then begin
          Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
          Unix.rmdir path
        end else Sys.remove path
    in
    rm dir
  ) (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let config = Masc_mcp.Room.default_config dir in
    let created = KAP.ensure_playground_bundle ~config ~name:"abc" in
    check int "bundle size" 3 (List.length created);
    List.iter (fun path ->
      check bool ("exists: " ^ path) true (Sys.file_exists path);
      check bool ("is_dir: " ^ path) true (Sys.is_directory path)
    ) created)

let with_temp_config f =
  with_temp_dir "keeper_default_root_" (fun dir ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    f (Masc_mcp.Room.default_config dir))

let check_default_roots_use_playground (meta : KT.keeper_meta) =
  with_temp_config (fun config ->
    let expected =
      Filename.concat
        (KAP.project_root_of_config config)
        (KAP.playground_path_of_keeper meta.name)
    in
    let write_root = KES.keeper_default_write_root ~config ~meta in
    let read_root = KES.keeper_default_read_root ~config ~meta in
    check string "default write root is playground" expected write_root;
    check string "default read root is playground" expected read_root;
    check bool "playground dir exists" true (Sys.file_exists expected);
    check bool "playground dir is directory" true (Sys.is_directory expected))

let test_default_roots_use_playground_with_explicit_paths () =
  let meta = make_meta ~execution_scope:"workspace"
      ~allowed_paths:["workspace/yousleepwhen/oas/"] ~name:"keeper" () in
  check_default_roots_use_playground meta

let test_default_roots_use_playground_with_full_access () =
  let meta = make_meta ~execution_scope:"workspace"
      ~allowed_paths:["*"] ~name:"keeper" () in
  check_default_roots_use_playground meta

let test_resolve_keeper_path_blocks_workspace_repo_write_default () =
  let meta = make_meta ~execution_scope:"workspace" ~name:"keeper" () in
  with_temp_config (fun config ->
    match KES.resolve_keeper_path ~config ~meta ~raw_path:"lib/foo.ml" with
    | Ok path -> fail ("expected write rejection, got: " ^ path)
    | Error err ->
      check bool "rejects repo-root write outside playground" true
        (String.starts_with ~prefix:"path_not_in_allowed_paths:" err))

let test_resolve_keeper_path_allows_playground_write_default () =
  let meta = make_meta ~execution_scope:"workspace" ~name:"keeper" () in
  with_temp_config (fun config ->
    let expected =
      Filename.concat
        (Filename.concat
           (KAP.project_root_of_config config)
           (KAP.playground_path_of_keeper meta.name))
        "notes.md"
    in
    match KES.resolve_keeper_path ~config ~meta ~raw_path:"notes.md" with
    | Error err -> fail ("expected playground write path, got error: " ^ err)
    | Ok path -> check string "bare file defaults into playground" expected path)

(* ── Runner ── *)

let () =
  run "keeper_allowed_paths"
    [
      ( "effective_allowed_paths",
        [
          test_case "observe_only + [] = [playground]" `Quick
            test_observe_only_empty_paths;
          test_case "observe_only + explicit = playground + explicit" `Quick
            test_observe_only_explicit_paths;
          test_case "workspace + [] = playground + computed default" `Quick
            test_workspace_empty_paths_computed_default;
          test_case "workspace + explicit = playground + explicit" `Quick
            test_workspace_explicit_paths;
          test_case "workspace write defaults stay in playground/state only" `Quick
            test_workspace_write_paths_keep_playground_and_state_only;
          test_case "workspace write defaults preserve explicit overrides" `Quick
            test_workspace_write_paths_preserve_explicit_overrides;
          test_case "workspace + [*] = full access" `Quick
            test_workspace_star_wildcard;
          test_case "local + [] = [playground]" `Quick
            test_local_empty_paths;
          test_case "[*] wildcard any scope" `Quick
            test_star_wildcard_any_scope;
          test_case "explicit paths any scope" `Quick
            test_explicit_paths_any_scope;
          test_case "keeper name in computed default" `Quick
            test_computed_default_uses_keeper_name;
        ] );
      ( "playground",
        [
          test_case "path sanitizes keeper name" `Quick
            test_playground_path_sanitizes_name;
          test_case "playground always in allowed_paths" `Quick
            test_playground_always_present;
          test_case "ensure playground bundle creates subdirs" `Quick
            test_ensure_playground_bundle_creates_subdirs;
          test_case "default roots stay in playground with explicit paths" `Quick
            test_default_roots_use_playground_with_explicit_paths;
          test_case "default roots stay in playground with full access" `Quick
            test_default_roots_use_playground_with_full_access;
          test_case "workspace repo writes blocked by default" `Quick
            test_resolve_keeper_path_blocks_workspace_repo_write_default;
          test_case "bare writes default into playground" `Quick
            test_resolve_keeper_path_allows_playground_write_default;
        ] );
    ]
