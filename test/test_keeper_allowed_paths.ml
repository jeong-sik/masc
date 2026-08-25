open Alcotest

module KAP = Masc.Keeper_alerting_path
module KTU = Masc.Keeper_turn_up_args

let make_meta ?(allowed_paths = []) ~name () =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("trace_id", `String ("trace-" ^ name));
        ("allowed_paths", `List (List.map (fun path -> `String path) allowed_paths));
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> fail ("make_meta: " ^ err)

let sandbox_roots meta =
  [ KAP.sandbox_path_of_meta ~meta ]

(* Read carries the skills tree, write does not. The two lists were byte
   identical until the prompt's "read it before you use it" was found to be
   unenforceable; keeping them apart here is what stops them collapsing back. *)
let skills_rel = Common.skills_rel

let test_empty_paths_default_to_sandbox_root () =
  let meta = make_meta ~name:"keeper" () in
  check (list string) "default read paths carry the skills tree"
    (skills_rel :: sandbox_roots meta)
    (KAP.effective_allowed_paths ~meta);
  check (list string) "default write paths do not" (sandbox_roots meta)
    (KAP.effective_write_allowed_paths ~meta)

let test_explicit_paths_append_to_sandbox_root () =
  let meta = make_meta ~name:"keeper" ~allowed_paths:["src/"; "docs/"] () in
  check (list string) "read paths append explicit entries"
    ((skills_rel :: sandbox_roots meta) @ [ "src/"; "docs/" ])
    (KAP.effective_allowed_paths ~meta);
  check (list string) "write paths append explicit entries"
    (sandbox_roots meta @ [ "src/"; "docs/" ])
    (KAP.effective_write_allowed_paths ~meta)

(* The prompt names this exact path. If the allowlist stops covering it the
   keeper is told to read a file it cannot open, which is the state this
   change ends. *)
let test_skills_tree_is_readable_not_writable () =
  let meta = make_meta ~name:"keeper" () in
  check bool "skills tree is readable" true
    (List.mem skills_rel (KAP.effective_allowed_paths ~meta));
  check bool "skills tree is not writable" false
    (List.mem skills_rel (KAP.effective_write_allowed_paths ~meta))

let test_playground_path_sanitizes_name () =
  let path = KAP.playground_path_of_keeper "my keeper/../../etc" in
  check string "special chars sanitized"
    ".masc/playground/my_keeper_.._.._etc/" path

let test_validate_rejects_star_wildcard () =
  match KTU.validate_sandbox_settings ~allowed_paths:[ "*" ] with
  | Ok () -> fail "expected wildcard rejection"
  | Error err ->
      check string "explicit rejection message"
        "allowed_paths=[\"*\"] is not supported; enumerate explicit paths instead"
        err

let test_validate_rejects_globs_and_traversal () =
  match
    KTU.validate_sandbox_settings
      ~allowed_paths:[ "workspace/../outside"; "logs/*.txt" ]
  with
  | Ok () -> fail "expected path-shape rejection"
  | Error err ->
      check bool "error mentions rejected path" true
        (String_util.contains_substring err "workspace/../outside");
      check bool "error mentions glob" true
        (String_util.contains_substring err "logs/*.txt")

let test_validate_accepts_plain_paths () =
  match
    KTU.validate_sandbox_settings
      ~allowed_paths:[ "workspace/outside"; ".masc/playground/keeper/" ]
  with
  | Ok () -> ()
  | Error err -> fail ("expected plain paths to validate: " ^ err)


let () =
  run "Keeper_allowed_paths"
    [
      ( "effective_paths",
        [
          test_case "empty paths default to sandbox root" `Quick
            test_empty_paths_default_to_sandbox_root;
          test_case "explicit paths append to sandbox root" `Quick
            test_explicit_paths_append_to_sandbox_root;
          test_case "playground path sanitizes name" `Quick
            test_playground_path_sanitizes_name;
        ] );
      ( "validation",
        [
          test_case "skills tree readable, not writable" `Quick
            test_skills_tree_is_readable_not_writable;
          test_case "rejects wildcard full access" `Quick
            test_validate_rejects_star_wildcard;
          test_case "rejects globs and traversal" `Quick
            test_validate_rejects_globs_and_traversal;
          test_case "accepts plain paths" `Quick
            test_validate_accepts_plain_paths;
        ] );
    ]
