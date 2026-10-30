open Alcotest

module L = Keeper_toml_loader

let doc =
  [ "keeper.name", L.Toml_string "alpha"
  ; "keeper.turns", L.Toml_int 7
  ; "keeper.temperature", L.Toml_float 0.2
  ; "keeper.enabled", L.Toml_bool true
  ; "keeper.models", L.Toml_string_array [ "fast"; "slow" ]
  ]
;;

let test_accessors () =
  check (option string) "string" (Some "alpha") (L.toml_string_opt doc "keeper.name");
  check (option int) "int" (Some 7) (L.toml_int_opt doc "keeper.turns");
  check bool "float from int"
    true
    (match L.toml_float_opt doc "keeper.turns" with
     | Some value -> Float.equal value 7.0
     | None -> false);
  check bool "bool"
    true
    (match L.toml_bool_opt doc "keeper.enabled" with
     | Some true -> true
     | _ -> false);
  check (list string) "array" [ "fast"; "slow" ]
    (L.toml_string_list doc "keeper.models")
;;

let test_update_field_in_content_preserves_table () =
  let content = "[keeper]\nname = \"old\"\n\n[other]\nname = \"keep\"\n" in
  match L.update_field_in_content ~table:"keeper" ~key:"name" ~value:"new" content with
  | Error msg -> fail msg
  | Ok updated ->
    check bool "updates target table" true
      (String.contains updated 'n'
       && String.starts_with ~prefix:"[keeper]\nname = \"new\"" updated);
    check bool "keeps other table" true
      (String.contains updated '['
       && String.ends_with ~suffix:"[other]\nname = \"keep\"\n" updated)
;;

let with_temp_toml content f =
  let path = Filename.temp_file "keeper-toml-loader" ".toml" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Out_channel.with_open_bin path (fun channel -> output_string channel content);
      f path)
;;

let test_nested_table_edits_follow_semantic_path () =
  with_temp_toml
    "[keeper]\nname = \"probe\"\nmention_targets = [\"fs\"]\n\n[keeper.skills]\nnames = [\"old\"]\n\n[keeper.tools]\nnative = \"read\"\n"
    (fun path ->
      let edit fields =
        match L.edit_keeper_toml_fields_strict_staged ~path fields with
        | Ok () -> ()
        | Error error -> fail (Fs_compat.atomic_replace_failure_to_string error)
      in
      edit
        [ "skills.names", L.Set (L.Toml_string_array [ "ocaml-coding" ])
        ; "mention_targets", L.Set (L.Toml_string_array [ "core"; "fs" ])
        ];
      let parse label =
        let content = In_channel.with_open_bin path In_channel.input_all in
        match L.parse_toml content with
        | Ok doc -> doc
        | Error error -> failf "%s: %s" label error
      in
      let updated = parse "updated nested tables" in
      check (list string) "nested Skill updated" [ "ocaml-coding" ]
        (L.toml_string_list updated "keeper.skills.names");
      check (list string) "sibling array updated" [ "core"; "fs" ]
        (L.toml_string_list updated "keeper.mention_targets");
      check (option string) "unrelated nested tool field preserved" (Some "read")
        (L.toml_string_opt updated "keeper.tools.native");
      edit [ "skills.names", L.Remove ];
      let removed = parse "removed nested key" in
      check bool "nested Skill key removed" true
        (List.assoc_opt "keeper.skills.names" removed = None);
      check (list string) "sibling array survives removal" [ "core"; "fs" ]
        (L.toml_string_list removed "keeper.mention_targets"))
;;

let test_dotted_assignments_follow_semantic_path () =
  with_temp_toml
    "[keeper]\nskills.names = [\"old\"]\nmention_targets = [\"fs\"]\ntools.native = \"read\"\n"
    (fun path ->
      (match
         L.edit_keeper_toml_fields_strict_staged
           ~path
           [ "skills.names", L.Set (L.Toml_string_array [])
           ; "mention_targets", L.Set (L.Toml_string_array [ "core" ])
           ]
       with
       | Ok () -> ()
       | Error error -> fail (Fs_compat.atomic_replace_failure_to_string error));
      let content = In_channel.with_open_bin path In_channel.input_all in
      match L.parse_toml content with
      | Error error -> fail error
      | Ok doc ->
        check (list string) "dotted Skill updated" []
          (L.toml_string_list doc "keeper.skills.names");
        check (list string) "dotted sibling array updated" [ "core" ]
          (L.toml_string_list doc "keeper.mention_targets");
        check (option string) "dotted native posture preserved" (Some "read")
          (L.toml_string_opt doc "keeper.tools.native"))
;;

let () =
  run
    "Keeper_toml_loader"
    [ ( "accessors", [ test_case "toml accessors" `Quick test_accessors ] )
    ; ( "writer"
      , [ test_case
            "update field in target table"
            `Quick
            test_update_field_in_content_preserves_table
        ; test_case
            "nested table edits follow semantic paths"
            `Quick
            test_nested_table_edits_follow_semantic_path
        ; test_case
            "dotted assignments follow semantic paths"
            `Quick
            test_dotted_assignments_follow_semantic_path
        ] )
    ]
;;
