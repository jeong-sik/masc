open Alcotest

module Tool_table = Masc_tui_tool_table

let width = Masc_tui_message_layout.display_width

let index_of needle text =
  let text_length = String.length text in
  let needle_length = String.length needle in
  let rec walk index =
    if index + needle_length > text_length then None
    else if String.sub text index needle_length = needle then Some index
    else walk (index + 1)
  in
  walk 0

(* Where a reading starts, counted in display cells rather than bytes. *)
let starts needle text =
  match index_of needle text with
  | Some index -> width (String.sub text 0 index)
  | None -> failf "%S is not in %S" needle text

(* An MCP tool name is longer than either table's name column, and it is what
   these tables draw all day. *)
let long_name = "mcp__claude_ai_Atlassian__getJiraIssueTypeMetaWithFields"

let check_column label reading ~header ~row =
  check int
    (Printf.sprintf "%s starts where its column does" label)
    (starts label header) (starts reading row)

(* The header named the columns and the rows filled them from two format
   strings, which is how the catalog came to indent its header three cells and
   its rows six. Both come from one description now, and this is the property
   that says so. *)
let test_catalog_header_and_rows_share_their_offsets () =
  let header = Tool_table.catalog_tool_header in
  let row =
    Tool_table.catalog_tool_line ~metadata:"" ~name:"N" ~direct:"D"
      ~surfaces:"S"
  in
  check_column "TOOL" "N" ~header ~row;
  check_column "DIRECT" "D" ~header ~row;
  check_column "SURFACES" "S" ~header ~row

let test_effective_header_and_rows_share_their_offsets () =
  let header = Tool_table.effective_tool_header in
  let row = Tool_table.effective_tool_line ~name:"N" ~origin:"O" in
  check_column "TOOL" "N" ~header ~row;
  check_column "ORIGIN" "O" ~header ~row

(* A name past its column is folded, not allowed to widen it: the columns
   after it stay where the header put them. This is the row an operator sees
   most -- every MCP tool is one. *)
let test_a_long_name_does_not_move_the_columns () =
  let header = Tool_table.catalog_tool_header in
  let ordinary =
    Tool_table.catalog_tool_line ~metadata:"" ~name:"masc_status" ~direct:"D"
      ~surfaces:"S"
  in
  let overlong =
    Tool_table.catalog_tool_line ~metadata:"" ~name:long_name ~direct:"D"
      ~surfaces:"S"
  in
  check int "DIRECT does not move" (starts "D" ordinary) (starts "D" overlong);
  check int "SURFACES does not move" (starts "S" ordinary)
    (starts "S" overlong);
  check int "and DIRECT is still under its header" (starts "DIRECT" header)
    (starts "D" overlong);
  let effective_header = Tool_table.effective_tool_header in
  let effective =
    Tool_table.effective_tool_line ~name:long_name ~origin:"O"
  in
  check int "ORIGIN is still under its header" (starts "ORIGIN" effective_header)
    (starts "O" effective)

(* The dress belongs to the two columns that answer about the tool, not to the
   name being answered about: a tool on no surface is unreachable, and the
   warning starts where that is said. *)
let test_the_metadata_dress_starts_at_direct () =
  let row =
    Tool_table.catalog_tool_line ~metadata:"\027[33m" ~name:"masc_status"
      ~direct:"yes" ~surfaces:"none"
  in
  check bool "the name is not dressed" true
    (starts "\027[33m" row > starts "masc_status" row);
  check bool "and the last column is" true
    (Option.is_some (index_of ("\027[33m" ^ "none") row))

(* A dressed row occupies the same cells as an undressed one, so a warning
   cannot move a column. *)
let test_a_dressed_row_is_as_wide_as_a_plain_one () =
  let plain =
    Tool_table.catalog_tool_line ~metadata:"" ~name:"masc_status" ~direct:"yes"
      ~surfaces:"none"
  in
  let dressed =
    Tool_table.catalog_tool_line ~metadata:"\027[33m" ~name:"masc_status"
      ~direct:"yes" ~surfaces:"none"
  in
  check int "same display width" (width plain) (width dressed)

(* Skill usage stacks rather than columns, and the header stands where each
   reading stands rather than naming a column over the first line's trailing
   spaces. *)
let test_skill_usage_indents_differ_by_the_nesting () =
  check bool "the keeper line is indented past the skill it belongs to" true
    (String.length Tool_table.skill_usage_keeper_indent
     > String.length Tool_table.skill_usage_name_indent)

let () =
  run "tui tool table"
    [ ( "columns"
      , [ test_case "catalog header and rows share their offsets" `Quick
            test_catalog_header_and_rows_share_their_offsets
        ; test_case "effective header and rows share their offsets" `Quick
            test_effective_header_and_rows_share_their_offsets
        ; test_case "a long name does not move the columns" `Quick
            test_a_long_name_does_not_move_the_columns
        ; test_case "the metadata dress starts at direct" `Quick
            test_the_metadata_dress_starts_at_direct
        ; test_case "a dressed row is as wide as a plain one" `Quick
            test_a_dressed_row_is_as_wide_as_a_plain_one
        ; test_case "skill usage indents differ by the nesting" `Quick
            test_skill_usage_indents_differ_by_the_nesting
        ] )
    ]
