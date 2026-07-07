(** Gh_verb typed capability identity + risk agreement (RFC-0309 W1).

    Proves three properties:
    1. [Gh_verb.classify] parses argv into the expected family/action, and
       every known family round-trips through [family_token].
    2. [Shell_ir_risk.risk_of_gh_verb] AGREES with the word-list floor
       ([classify_repo_hosting_cli]) for every well-formed known-family
       command — there is one risk source (the subcommand tables), not two.
    3. [risk_of_gh_verb] DIVERGES from the floor in exactly the two intended
       places: [Other] (fail-closed R2 vs floor R0) and [Api] (R0 vs whatever
       the floor derives from -X/graphql). *)

module Gh_verb = Masc_exec.Gh_verb
module Shell_ir_risk = Masc_exec.Shell_ir_risk

let rc = Shell_ir_risk.string_of_risk_class

let words_of s = "gh" :: (String.split_on_char ' ' s |> List.filter (( <> ) ""))

(* --- 1. classify parses family + action ---------------------------------- *)

let action_str = function Some a -> a | None -> "<none>"

let test_classify_family_action () =
  let check s exp_family exp_action =
    let v = Gh_verb.classify (words_of s) in
    if v.Gh_verb.family <> exp_family then
      Alcotest.failf "%S: family %s, expected %s" s
        (Gh_verb.string_of_family v.Gh_verb.family)
        (Gh_verb.string_of_family exp_family);
    if v.Gh_verb.action <> exp_action then
      Alcotest.failf "%S: action %s, expected %s" s
        (action_str v.Gh_verb.action) (action_str exp_action)
  in
  check "repo create owner/x" Gh_verb.Repo (Some "create");
  check "pr view 123" Gh_verb.Pr (Some "view");
  check "discussion comment 42 --body B" Gh_verb.Discussion (Some "comment");
  check "api graphql -f q=x" Gh_verb.Api (Some "graphql");
  check "repo" Gh_verb.Repo None;
  check "frobnicate now" (Gh_verb.Other "frobnicate") (Some "now");
  (* Known limitation pinned: a leading value-taking global flag mis-locates
     the subcommand under the boolean-skip parse (its value lands in the
     command slot), exactly as the word-list floor does. The real pipeline
     avoids this by using [of_fields] on the parsed Gh constructor. *)
  check "--repo o/r pr merge 5" (Gh_verb.Other "o/r") (Some "pr")
;;

(* [of_fields] is the real-pipeline path: it takes the already-parsed Gh
   constructor fields, so a leading [--repo VALUE] is a non-issue. *)
let test_of_fields () =
  let check ~subcommand ~action exp_family =
    let v = Gh_verb.of_fields ~subcommand ~action in
    if v.Gh_verb.family <> exp_family then
      Alcotest.failf "of_fields %s: family %s, expected %s" subcommand
        (Gh_verb.string_of_family v.Gh_verb.family)
        (Gh_verb.string_of_family exp_family);
    if v.Gh_verb.action <> action then
      Alcotest.failf "of_fields %s: action mismatch" subcommand
  in
  check ~subcommand:"pr" ~action:(Some "merge") Gh_verb.Pr;
  check ~subcommand:"repo" ~action:(Some "create") Gh_verb.Repo;
  check ~subcommand:"discussion" ~action:(Some "comment") Gh_verb.Discussion;
  check ~subcommand:"api" ~action:(Some "graphql") Gh_verb.Api;
  check ~subcommand:"frobnicate" ~action:None (Gh_verb.Other "frobnicate")
;;

(* Every known family's token classifies back to that family — the closed set
   is complete and self-consistent. *)
let test_family_token_round_trip () =
  let known =
    [ Gh_verb.Pr; Gh_verb.Issue; Gh_verb.Repo; Gh_verb.Discussion
    ; Gh_verb.Release; Gh_verb.Secret; Gh_verb.Ssh_key; Gh_verb.Workflow
    ; Gh_verb.Auth; Gh_verb.Gist; Gh_verb.Ruleset; Gh_verb.Label
    ; Gh_verb.Run; Gh_verb.Cache; Gh_verb.Project; Gh_verb.Api ]
  in
  List.iter
    (fun fam ->
       let token = Gh_verb.family_token fam in
       let v = Gh_verb.classify [ "gh"; token ] in
       if v.Gh_verb.family <> fam then
         Alcotest.failf "family_token %s did not round-trip (got %s)"
           (Gh_verb.string_of_family fam)
           (Gh_verb.string_of_family v.Gh_verb.family))
    known
;;

(* --- 2. risk_of_gh_verb agrees with the word-list floor on known families -- *)

let risk_of_words s =
  Shell_ir_risk.risk_of_gh_verb (Gh_verb.classify (words_of s))
;;

let floor_of_words s = Shell_ir_risk.classify_repo_hosting_cli (words_of s)

