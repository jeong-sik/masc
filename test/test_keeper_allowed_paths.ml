(** Test suite for Keeper_alerting_path.effective_allowed_paths.
    Verifies computed defaults, wildcard handling, and scope-based behavior. *)

open Alcotest
module KAP = Masc_mcp.Keeper_alerting_path
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

let workspace_defaults name =
  [ Printf.sprintf ".masc/keepers/%s/" name;
    ".masc/traces/";
    ".worktrees/";
    "lib/"; "test/"; "config/"; "bin/"; "scripts/"; "docs/" ]

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
        ] );
    ]
