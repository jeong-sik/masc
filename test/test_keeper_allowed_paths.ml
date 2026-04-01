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

(* ── observe_only scope ── *)

let test_observe_only_empty_paths () =
  let meta = make_meta ~execution_scope:"observe_only" ~name:"t" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "observe_only + [] = []" [] effective

let test_observe_only_explicit_paths () =
  let meta = make_meta ~execution_scope:"observe_only"
      ~allowed_paths:["src/"; "lib/"] ~name:"t" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "observe_only + explicit = explicit"
    ["src/"; "lib/"] effective

(* ── workspace scope ── *)

let test_workspace_empty_paths_computed_default () =
  let meta = make_meta ~execution_scope:"workspace"
      ~name:"sangsu" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "workspace + [] = computed default"
    [".masc/keepers/sangsu/"; ".masc/traces/"] effective

let test_workspace_explicit_paths () =
  let meta = make_meta ~execution_scope:"workspace"
      ~allowed_paths:["src/"; "docs/"] ~name:"t" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "workspace + explicit = explicit"
    ["src/"; "docs/"] effective

let test_workspace_star_wildcard () =
  let meta = make_meta ~execution_scope:"workspace"
      ~allowed_paths:["*"] ~name:"t" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "workspace + [*] = [] (full access)" [] effective

(* ── local scope ── *)

let test_local_empty_paths () =
  let meta = make_meta ~execution_scope:"local" ~name:"t" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "local + [] = []" [] effective

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
  let scopes = ["observe_only"; "workspace"; "local"] in
  List.iter (fun scope ->
    let meta = make_meta ~execution_scope:scope ~allowed_paths:paths ~name:"t" () in
    let effective = KAP.effective_allowed_paths ~meta in
    check (list string) (scope ^ " + explicit = explicit") paths effective
  ) scopes

(* ── keeper name in computed default ── *)

let test_computed_default_uses_keeper_name () =
  let meta = make_meta ~execution_scope:"workspace"
      ~name:"cdal-formalist" () in
  let effective = KAP.effective_allowed_paths ~meta in
  check (list string) "name embedded in path"
    [".masc/keepers/cdal-formalist/"; ".masc/traces/"] effective

(* ── Runner ── *)

let () =
  run "keeper_allowed_paths"
    [
      ( "effective_allowed_paths",
        [
          test_case "observe_only + [] = []" `Quick
            test_observe_only_empty_paths;
          test_case "observe_only + explicit = explicit" `Quick
            test_observe_only_explicit_paths;
          test_case "workspace + [] = computed default" `Quick
            test_workspace_empty_paths_computed_default;
          test_case "workspace + explicit = explicit" `Quick
            test_workspace_explicit_paths;
          test_case "workspace + [*] = full access" `Quick
            test_workspace_star_wildcard;
          test_case "local + [] = []" `Quick
            test_local_empty_paths;
          test_case "[*] wildcard any scope" `Quick
            test_star_wildcard_any_scope;
          test_case "explicit paths any scope" `Quick
            test_explicit_paths_any_scope;
          test_case "keeper name in computed default" `Quick
            test_computed_default_uses_keeper_name;
        ] );
    ]
