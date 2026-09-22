open Alcotest

module Prim = Masc_tui_render_prim

let said ~root path = Prim.path_from_root ~root path

(* The Config panes read one file, and the title row beside the strip was
   printing its whole address. The prefix is the server's masc root -- the same
   for every screen in the session, and named in the Config pane's own identity
   row -- so the row ran past the frame and was cut in the middle:
   "/Users/d\xe2\x80\xa6onfig/runtime.toml", where neither end is the file. *)
let test_a_path_under_the_root_is_said_from_it () =
  check string "the root leaves and the file stays" "config/runtime.toml"
    (said ~root:"/Users/dancer/me/.masc" "/Users/dancer/me/.masc/config/runtime.toml")

(* A directory beside the root whose name begins with the root's is not under
   it. Compared as plain text the prefix matches and the reading would come out
   as a path with no leading separator, which is a different file. *)
let test_a_sibling_that_begins_with_the_root_is_not_under_it () =
  check string "the sibling keeps its whole address" "/a/bc/runtime.toml"
    (said ~root:"/a/b" "/a/bc/runtime.toml")

(* A file the server reads from outside its root: there the address is the
   news, and it is what the row says. *)
let test_a_path_outside_the_root_keeps_its_address () =
  check string "an unrelated path is whole" "/etc/masc/runtime.toml"
    (said ~root:"/Users/dancer/me/.masc" "/etc/masc/runtime.toml")

(* Until the server has said where its root is there is nothing to say the
   path from. *)
let test_no_root_leaves_the_path_whole () =
  check string "an empty root changes nothing" "/a/b/runtime.toml"
    (said ~root:"" "/a/b/runtime.toml")

let () =
  run "tui config path"
    [ ( "path from root"
      , [ test_case "a path under the root is said from it" `Quick
            test_a_path_under_the_root_is_said_from_it
        ; test_case "a sibling that begins with the root is not under it"
            `Quick test_a_sibling_that_begins_with_the_root_is_not_under_it
        ; test_case "a path outside the root keeps its address" `Quick
            test_a_path_outside_the_root_keeps_its_address
        ; test_case "no root leaves the path whole" `Quick
            test_no_root_leaves_the_path_whole
        ] )
    ]
