open Alcotest
open Skill_source_config

let parse_exn text =
  match parse_text text with
  | Ok config -> config
  | Error diagnostics ->
    fail (String.concat "; " (List.map diagnostic_to_string diagnostics))
;;

let test_absent_section_is_empty () =
  let config = parse_exn "[runtime]\ndefault = \"provider.model\"\n" in
  check int "no implicit sources" 0 (List.length config.sources);
  check string
    "session lifetime"
    "session"
    (activation_lifetime_to_string config.activation_lifetime)
;;

let ordered_sources =
  {|[skills]
activation-lifetime = "session"

[[skills.sources]]
id = "project"
anchor = "base-path"
path = ".agents/skills"
access = "read-only"

[[skills.sources]]
id = "personal"
anchor = "user-home"
path = ".masc/skills"
access = "read-write"
|}
;;

let test_order_and_resolution () =
  let config = parse_exn ordered_sources in
  check
    (list string)
    "declaration order"
    [ "project"; "personal" ]
    (List.map (fun source -> source_id_to_string source.id) config.sources);
  match config.sources with
  | [ project; personal ] ->
    (match resolve ~base_path:"/work/project" ~user_home:None project with
     | { resolution = Resolved path; _ } ->
       check string "base path resolution" "/work/project/.agents/skills" path
     | _ -> fail "project source did not resolve");
    (match resolve ~base_path:"/work/project" ~user_home:None personal with
     | { resolution = Anchor_unavailable User_home; _ } -> ()
     | _ -> fail "missing HOME must stay visible on the source")
  | _ -> fail "expected two sources"
;;

let expect_error text predicate =
  match parse_text text with
  | Ok _ -> fail "invalid Skill source config was accepted"
  | Error diagnostics ->
    check bool "expected typed diagnostic" true (List.exists predicate diagnostics)
;;

let source ?(id = "one") ?(anchor = "base-path") ?(path = "skills")
    ?(access = "read-only") extra
  =
  Printf.sprintf
    "[[skills.sources]]\nid = %S\nanchor = %S\npath = %S\naccess = %S\n%s"
    id
    anchor
    path
    access
    extra
;;

let test_duplicate_and_unexpected_fields () =
  expect_error
    (source "" ^ "\n" ^ source "")
    (function
      | Duplicate_source_id _ -> true
      | _ -> false);
  expect_error
    (source "priority = 1\n")
    (function
      | Unexpected_source_field { field = "priority"; _ } -> true
      | _ -> false)
;;

let test_missing_and_wrong_fields () =
  expect_error
    "[[skills.sources]]\nid = \"one\"\nanchor = \"base-path\"\naccess = \"read-only\"\n"
    (function
      | Missing_source_field { field = Path; _ } -> true
      | _ -> false);
  expect_error
    "[[skills.sources]]\nid = 1\nanchor = \"base-path\"\npath = \"skills\"\naccess = \"read-only\"\n"
    (function
      | Invalid_source_field_type { field = Id; actual = Integer; _ } -> true
      | _ -> false)
;;

let test_anchor_and_path_rules () =
  expect_error
    (source ~anchor:"workspace" "")
    (function
      | Unsupported_anchor _ -> true
      | _ -> false);
  expect_error
    (source ~path:"../skills" "")
    (function
      | Invalid_source_path { rejection = Parent_directory_component; _ } -> true
      | _ -> false);
  expect_error
    (source ~anchor:"absolute" ~path:"relative/skills" "")
    (function
      | Invalid_source_path { rejection = Expected_absolute; _ } -> true
      | _ -> false);
  let absolute = parse_exn (source ~anchor:"absolute" ~path:"/srv/./masc/../skills" "") in
  match absolute.sources with
  | [ source ] ->
    (match resolve ~base_path:"unused" ~user_home:None source with
     | { resolution = Resolved path; _ } ->
       check string "lexical normalization" "/srv/skills" path
     | _ -> fail "absolute source did not resolve")
  | _ -> fail "expected one absolute source"
;;

let rec repo_root_from directory =
  let candidate = Filename.concat directory "dune-project" in
  if Sys.file_exists candidate
  then directory
  else
    let parent = Filename.dirname directory in
    if String.equal parent directory
    then fail "could not locate repository root"
    else repo_root_from parent
;;

let test_seed_declares_sources () =
  let root = repo_root_from (Sys.getcwd ()) in
  let path = Filename.concat root "config/runtime.toml" in
  let channel = open_in_bin path in
  let text =
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> really_input_string channel (in_channel_length channel))
  in
  let config = parse_exn text in
  let projected =
    List.map
      (fun source ->
         String.concat
           "|"
           [ source_id_to_string source.id
           ; anchor_to_string source.anchor
           ; source.configured_path
           ; access_to_string source.access
           ])
      config.sources
  in
  check
    (list string)
    "seed order and values"
    [ "project-masc|base-path|.masc/skills|read-write"
    ; "project-agents|base-path|.agents/skills|read-only"
    ; "user-masc|user-home|.masc/skills|read-write"
    ; "user-agents|user-home|.agents/skills|read-only"
    ]
    projected
;;

let () =
  run
    "skill_source_config"
    [ ( "config"
      , [ test_case "absent section" `Quick test_absent_section_is_empty
        ; test_case "ordered resolution" `Quick test_order_and_resolution
        ; test_case "duplicates and unknown fields" `Quick
            test_duplicate_and_unexpected_fields
        ; test_case "missing and wrong fields" `Quick test_missing_and_wrong_fields
        ; test_case "anchor and path rules" `Quick test_anchor_and_path_rules
        ; test_case "seed declares sources" `Quick test_seed_declares_sources
        ] )
    ]
;;
