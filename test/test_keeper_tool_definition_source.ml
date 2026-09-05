(* Which file defines a tool has two shipped answers and one honest silence.
   The resolver exists because both readers that want the answer — the
   post-tool log line and the tool-call inspector — used to try the two
   lookups in their own order, and an order copied is an order that drifts. *)

module Source = Masc.Keeper_tool_definition_source

let test_shipped_tool_names_its_toml () =
  match Source.resolve "keeper_broadcast" with
  | Some rel ->
    Alcotest.(check string)
      "shipped descriptor path"
      "tools/keeper_broadcast.toml"
      rel
  | None -> Alcotest.fail "a shipped tool must name the TOML it was read from"
;;

let test_composition_tool_names_its_skill () =
  match Source.resolve "keeper_compose_mission-snapshot" with
  | Some rel ->
    Alcotest.(check string)
      "composition definition path"
      "skills/mission-snapshot/SKILL.md"
      rel
  | None -> Alcotest.fail "a composition tool must name the SKILL.md that made it"
;;

(* [Execute] ships neither a TOML nor a skill fence. [None] is the answer for
   a built-in, not a lookup that gave up: a reader that renders "-" here is
   telling the operator there is no file to open. *)
let test_builtin_names_no_file () =
  match Source.resolve "Execute" with
  | None -> ()
  | Some rel -> Alcotest.failf "Execute ships no definition file, got %s" rel
;;

let test_unknown_name_names_no_file () =
  match Source.resolve "not_a_tool_at_all" with
  | None -> ()
  | Some rel -> Alcotest.failf "an unknown name has no definition file, got %s" rel
;;

let row_of tool = `Assoc [ ("ts", `Float 1.0); ("tool", `String tool) ]

let definition_source_of = function
  | `Assoc fields -> List.assoc_opt "definition_source" fields
  | _ -> None
;;

let test_annotate_adds_the_path () =
  match definition_source_of (Source.annotate_row (row_of "keeper_broadcast")) with
  | Some (`String rel) ->
    Alcotest.(check string)
      "annotated path"
      "tools/keeper_broadcast.toml"
      rel
  | Some _ | None -> Alcotest.fail "a row naming a shipped tool must carry its file"
;;

(* The field is absent rather than null or "-": a reader distinguishes "no
   file ships this" from "the projection did not run" by whether the key is
   there at all, and a null would make those two look the same. *)
let test_annotate_leaves_a_builtin_row_alone () =
  let row = row_of "Execute" in
  Alcotest.(check bool)
    "builtin row is unchanged"
    true
    (Source.annotate_row row = row)
;;

let test_annotate_leaves_a_row_without_a_tool_alone () =
  let row = `Assoc [ ("ts", `Float 1.0) ] in
  Alcotest.(check bool)
    "row with no tool name is unchanged"
    true
    (Source.annotate_row row = row)
;;

let test_annotate_leaves_a_non_object_alone () =
  Alcotest.(check bool)
    "a non-object row is unchanged"
    true
    (Source.annotate_row (`String "not a row") = `String "not a row")
;;

let () =
  Alcotest.run
    "keeper_tool_definition_source"
(* A deferred tool is chosen from one line. The listing shows
   [Keeper_identity_tool_search.summary_of], which takes the first line of the
   description and cuts it at the summary budget, so a description whose first
   line runs on is offered to the model ending mid-sentence.

   Twenty-nine of the fifty-five deferred tools were in that state when this
   was written; [masc_fusion] had no newline at all, so its whole opening
   paragraph was the first line. [keeper_code_query] was the measurable cost:
   the fleet called it ten times in September with a search-shaped argument it
   does not take, and every call failed.

   The budget lives in the summariser, so this asks the summariser instead of
   repeating the number here. *)
let test_a_deferred_tool_is_offered_a_whole_sentence () =
  let cut =
    List.filter_map
      (fun path ->
         match Filename.dirname path, Filename.extension path with
         | "tools", ".toml" ->
           let name = Filename.remove_extension (Filename.basename path) in
           (match Embedded_config.read path with
            | None -> None
            | Some contents ->
              (match Tool_definition_toml.load ~name ~contents with
               | Error message -> Some (name ^ ": " ^ message)
               | Ok { Tool_definition_toml.schema; loading; _ } ->
                 (match loading with
                  | Tool_definition_toml.Always_loaded -> None
                  | Tool_definition_toml.Deferrable ->
                    let description = schema.Masc_domain.description in
                    let first_line =
                      match String.index_opt description '\n' with
                      | Some newline -> String.sub description 0 newline
                      | None -> description
                    in
                    let first_line = String.trim first_line in
                    let offered =
                      Masc.Keeper_identity_tool_search.summary_of description
                    in
                    if String.equal offered first_line
                    then None
                    else
                      Some
                        (Printf.sprintf
                           "%s: first line is %d bytes, offered as %S"
                           name
                           (String.length first_line)
                           offered))))
         | _, _ -> None)
      Embedded_config.file_list
  in
  match cut with
  | [] -> ()
  | _ ->
    Alcotest.failf
      "a deferred tool is chosen from its first line; these are cut:\n  %s"
      (String.concat "\n  " cut)
;;

    [ ( "deferred summary"
      , [ Alcotest.test_case "a whole sentence is offered" `Quick
            test_a_deferred_tool_is_offered_a_whole_sentence
        ] )
    ; ( "resolve"
      , [ Alcotest.test_case "shipped tool names its toml" `Quick
            test_shipped_tool_names_its_toml
        ; Alcotest.test_case "composition tool names its skill" `Quick
            test_composition_tool_names_its_skill
        ; Alcotest.test_case "builtin names no file" `Quick test_builtin_names_no_file
        ; Alcotest.test_case "unknown name names no file" `Quick
            test_unknown_name_names_no_file
        ] )
    ; ( "annotate_row"
      , [ Alcotest.test_case "adds the path" `Quick test_annotate_adds_the_path
        ; Alcotest.test_case "builtin row unchanged" `Quick
            test_annotate_leaves_a_builtin_row_alone
        ; Alcotest.test_case "row without a tool unchanged" `Quick
            test_annotate_leaves_a_row_without_a_tool_alone
        ; Alcotest.test_case "non-object unchanged" `Quick
            test_annotate_leaves_a_non_object_alone
        ] )
    ]
;;
