(* The /api/v1/git/log row format, pinned at the parser. *)

module W = Server_routes_http_routes_workspace.For_testing_log

let check_json = Alcotest.(check string)

let row line =
  match W.git_log_row_of_line line with
  | Some json -> Yojson.Safe.to_string json
  | None -> "none"

let test_a_row_splits_on_the_first_three_tabs () =
  check_json "plain row"
    {|{"hash":"abc1234","timestamp_ms":1787000000000,"author":"alpha","subject":"fix: a thing"}|}
    (row "abc1234\t1787000000\talpha\tfix: a thing");
  check_json "a subject keeps its own tabs"
    {|{"hash":"abc1234","timestamp_ms":1787000000000,"author":"alpha","subject":"a\tb"}|}
    (row "abc1234\t1787000000\talpha\ta\tb")

let test_a_malformed_row_is_dropped () =
  check_json "three fields is not a row" "none" (row "abc\t1787000000\talpha");
  check_json "empty line is not a row" "none" (row "");
  check_json "a non-epoch second field is not a row" "none"
    (row "abc1234\t2026-08-25\talpha\tfix: a thing")

(* Both Git changes routes answer through [Server_git_status_json.snapshot], and
   the TUI reads either answer with one decoder. A body the decoder refuses made
   the repository-scoped screen fail while the project-scoped one worked. *)
let change : Repo_git.status_file =
  { path = "lib/a.ml"; staged = false; unstaged = true; untracked = false
  ; conflicted = false }

let decode_snapshot ~scope branch =
  Masc.Tui_decode.decode_repository_change_snapshot
    (Server_git_status_json.snapshot ~scope ~branch ~changes:[ change ])

let scopes =
  [ "project", `Assoc [ ("kind", `String "project") ]
  ; ( "repository"
    , `Assoc [ ("kind", `String "repository"); ("repository_id", `String "masc") ] )
  ]

let test_every_branch_state_decodes_in_every_scope () =
  List.iter
    (fun (scope_name, scope) ->
      let check label branch expected =
        match decode_snapshot ~scope branch with
        | Error err -> Alcotest.failf "%s/%s: %s" scope_name label err
        | Ok snapshot ->
            Alcotest.(check bool)
              (scope_name ^ "/" ^ label) true
              (snapshot.Masc.Tui_decode.rcs_branch = expected
               && snapshot.rcs_total = 1)
      in
      check "detached" Repo_git.Detached Masc.Tui_decode.Repository_detached;
      check "no upstream"
        (Repo_git.On_branch { name = "main"; upstream = No_upstream })
        (Masc.Tui_decode.Repository_on_branch
           { name = "main"; upstream = Repository_no_upstream });
      check "gone upstream"
        (Repo_git.On_branch { name = "main"; upstream = Upstream_gone "origin/main" })
        (Masc.Tui_decode.Repository_on_branch
           { name = "main"; upstream = Repository_upstream_gone "origin/main" });
      check "tracking"
        (Repo_git.On_branch
           { name = "feat/x"
           ; upstream = Tracking { upstream = "origin/feat/x"; ahead = 2; behind = 1 }
           })
        (Masc.Tui_decode.Repository_on_branch
           { name = "feat/x"
           ; upstream =
               Repository_tracking { upstream = "origin/feat/x"; ahead = 2; behind = 1 }
           }))
    scopes

let () =
  Alcotest.run "workspace-git-log"
    [ ( "rows"
      , [ Alcotest.test_case "a row splits on the first three tabs" `Quick
            test_a_row_splits_on_the_first_three_tabs
        ; Alcotest.test_case "a malformed row is dropped" `Quick
            test_a_malformed_row_is_dropped
        ] )
    ]
