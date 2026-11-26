(** What [/api/v1/git/diff] sends for one file's git output. The TUI review
    screen jumps between hunks, so hunk headers must survive as rows, and a
    hunk body must be read by its header's counts: a deleted SQL or Lua
    comment ("-- note") prints as "--- note", which a prefix check reads as a
    file header and drops. *)

open Alcotest

module D = Git_unified_diff

let row_label = function
  | D.Hunk h ->
      Printf.sprintf "hunk -%d,%d +%d,%d %s" h.old_start h.old_count h.new_start
        h.new_count (Option.value h.section ~default:"-")
  | D.Context { old_line; new_line; text } ->
      Printf.sprintf "ctx %d %d %s" old_line new_line text
  | D.Added { new_line; text } -> Printf.sprintf "add %d %s" new_line text
  | D.Deleted { old_line; text } -> Printf.sprintf "del %d %s" old_line text

let parse_ok lines =
  match D.parse lines with
  | Ok rows -> List.map row_label rows
  | Error e -> fail e

let test_two_hunks_keep_headers_and_coordinates () =
  check (list string) "rows"
    [ "hunk -1,2 +1,2 let a ="; "del 1 old"; "add 1 new"; "ctx 2 2 keep";
      "hunk -10,1 +10,2 -"; "ctx 10 10 tail"; "add 11 more" ]
    (parse_ok
       [ "diff --git a/x.ml b/x.ml"; "index 1..2 100644"; "--- a/x.ml"; "+++ b/x.ml";
         "@@ -1,2 +1,2 @@ let a ="; "-old"; "+new"; " keep";
         "@@ -10 +10,2 @@"; " tail"; "+more" ])

let test_a_deleted_dash_dash_line_is_a_deletion () =
  check (list string) "rows"
    [ "hunk -3,2 +3,1 -"; "del 3 -- note"; "ctx 4 3 select 1;" ]
    (parse_ok [ "--- a/q.sql"; "+++ b/q.sql"; "@@ -3,2 +3,1 @@"; "--- note"; " select 1;" ])

let test_an_added_plus_plus_line_is_an_addition () =
  check (list string) "rows" [ "hunk -0,0 +1,1 -"; "add 1 ++ counter" ]
    (parse_ok [ "--- /dev/null"; "+++ b/c.txt"; "@@ -0,0 +1 @@"; "+++ counter" ])

let test_no_newline_marker_is_not_a_row () =
  check (list string) "rows" [ "hunk -1,1 +1,1 -"; "del 1 a"; "add 1 b" ]
    (parse_ok [ "@@ -1 +1 @@"; "-a"; "\\ No newline at end of file"; "+b";
                "\\ No newline at end of file" ])

let is_error lines = match D.parse lines with Ok _ -> false | Error _ -> true

let test_malformed_input_is_an_error () =
  check bool "malformed header" true (is_error [ "@@ -x +1 @@"; "+a" ]);
  check bool "body shorter than its header" true (is_error [ "@@ -1,2 +1,2 @@"; " a" ]);
  check bool "line without a marker" true (is_error [ "@@ -1 +1 @@"; "?a" ]);
  check bool "empty body line" true (is_error [ "@@ -1 +1 @@"; "" ]);
  check bool "negative count" true (is_error [ "@@ -1,-2 +1 @@"; " a" ]);
  check bool "negative start" true (is_error [ "@@ --1 +1 @@"; " a" ]);
  check bool "signed number" true (is_error [ "@@ -+1 +1 @@"; " a" ]);
  check bool "missing space before section" true (is_error [ "@@ -1 +1 @@nospace"; " a" ])

let test_json_kinds () =
  let json =
    match D.parse [ "@@ -1 +1 @@ f"; "-a"; "+b" ] with
    | Ok rows -> List.map D.row_to_json rows
    | Error e -> fail e
  in
  let kind j = Yojson.Safe.Util.(member "kind" j |> to_string) in
  check (list string) "kinds" [ "hunk"; "delete"; "add" ] (List.map kind json);
  check string "section" "f"
    Yojson.Safe.Util.(member "section" (List.hd json) |> to_string)

let () =
  run "git_unified_diff"
    [ ( "parse",
        [ test_case "two hunks" `Quick test_two_hunks_keep_headers_and_coordinates;
          test_case "deleted -- line" `Quick test_a_deleted_dash_dash_line_is_a_deletion;
          test_case "added ++ line" `Quick test_an_added_plus_plus_line_is_an_addition;
          test_case "no newline marker" `Quick test_no_newline_marker_is_not_a_row;
          test_case "malformed input" `Quick test_malformed_input_is_an_error;
          test_case "json kinds" `Quick test_json_kinds ] ) ]
