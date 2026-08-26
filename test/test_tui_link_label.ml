(* A link's name, read out of the link. The rule is only worth having if it is
   right about the shapes masc actually trades in, and silent about the ones
   it cannot read -- a wrong label is worse than none, since a reader who
   trusts it stops opening the link. *)

open Alcotest

let label = Masc_tui_link_label.label
let check_label name expected url = check (option string) name expected (label url)

let test_a_pull_request () =
  check_label "the repo and the number" (Some "masc PR #30866")
    "https://github.com/jeong-sik/masc/pull/30866"

let test_an_issue () =
  check_label "issues are not pulls" (Some "masc issue #22797")
    "https://github.com/jeong-sik/masc/issues/22797"

let test_a_commit_is_shortened () =
  check_label "seven characters, the way git prints one"
    (Some "masc commit 0420067")
    "https://github.com/jeong-sik/masc/commit/0420067137aabbccddee"

let test_a_ci_run () =
  check_label "the run, and the job path after it does not change that"
    (Some "masc CI run 32959102055")
    "https://github.com/jeong-sik/masc/actions/runs/32959102055/job/98147624211"

(* The branch a file was read on is not what a reader is being pointed at. *)
let test_a_file_keeps_its_name_and_its_lines () =
  check_label "the file" (Some "masc masc_tui_render.ml")
    "https://github.com/jeong-sik/masc/blob/main/bin/masc_tui_render.ml";
  check_label "the file and the range it points at"
    (Some "masc masc_tui_render.ml L108-L115")
    "https://github.com/jeong-sik/masc/blob/main/bin/masc_tui_render.ml#L108-L115"

let test_the_repository_itself () =
  check_label "owner and repo" (Some "jeong-sik/masc")
    "https://github.com/jeong-sik/masc"

(* Saying "github.com" under a github.com URL costs a row and answers
   nothing, and guessing at a host nobody has taught this is how a label
   becomes wrong. *)
let test_what_gets_no_label () =
  check_label "another host" None "https://docs.anthropic.com/en/api";
  check_label "a github path this does not read" None
    "https://github.com/jeong-sik/masc/settings/hooks";
  check_label "not a url at all" None "docs/evidence/shot.png";
  check_label "the host alone" None "https://github.com"

let () =
  run "tui link label"
    [ ( "github"
      , [ test_case "a pull request" `Quick test_a_pull_request
        ; test_case "an issue" `Quick test_an_issue
        ; test_case "a commit is shortened" `Quick test_a_commit_is_shortened
        ; test_case "a ci run" `Quick test_a_ci_run
        ; test_case "a file keeps its name and its lines" `Quick
            test_a_file_keeps_its_name_and_its_lines
        ; test_case "the repository itself" `Quick test_the_repository_itself
        ] )
    ; ("silence", [ test_case "what gets no label" `Quick test_what_gets_no_label ])
    ]
