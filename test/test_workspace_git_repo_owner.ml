(** Which repository a workspace git route runs in.

    [Server_routes_http_routes_workspace] used to run [git diff] and
    [git blame] at the queried root. A playground that keeps its clones in
    [repos/<id>/] has no repository at that root, so git walked past it and
    answered from whichever repository encloses MASC's own checkout. The path
    does not exist there, git printed nothing, and a modified file came back
    as [has_changes:false] -- a wrong answer with a 200 on it (#30322).

    These tests build real directory trees, because the thing under test is a
    question about the filesystem: is there a [.git] here, and where does the
    search stop. *)

open Alcotest

module W = Server_routes_http_routes_workspace

let temp_root () =
  let dir = Filename.temp_file "masc-repo-owner" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  dir
;;

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o700
  end
;;

let make_repo root segments =
  let dir = List.fold_left Filename.concat root segments in
  mkdir_p dir;
  (* A worktree's [.git] is a file, not a directory, which is why the search
     asks whether the name exists rather than whether it is a directory. *)
  Unix.mkdir (Filename.concat dir ".git") 0o700;
  dir
;;

let touch dir name =
  let path = Filename.concat dir name in
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  close_out oc;
  path
;;

(* The reported case. The clone is two levels under the queried root, and the
   file is inside it. *)
let test_finds_the_clone_below_the_playground () =
  let root = temp_root () in
  let playground = Filename.concat root "playground/<keeper>" in
  mkdir_p playground;
  let clone = make_repo playground [ "repos"; "masc" ] in
  let file = touch clone "dashboard/src/fusion.ts" in
  check (option string) "the clone owns it" (Some clone)
    (W.For_testing.repository_owning ~base:playground ~path:file)
;;

(* The other layout: the clone sits directly at the playground root. *)
let test_finds_a_clone_at_the_root () =
  let root = temp_root () in
  let playground = Filename.concat root "playground/<keeper>" in
  mkdir_p playground;
  let clone = make_repo playground [ "masc" ] in
  let file = touch clone "test/thing.ml" in
  check (option string) "the clone owns it" (Some clone)
    (W.For_testing.repository_owning ~base:playground ~path:file)
;;

(* The root itself is a repository, which is the project checkout's case. *)
let test_the_base_can_be_the_repository () =
  let root = temp_root () in
  let repo = make_repo root [ "project" ] in
  let file = touch repo "lib/thing.ml" in
  check (option string) "the base owns it" (Some repo)
    (W.For_testing.repository_owning ~base:repo ~path:file)
;;

(* The whole point. A repository above the queried root is not an answer to a
   question asked about that root, and returning it is how the wrong answer
   was produced. The search stops at [base] even though git would not. *)
let test_stops_at_the_base_rather_than_climbing_out () =
  let root = temp_root () in
  let outer = make_repo root [ "outer" ] in
  let playground = Filename.concat outer "playground/keeper" in
  mkdir_p playground;
  let file = touch playground "notes/scratch.md" in
  check (option string) "no repository under the scope" None
    (W.For_testing.repository_owning ~base:playground ~path:file);
  (* And the repository really is up there: without the bound this would have
     found it, which is what the routes used to do. *)
  check (option string) "it is above, and it is out of scope" (Some outer)
    (W.For_testing.repository_owning ~base:root ~path:file)
;;

(* The nearest one wins. A clone inside a repository -- a vendored checkout,
   or MASC's own tree holding a playground -- must answer for its own files. *)
let test_the_nearest_repository_wins () =
  let root = temp_root () in
  let outer = make_repo root [ "outer" ] in
  let inner = make_repo outer [ "playground"; "keeper"; "repos"; "masc" ] in
  let file = touch inner "lib/thing.ml" in
  check (option string) "the inner one" (Some inner)
    (W.For_testing.repository_owning ~base:outer ~path:file)
;;

(* A trailing slash on the root is the same root. The bound is a string
   comparison, so a root spelled with one would have failed to contain its own
   children. *)
let test_a_trailing_slash_is_the_same_root () =
  let root = temp_root () in
  let playground = Filename.concat root "playground/keeper" in
  mkdir_p playground;
  let clone = make_repo playground [ "repos"; "masc" ] in
  let file = touch clone "lib/thing.ml" in
  check (option string) "still found" (Some clone)
    (W.For_testing.repository_owning ~base:(playground ^ "/") ~path:file)
;;

let () =
  run "workspace_git_repo_owner"
    [ ( "finding"
      , [ test_case "the clone below the playground" `Quick
            test_finds_the_clone_below_the_playground
        ; test_case "a clone at the root" `Quick test_finds_a_clone_at_the_root
        ; test_case "the base itself" `Quick test_the_base_can_be_the_repository
        ; test_case "the nearest wins" `Quick test_the_nearest_repository_wins
        ] )
    ; ( "bounds"
      , [ test_case "stops at the base" `Quick
            test_stops_at_the_base_rather_than_climbing_out
        ; test_case "a trailing slash is the same root" `Quick
            test_a_trailing_slash_is_the_same_root
        ] )
    ]
;;
