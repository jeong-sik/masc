(* A link's name, read out of the link. The rule is only worth having if it is
   right about the shapes masc actually trades in, and silent about the ones
   it cannot read -- a wrong label is worse than none, since a reader who
   trusts it stops opening the link. *)

open Alcotest

let label = Masc_tui_link_label.label
let check_label name expected url = check (option string) name expected (label url)

let test_what_gets_no_label () =
  check_label "another host" None "https://docs.anthropic.com/en/api";
  check_label "a github subdomain" None
    "https://api.github.com/jeong-sik/masc";
  check_label "a non-web scheme" None
    "ftp://github.com/jeong-sik/masc/pull/30866";
  check_label "a port changes the authority" None
    "https://github.com:443/jeong-sik/masc/pull/30866";
  check_label "userinfo changes the authority" None
    "https://reader@github.com/jeong-sik/masc/pull/30866";
  check_label "a github path this does not read" None
    "https://github.com/jeong-sik/masc/settings/hooks";
  check_label "not a url at all" None "docs/evidence/shot.png";
  check_label "a malformed url has no authority" None
    "https:///jeong-sik/masc/pull/30866";
  check_label "the host alone" None "https://github.com"

let () =
  run "tui link label"
    [ ( "github"
      , [] )
    ; ("silence", [ test_case "what gets no label" `Quick test_what_gets_no_label ])
    ]
