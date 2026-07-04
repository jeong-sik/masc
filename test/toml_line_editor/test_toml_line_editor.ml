(* RFC-0306 §3.2 / §6 — the reason this module exists is comment preservation:
   editing a value must leave every comment, blank, and unrelated key byte-for-byte
   unchanged. These tests fix that property for the scalar and multi-line-array
   edits the fusion settings writer depends on. *)

let fixture =
  {|# top-of-file note
[fusion]
enabled = true
# concurrency knob doc, must survive edits
max_concurrent_panels = 2

# panel roster doc line 1
# panel roster doc line 2
[fusion.presets.trio]
panel = [
  "provider.a",
  "provider.b",
]
# judge doc comment
judge = "old-judge"
judge_timeout_s = 300.0
|}

let comment_lines content =
  fst (Toml_line_editor.split_lines content)
  |> List.filter (fun line ->
         let t = String.trim line in
         String.length t > 0 && Char.equal t.[0] '#')

let has_line content target =
  List.exists (String.equal target) (fst (Toml_line_editor.split_lines content))

let check_comments_unchanged before after =
  Alcotest.(check (list string))
    "every comment line survives byte-for-byte, in order"
    (comment_lines before) (comment_lines after)

let test_scalar_edit_preserves_comments () =
  let out =
    Toml_line_editor.edit_table_scalar fixture ~path:"fusion.presets.trio"
      ~key:"judge" ~value:(Some "new-judge")
  in
  check_comments_unchanged fixture out;
  Alcotest.(check bool) "judge value replaced" true
    (has_line out {|judge = "new-judge"|});
  Alcotest.(check bool) "old judge value gone" false
    (has_line out {|judge = "old-judge"|});
  Alcotest.(check bool) "unrelated scalar untouched" true
    (has_line out "judge_timeout_s = 300.0");
  Alcotest.(check bool) "multi-line array untouched" true
    (has_line out {|  "provider.a",|})

let test_scalar_remove () =
  let out =
    Toml_line_editor.edit_table_scalar fixture ~path:"fusion.presets.trio"
      ~key:"judge" ~value:None
  in
  check_comments_unchanged fixture out;
  Alcotest.(check bool) "judge key removed" false
    (has_line out {|judge = "old-judge"|});
  Alcotest.(check bool) "sibling scalar retained" true
    (has_line out "judge_timeout_s = 300.0")

let test_multiline_array_edit_preserves_comments () =
  let out =
    Toml_line_editor.edit_table_multiline_array fixture ~path:"fusion.presets.trio"
      ~key:"panel" ~values:[ "provider.x"; "provider.y"; "provider.z" ]
  in
  check_comments_unchanged fixture out;
  List.iter
    (fun model ->
      Alcotest.(check bool) (Printf.sprintf "new panel model %s present" model) true
        (has_line out (Printf.sprintf {|  "%s",|} model)))
    [ "provider.x"; "provider.y"; "provider.z" ];
  Alcotest.(check bool) "old panel model dropped" false
    (has_line out {|  "provider.a",|});
  Alcotest.(check bool) "array framing kept" true (has_line out "panel = [");
  Alcotest.(check bool) "sibling scalar untouched" true
    (has_line out {|judge = "old-judge"|})

(* The scalar editor must target the right table: [max_concurrent_panels] exists
   in [fusion] and must not be touched when editing [fusion.presets.trio]. *)
let test_scalar_edit_is_table_scoped () =
  let out =
    Toml_line_editor.edit_table_scalar fixture ~path:"fusion.presets.trio"
      ~key:"judge" ~value:(Some "new-judge")
  in
  Alcotest.(check bool) "[fusion] scalar untouched" true
    (has_line out "max_concurrent_panels = 2")

let () =
  Alcotest.run "toml_line_editor"
    [ ( "comment-preserving edits"
      , [ Alcotest.test_case "scalar edit preserves comments" `Quick
            test_scalar_edit_preserves_comments
        ; Alcotest.test_case "scalar remove" `Quick test_scalar_remove
        ; Alcotest.test_case "multi-line array edit preserves comments" `Quick
            test_multiline_array_edit_preserves_comments
        ; Alcotest.test_case "scalar edit is table-scoped" `Quick
            test_scalar_edit_is_table_scoped
        ] )
    ]
