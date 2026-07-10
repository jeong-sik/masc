(* Stress test the real repo-hosting CLI classifier used by Execute,
   Shell IR, exec_dispatch, and worker-dev dispatch paths. *)

module Risk = Masc_exec.Shell_ir_risk

(* Risk.classify_repo_hosting_cli expects words = [ "gh" ; cmd ; ... ] *)
let words_of_input s =
  "gh" :: (String.split_on_char ' ' s |> List.filter (fun t -> t <> ""))

type expected = E_R0 | E_R1 | E_R2

type case = {
  label : string;
  input : string;
  expected : expected;
}

let cases : case list = [
  { label = "baseline-pr-list";          input = "pr list --state open";          expected = E_R0 };
  { label = "baseline-pr-create";        input = "pr create --title T";            expected = E_R1 };
  { label = "baseline-pr-merge";         input = "pr merge 123";                   expected = E_R1 };  (* reversible (git revert); capability axis gates to Requires_approval *)
  { label = "baseline-repo-create";      input = "repo create owner/new-repo";      expected = E_R1 };  (* W4/G-9: reversible; capability axis gates *)
  { label = "baseline-repo-fork";        input = "repo fork owner/repo";            expected = E_R1 };  (* W4/G-9 *)
  { label = "baseline-repo-delete";      input = "repo delete o/r --yes";          expected = E_R2 };
  { label = "baseline-discussion-create";input = "discussion create --title T";     expected = E_R1 };  (* W4/G-9 *)

  { label = "flag-no-space-XDELETE";     input = "api -XDELETE /repos/o/r";        expected = E_R2 };
  { label = "flag-equals-method";        input = "api --method=DELETE /repos/o/r"; expected = E_R2 };
  { label = "flag-lowercase-method";     input = "api -X delete /repos/o/r";       expected = E_R2 };
  (* `workflow delete` doesn't exist in the repo-hosting CLI; the real destructive
     workflow subcmd is `disable`. Boolean-bypass coverage is provided
     by `repo --jq . delete o/r` below. *)
  { label = "flag-bool-prefix-disable";  input = "workflow -q disable some-wf";    expected = E_R2 };
  { label = "flag-bool-prefix-repo-del"; input = "repo --jq . delete o/r";         expected = E_R2 };

  { label = "graphql-deletePR";          input = "api graphql -f query=mutation{deletePullRequest}"; expected = E_R2 };
  { label = "graphql-purgeRepository";   input = "api graphql -f query=mutation{purgeRepository}";   expected = E_R2 };
  { label = "graphql-createRepository";  input = "api graphql -f query=mutation{createRepository}";  expected = E_R1 };  (* W4/G-9: reversible *)
  { label = "graphql-createDiscussion";  input = "api graphql -f query=mutation{createDiscussion}";  expected = E_R1 };  (* W4/G-9: reversible *)

  { label = "double-spaces-merge";       input = "pr  merge  123";                 expected = E_R1 };  (* reversible; capability axis gates *)
  { label = "case-upper-cmd";            input = "PR LIST";                        expected = E_R0 };

  { label = "ssh-key-delete";            input = "ssh-key delete 12345";           expected = E_R2 };
  { label = "auth-logout";               input = "auth logout";                    expected = E_R2 };
]

let string_of_risk = function
  | Risk.R0_Read -> "R0"
  | Risk.R1_Reversible_mutation -> "R1"
  | Risk.R2_Irreversible -> "R2"
  | Risk.Destructive_protected -> "DP"

let string_of_expected = function E_R0 -> "R0" | E_R1 -> "R1" | E_R2 -> "R2"

let test_all () =
  let anomalies = ref 0 in
  List.iter
    (fun c ->
       let r = Risk.classify_repo_hosting_cli (words_of_input c.input) in
       let actual = string_of_risk r in
       let expect = string_of_expected c.expected in
       let mark =
         if actual = expect then "✓"
         else begin incr anomalies; "✗" end
       in
       Printf.printf "[%s] %-30s  expect=%s actual=%s  '%s'\n"
         mark c.label expect actual c.input)
    cases;
  Printf.printf "\nAnomalies: %d / %d\n" !anomalies (List.length cases)

let () =
  Alcotest.run "shell_ir_risk_repo_hosting_cli_stress"
    [ "enumeration", [ Alcotest.test_case "all" `Quick test_all ] ]
