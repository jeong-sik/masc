open Agent_core

let skill_exn ~name ~description body =
  let source =
    Printf.sprintf "---\nname: %s\ndescription: %s\n---\n%s" name description body
  in
  match Skill_document.decode ~directory_name:name source with
  | Loaded document -> document
  | Unloadable diagnostics ->
    Alcotest.fail
      (String.concat "; " (List.map Skill_document.diagnostic_to_string diagnostics))
;;

let skill_a = skill_exn ~name:"greet" ~description:"Say hello" "Hello"
let skill_b = skill_exn ~name:"review" ~description:"Review code" "Review the code"
let skill_c = skill_exn ~name:"deploy" ~description:"Deploy safely" "Deploy"

let test_create_empty () =
  let registry = Skill_registry.create () in
  Alcotest.(check int) "empty count" 0 (Skill_registry.count registry);
  Alcotest.(check (list string)) "empty names" [] (Skill_registry.names registry)
;;

let test_register_find_and_overwrite () =
  let registry = Skill_registry.create () in
  Skill_registry.register registry skill_a;
  Alcotest.(check int) "count" 1 (Skill_registry.count registry);
  (match Skill_registry.find registry "greet" with
   | Some skill -> Alcotest.(check string) "body" "Hello" skill.body
   | None -> Alcotest.fail "registered skill missing");
  let updated = skill_exn ~name:"greet" ~description:"Updated greeting" "Hi" in
  Skill_registry.register registry updated;
  Alcotest.(check int) "overwrite keeps count" 1 (Skill_registry.count registry);
  match Skill_registry.find registry "greet" with
  | Some skill ->
    Alcotest.(check string) "updated description" "Updated greeting" skill.description
  | None -> Alcotest.fail "updated skill missing"
;;

let test_sorted_list_and_remove () =
  let registry = Skill_registry.create () in
  List.iter (Skill_registry.register registry) [ skill_c; skill_a; skill_b ];
  let names =
    Skill_registry.list registry
    |> List.map (fun (skill : Skill_document.t) -> skill.name)
  in
  Alcotest.(check (list string))
    "alphabetical"
    [ "deploy"; "greet"; "review" ]
    names;
  Skill_registry.remove registry "greet";
  Skill_registry.remove registry "missing";
  Alcotest.(check (list string))
    "remaining"
    [ "deploy"; "review" ]
    (Skill_registry.names registry)
;;

let test_json_projection () =
  let registry = Skill_registry.create () in
  let skill =
    match
      Skill_document.decode
        ~directory_name:"inspect"
        "---\nname: inspect\ndescription: Inspect state\nlicense: MIT\nmetadata:\n  owner: masc\n---\nInspect exactly."
    with
    | Loaded document -> document
    | Unloadable diagnostics ->
      Alcotest.fail
        (String.concat "; " (List.map Skill_document.diagnostic_to_string diagnostics))
  in
  Skill_registry.register registry skill;
  let open Yojson.Safe.Util in
  let json = Skill_registry.to_json registry in
  Alcotest.(check int) "count" 1 (json |> member "count" |> to_int);
  let projected = json |> member "skills" |> to_list |> List.hd in
  Alcotest.(check string) "name" "inspect" (projected |> member "name" |> to_string);
  Alcotest.(check string)
    "description"
    "Inspect state"
    (projected |> member "description" |> to_string);
  Alcotest.(check string)
    "body"
    "Inspect exactly."
    (projected |> member "body" |> to_string);
  Alcotest.(check string)
    "metadata"
    "masc"
    (projected |> member "metadata" |> member "owner" |> to_string);
  ()
;;

let () =
  let open Alcotest in
  run
    "Skill_registry"
    [ ( "registry"
      , [ test_case "create empty" `Quick test_create_empty
        ; test_case "register, find, overwrite" `Quick test_register_find_and_overwrite
        ; test_case "sorted list and remove" `Quick test_sorted_list_and_remove
        ; test_case "JSON projection" `Quick test_json_projection
        ] )
    ]
;;
