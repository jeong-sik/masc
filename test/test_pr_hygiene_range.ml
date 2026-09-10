(** What [scripts/check-pr-hygiene.sh] attributes to a pull request.

    The range is "reachable from HEAD and not from the base". These cases run
    the real script against a shallow clone, which is the shape CI has and the
    shape where the merge-base this used to compute cannot answer (#35012).

    The fixture initialises with [--template=] so no hook from the developer's
    git configuration runs inside it, and names its trunk branch [trunk] for
    the same reason. *)

open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let script_path () = Filename.concat (source_root ()) "scripts/check-pr-hygiene.sh"

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then begin
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path

let with_temp_dir f =
  let dir = Filename.temp_file "pr_hygiene_range" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let write_file path contents =
  Out_channel.with_open_bin path (fun oc -> output_string oc contents)

(* [(exit_code, combined_output)]. The script writes its findings to stdout and
   its verdict sentence to stderr, and a case that reads only one of the two
   would miss half of what it says. *)
let run_shell script =
  let out = Filename.temp_file "pr_hygiene_out" "" in
  let command = Printf.sprintf "{ %s ; } > %s 2>&1" script (Filename.quote out) in
  let code =
    match Unix.system command with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> 128 + signal
  in
  let contents = In_channel.with_open_bin out In_channel.input_all in
  Sys.remove out;
  (code, contents)

(* trunk: six ordinary commits, one empty commit, two more ordinary ones.
   feature: branched four commits back, one commit, a merge of trunk, one more.
   The empty trunk commit is therefore an ancestor of HEAD through the merge --
   which is what makes it a candidate for being attributed to the branch. *)
let fixture_script dir =
  Printf.sprintf
    {|set -e
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --initial-branch=trunk --template= %s/origin
cd %s/origin
for i in 1 2 3 4 5 6; do echo $i > f$i; git add f$i; git commit -qm "trunk $i"; done
git commit -q --allow-empty -m "trunk empty"
git rev-parse HEAD > %s/trunk_empty_sha
for i in 7 8; do echo $i > f$i; git add f$i; git commit -qm "trunk $i"; done
git checkout -q -b feature "$(git rev-parse HEAD~4)"
echo x > fx; git add fx; git commit -qm "feature 1"
git merge -q --no-edit trunk -m "merge trunk into feature"
echo y > fy; git add fy; git commit -qm "feature 2"
git clone -q --depth=2 --branch feature --template= file://%s/origin %s/work
cd %s/work
git fetch -q --depth=2 origin trunk:refs/remotes/origin/trunk|}
    dir dir dir dir dir dir

let build_fixture dir =
  let path = Filename.concat dir "fixture.sh" in
  write_file path (fixture_script dir);
  let code, output = run_shell (Printf.sprintf "bash %s" (Filename.quote path)) in
  if code <> 0 then failf "fixture setup failed (%d): %s" code output

let hygiene dir extra =
  run_shell
    (Printf.sprintf
       "cd %s/work && bash %s --base origin/trunk --head HEAD %s"
       dir
       (Filename.quote (script_path ()))
       extra)

let trunk_empty_sha dir =
  In_channel.with_open_bin (Filename.concat dir "trunk_empty_sha") In_channel.input_all
  |> String.trim

let holds ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0

(* The merge-base this script used to compute exits 1 here: neither side has a
   common ancestor within the fetched depth. Under [set -e] the script then
   died before printing anything, so the lint reported a failure with no line
   saying why. *)
let test_a_shallow_clone_still_gets_a_verdict () =
  with_temp_dir (fun dir ->
    build_fixture dir;
    let merge_base_code, _ =
      run_shell (Printf.sprintf "cd %s/work && git merge-base origin/trunk HEAD" dir)
    in
    check bool "the fixture is one where merge-base cannot answer" true
      (merge_base_code <> 0);
    let code, output = hygiene dir "" in
    check int "the script reaches a verdict" 0 code;
    check bool "and says so" true (holds ~needle:"PR hygiene check passed" output))

(* #35012's symptom: a commit of the base reported as a commit of the pull
   request. Here the empty trunk commit is an ancestor of HEAD through the
   merge, and reachable from the base, so it is the base's. *)
let test_a_base_commit_is_not_this_pull_requests () =
  with_temp_dir (fun dir ->
    build_fixture dir;
    let _, output = hygiene dir "" in
    check bool "the empty base commit is not reported" false
      (holds ~needle:(trunk_empty_sha dir) output))

let test_an_empty_commit_on_the_branch_is_caught () =
  with_temp_dir (fun dir ->
    build_fixture dir;
    let setup, _ =
      run_shell
        (Printf.sprintf
           "cd %s/work && GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
            GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t git commit -q \
            --allow-empty -m 'feature empty'"
           dir)
    in
    check int "the branch takes an empty commit" 0 setup;
    let code, output = hygiene dir "" in
    check int "an empty commit fails the check" 1 code;
    check bool "and is named" true (holds ~needle:"Empty commit detected" output))

(* The priority walk reads the pull request's own patches rather than a
   two-point diff, so this is what says it still reads them.

   The forbidden pattern is assembled at run time rather than written out.
   The guard scans added lines of every .ml and .mli for it, this file is one,
   and a fixture spelled in full would make the guard read its own test as an
   erasure -- which it did, on this change's first run. *)
let erasure_pattern = "~priority" ^ ":()"
let test_priority_erasure_on_the_branch_is_caught () =
  with_temp_dir (fun dir ->
    build_fixture dir;
    let setup, _ =
      run_shell
        (Printf.sprintf
           "cd %s/work && printf 'let f %s = ()\\n' > p.ml && git add p.ml \
            && GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t \
            GIT_COMMITTER_EMAIL=t@t git commit -qm 'erase priority'"
           dir
           erasure_pattern)
    in
    check int "the branch takes the erasing commit" 0 setup;
    let code, output = hygiene dir "" in
    check int "priority erasure fails the check" 1 code;
    check bool "and is named" true (holds ~needle:"Priority type erasure" output))

let () =
  run
    "pr_hygiene_range"
    [ ( "shallow"
      , [ test_case "a shallow clone still gets a verdict" `Quick
            test_a_shallow_clone_still_gets_a_verdict
        ; test_case "a base commit is not this pull request's" `Quick
            test_a_base_commit_is_not_this_pull_requests
        ] )
    ; ( "still catches"
      , [ test_case "an empty commit on the branch" `Quick
            test_an_empty_commit_on_the_branch_is_caught
        ; test_case "priority erasure on the branch" `Quick
            test_priority_erasure_on_the_branch_is_caught
        ] )
    ]
;;
