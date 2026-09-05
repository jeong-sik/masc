(* What free text counts as naming a pull request. "Fix items #3 and #4" used
   to open pull/3: a bare [#n] is a list item as often as a PR, so only a pull
   link or a PR-N token is one. *)

open Alcotest
module Pr = Masc_tui_pr_ref

let reference =
  testable
    (fun fmt -> function
      | Pr.Pull_url { slug; number } -> Format.fprintf fmt "Pull_url %s#%d" slug number
      | Pr.Pr_token number -> Format.fprintf fmt "Pr_token %d" number)
    ( = )

let test_a_bare_hash_number_is_not_a_pr () =
  check (option reference) "#3 in a list of items" None (Pr.find "Fix items #3 and #4");
  check (option reference) "#123 alone" None (Pr.find "see #123")

let test_a_pull_link_names_its_repository () =
  check (option reference) "https link"
    (Some (Pr.Pull_url { slug = "jeong-sik/masc"; number = 33123 }))
    (Pr.find "landed in https://github.com/jeong-sik/masc/pull/33123 yesterday");
  check (option reference) "a link with a trailing path"
    (Some (Pr.Pull_url { slug = "jeong-sik/masc"; number = 7 }))
    (Pr.find "https://github.com/jeong-sik/masc/pull/7/files");
  check (option reference) "an owner with a dot and a dash"
    (Some (Pr.Pull_url { slug = "my.org-x/repo_1"; number = 2 }))
    (Pr.find "github.com/my.org-x/repo_1/pull/2")

let test_a_pr_token_is_a_reference () =
  check (option reference) "PR-N" (Some (Pr.Pr_token 42)) (Pr.find "closes PR-42");
  check (option reference) "pr-N" (Some (Pr.Pr_token 42)) (Pr.find "closes pr-42 too");
  check (option reference) "glued to an identifier is not a token" None
    (Pr.find "SUPR-42 is a ticket");
  check (option reference) "a token with no digits" None (Pr.find "PR- pending")

(* The number is a whole word too: what follows the digits decides. *)
let test_a_reference_is_bounded_on_the_right () =
  check (option reference) "a date is not a token" None (Pr.find "since PR-2026-09-05");
  check (option reference) "digits running into a suffix" None (Pr.find "PR-42-b");
  check (option reference) "digits running into an identifier" None (Pr.find "PR-42_x");
  check (option reference) "a token before punctuation" (Some (Pr.Pr_token 42))
    (Pr.find "see PR-42.");
  check (option reference) "a link whose number runs into letters" None
    (Pr.find "github.com/a/b/pull/12abc");
  check (option reference) "a link with a comment anchor"
    (Some (Pr.Pull_url { slug = "a/b"; number = 7 }))
    (Pr.find "https://github.com/a/b/pull/7#issuecomment-1")

let test_the_host_is_the_whole_host () =
  check (option reference) "another host ending in github.com" None
    (Pr.find "notgithub.com/a/b/pull/1");
  check (option reference) "a subdomain is not read" None
    (Pr.find "www.github.com/a/b/pull/1");
  check (option reference) "a link in parentheses"
    (Some (Pr.Pull_url { slug = "a/b"; number = 1 }))
    (Pr.find "(https://github.com/a/b/pull/1)")

let test_the_first_reference_wins () =
  check (option reference) "link before token"
    (Some (Pr.Pull_url { slug = "a/b"; number = 1 }))
    (Pr.find "https://github.com/a/b/pull/1 then PR-2");
  check (option reference) "token before link" (Some (Pr.Pr_token 2))
    (Pr.find "PR-2 then https://github.com/a/b/pull/1")

let test_a_github_remote_yields_its_slug () =
  check (option string) "ssh remote" (Some "jeong-sik/masc")
    (Pr.github_slug_of_remote "git@github.com:jeong-sik/masc.git");
  check (option string) "https remote" (Some "jeong-sik/masc")
    (Pr.github_slug_of_remote "https://github.com/jeong-sik/masc");
  check (option string) "ssh scheme remote" (Some "jeong-sik/masc")
    (Pr.github_slug_of_remote "ssh://git@github.com/jeong-sik/masc.git");
  check (option string) "https remote with .git and a trailing slash"
    (Some "jeong-sik/masc")
    (Pr.github_slug_of_remote "https://github.com/jeong-sik/masc.git/");
  check (option string) "another forge" None
    (Pr.github_slug_of_remote "git@gitlab.com:group/project.git");
  check (option string) "a remote that is only an owner" None
    (Pr.github_slug_of_remote "https://github.com/jeong-sik")

let test_a_pull_url_is_built_from_the_slug () =
  check string "shape" "https://github.com/jeong-sik/masc/pull/9"
    (Pr.pull_url ~slug:"jeong-sik/masc" ~number:9);
  check (option string) "from a remote"
    (Some "https://github.com/jeong-sik/masc/pull/9")
    (Pr.github_pr_url ~remote:"git@github.com:jeong-sik/masc.git" ~number:9);
  check (option string) "no link for another forge" None
    (Pr.github_pr_url ~remote:"git@gitlab.com:g/p.git" ~number:9)

let () =
  run "tui_pr_ref"
    [ ( "find"
      , [ test_case "a bare #n is not a PR" `Quick test_a_bare_hash_number_is_not_a_pr
        ; test_case "a pull link names its repository" `Quick
            test_a_pull_link_names_its_repository
        ; test_case "a PR-N token is a reference" `Quick test_a_pr_token_is_a_reference
        ; test_case "the first reference wins" `Quick test_the_first_reference_wins
        ; test_case "a reference is bounded on the right" `Quick
            test_a_reference_is_bounded_on_the_right
        ; test_case "the host is the whole host" `Quick test_the_host_is_the_whole_host
        ] )
    ; ( "remote"
      , [ test_case "a github remote yields its slug" `Quick
            test_a_github_remote_yields_its_slug
        ; test_case "a pull url is built from the slug" `Quick
            test_a_pull_url_is_built_from_the_slug
        ] )
    ]