let test_verb_agrees_with_floor_on_known () =
  (* Well-formed [gh <family> <action>] across every risk tier. Excludes api
     (string-borne, tested separately) and adversarial flag injection (the
     floor's positional-scan defense legitimately diverges there; composed
     risk is still safe because the floor runs via max_risk). *)
  let cases =
    [ "pr view 1"; "pr list"; "pr create --title T"; "pr comment 1 --body B"
    ; "pr merge 1"; "pr ready 1"; "issue view 2"; "issue create --title T"
    ; "repo view o/r"; "repo clone o/r"; "repo create o/new"; "repo fork o/r"
    ; "repo delete o/r"; "repo archive o/r"; "repo transfer o/r"
    ; "discussion view 3"; "discussion create --title T"
    ; "discussion comment 3 --body B"; "discussion delete 3"
    ; "release create v1"; "release delete v1"; "secret delete S"
    ; "workflow enable w.yml"; "run cancel 9"; "gist create"; "gist delete 1"
    ; "label create L"; "cache delete 1"; "ruleset delete 1"; "project create"
    ]
  in
  List.iter
    (fun s ->
       let v = risk_of_words s and f = floor_of_words s in
       if v <> f then
         Alcotest.failf
           "risk_of_gh_verb %S = %s but floor = %s (must agree on known)" s
           (rc v) (rc f))
    cases
;;

(* --- 3. the two intended divergences -------------------------------------- *)

let test_other_fail_closes_above_floor () =
  List.iter
    (fun s ->
       let v = risk_of_words s and f = floor_of_words s in
       if v <> Shell_ir_risk.R2_Irreversible then
         Alcotest.failf "unknown area %S: verb opinion %s, expected R2" s (rc v);
       if f <> Shell_ir_risk.R0_Read then
         Alcotest.failf "unknown area %S: floor %s, expected R0 (unchanged)" s
           (rc f))
    [ "frobnicate now"; "quantum entangle"; "preview enable-feature x" ]
;;

let test_api_left_to_floor () =
  (* verb opinion for api is R0; the floor derives real risk from -X/graphql,
     and composed classify takes the max — so api risk is never lost. *)
  let v = risk_of_words "api repos/o/r -X DELETE" in
  if v <> Shell_ir_risk.R0_Read then
    Alcotest.failf "api verb opinion: %s, expected R0" (rc v);
  let f = floor_of_words "api repos/o/r -X DELETE" in
  if f <> Shell_ir_risk.R2_Irreversible then
    Alcotest.failf "floor should still catch api -X DELETE: got %s" (rc f)
;;

(* The gating rationale surfaced on operator approval prompts (RFC-0309
   visibility): each verb class maps to a distinct human-readable label, and a
   real irreversible command (pr merge) yields the mutation label. *)
let test_verb_class_to_string () =
  let label words =
    Shell_ir_risk.gh_verb_class_to_string
      (Shell_ir_risk.classify_gh_verb (Gh_verb.classify words))
  in
  Alcotest.(check string)
    "pr merge is an irreversible mutation"
    "irreversible mutation"
    (label [ "gh"; "pr"; "merge" ]);
  Alcotest.(check string)
    "pr view is a read"
    "read"
    (label [ "gh"; "pr"; "view"; "1" ]);
  (* every class label is non-empty and distinct *)
  let classes =
    [ Shell_ir_risk.Gh_read
    ; Shell_ir_risk.Gh_reversible_mutation
    ; Shell_ir_risk.Gh_irreversible_mutation
    ; Shell_ir_risk.Gh_unrecognized_action
    ; Shell_ir_risk.Gh_string_borne
    ; Shell_ir_risk.Gh_unrecognized_family
    ]
  in
  let labels = List.map Shell_ir_risk.gh_verb_class_to_string classes in
  List.iter
    (fun s -> if s = "" then Alcotest.fail "verb class label must be non-empty")
    labels;
  Alcotest.(check int)
    "all six labels distinct"
    (List.length classes)
    (List.length (List.sort_uniq String.compare labels))

let () =
  Alcotest.run "gh_verb"
    [
      ( "classify",
        [
          Alcotest.test_case "family + action" `Quick test_classify_family_action;
          Alcotest.test_case "of_fields (real pipeline)" `Quick test_of_fields;
          Alcotest.test_case "family_token round-trip" `Quick
            test_family_token_round_trip;
          Alcotest.test_case "verb class to_string labels" `Quick
            test_verb_class_to_string;
        ] );
      ( "risk-agreement",
        [
          Alcotest.test_case "agrees with floor on known" `Quick
            test_verb_agrees_with_floor_on_known;
          Alcotest.test_case "Other fail-closes above floor" `Quick
            test_other_fail_closes_above_floor;
          Alcotest.test_case "api left to floor" `Quick test_api_left_to_floor;
        ] );
    ]
;;
