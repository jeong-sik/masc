(** RFC-0465 §2-§4: the server reads the open pull requests of each
    registered GitHub repository with the declared reader Keeper's token.

    Every case answers from a stub transport, so what is under test is what
    the server makes of GitHub's answer and of its own declarations, not the
    network. *)

module Pulls = Server_repository_pulls

let failf = Alcotest.failf

let now () = 1_790_000_000.

let temp_base_path () =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-repository-pulls-%d-%d" (Unix.getpid ()) (Random.int 1_000_000))
  in
  Unix.mkdir path 0o700;
  path

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o700)

let write_file path text =
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> output_string oc text)

let ok_response body =
  Ok { Pulls.status = 200; body; rate_limit_remaining = Some 4990; rate_limit_reset = None }

let pull_node ~number ~branch ~draft ~review ~rollup =
  Printf.sprintf
    {|{"number":%d,"title":"PR %d","headRefName":"%s","isDraft":%b,
       "updatedAt":"2026-09-23T01:02:03Z","reviewDecision":%s,
       "commits":{"nodes":[{"commit":{"statusCheckRollup":%s}}]}}|}
    number
    number
    branch
    draft
    review
    rollup

let page ~has_next ~cursor nodes =
  Printf.sprintf
    {|{"data":{"repository":{"pullRequests":{"pageInfo":{"hasNextPage":%b,"endCursor":%s},"nodes":[%s]}}}}|}
    has_next
    (match cursor with Some c -> Printf.sprintf "%S" c | None -> "null")
    (String.concat "," nodes)

(* The [after] variable each request carried, in order. *)
let recording_stub answers =
  let requests = ref [] in
  let remaining = ref answers in
  let http_post ~url:_ ~token ~body =
    let after =
      match body with
      | `Assoc fields ->
        (match List.assoc_opt "variables" fields with
         | Some (`Assoc vars) -> List.assoc_opt "after" vars
         | _ -> None)
      | _ -> None
    in
    requests := (token, after) :: !requests;
    match !remaining with
    | answer :: rest ->
      remaining := rest;
      answer
    | [] -> failf "the reader asked GitHub more times than the case answers"
  in
  http_post, fun () -> List.rev !requests

let never_called ~url:_ ~token:_ ~body:_ =
  failf "the reader must not reach GitHub in this case"

let read_or_fail = function
  | Pulls.Pulls_read { pulls; undecodable; _ } -> pulls, undecodable
  | Pulls.Pulls_failed _ -> failf "expected Pulls_read, got Pulls_failed"
  | Pulls.Pulls_not_read -> failf "expected Pulls_read, got Pulls_not_read"
  | Pulls.Pulls_not_github -> failf "expected Pulls_read, got Pulls_not_github"

let test_decodes_two_pages () =
  let first =
    page
      ~has_next:true
      ~cursor:(Some "Y3Vyc29yOjE=")
      [ pull_node ~number:38091 ~branch:"docs/rfc-0465" ~draft:true ~review:"null" ~rollup:"null"
      ; pull_node
          ~number:38054
          ~branch:"fix/schedule-actor"
          ~draft:false
          ~review:{|"APPROVED"|}
          ~rollup:{|{"state":"SUCCESS"}|}
      ]
  in
  let second =
    page
      ~has_next:false
      ~cursor:None
      [ pull_node
          ~number:38030
          ~branch:"fix/tui-task-body"
          ~draft:false
          ~review:{|"REVIEW_REQUIRED"|}
          ~rollup:{|{"state":"PENDING"}|}
      ]
  in
  let http_post, requests = recording_stub [ ok_response first; ok_response second ] in
  let pulls, undecodable =
    Pulls.read_repository ~now ~http_post ~token:"gho_reader" "jeong-sik/masc" |> read_or_fail
  in
  Alcotest.(check int) "no row is undecodable" 0 undecodable;
  Alcotest.(check (list int)) "every page is read, in order" [ 38091; 38054; 38030 ]
    (List.map (fun (p : Pulls.pull_request) -> p.number) pulls);
  (match pulls with
   | [ draft; approved; waiting ] ->
     Alcotest.(check bool) "draft" true draft.draft;
     Alcotest.(check bool) "no rollup reads as no checks" true (draft.checks = Pulls.Checks_none);
     Alcotest.(check bool) "no decision reads as no review" true (draft.review = Pulls.Review_none);
     Alcotest.(check bool) "SUCCESS" true (approved.checks = Pulls.Checks_passing);
     Alcotest.(check bool) "APPROVED" true (approved.review = Pulls.Review_approved);
     Alcotest.(check bool) "PENDING" true (waiting.checks = Pulls.Checks_running);
     Alcotest.(check bool) "REVIEW_REQUIRED" true (waiting.review = Pulls.Review_waiting);
     Alcotest.(check string) "head branch" "fix/tui-task-body" waiting.head_branch;
     Alcotest.(check string) "slug" "jeong-sik/masc" waiting.repo_slug
   | _ -> failf "expected three pull requests");
  match requests () with
  | [ ("gho_reader", Some `Null); ("gho_reader", Some (`String "Y3Vyc29yOjE=")) ] -> ()
  | _ -> failf "the second page must be asked for with the first page's cursor and the same token"

let test_unknown_enum_is_counted () =
  let body =
    page
      ~has_next:false
      ~cursor:None
      [ pull_node ~number:1 ~branch:"a" ~draft:false ~review:"null" ~rollup:{|{"state":"SUCCESS"}|}
      ; pull_node
          ~number:2
          ~branch:"b"
          ~draft:false
          ~review:"null"
          ~rollup:{|{"state":"QUEUED_FOR_SOMETHING_NEW"}|}
      ; pull_node ~number:3 ~branch:"c" ~draft:false ~review:{|"DISMISSED_NEW"|} ~rollup:"null"
      ; {|{"number":4,"title":"PR 4","headRefName":"d","isDraft":false,
          "updatedAt":"2026-09-23T01:02:03Z","reviewDecision":null,
          "commits":{"nodes":[{"commit":{}}]}}|}
      ]
  in
  let http_post, _ = recording_stub [ ok_response body ] in
  let pulls, undecodable =
    Pulls.read_repository ~now ~http_post ~token:"t" "o/r" |> read_or_fail
  in
  Alcotest.(check int) "unknown members and a missing rollup key are counted" 3 undecodable;
  Alcotest.(check (list int)) "they are not shown as some known state" [ 1 ]
    (List.map (fun (p : Pulls.pull_request) -> p.number) pulls)

let failure_or_fail = function
  | Pulls.Pulls_failed { failure; _ } -> failure
  | Pulls.Pulls_read _ -> failf "expected Pulls_failed, got Pulls_read"
  | Pulls.Pulls_not_read -> failf "expected Pulls_failed, got Pulls_not_read"
  | Pulls.Pulls_not_github -> failf "expected Pulls_failed, got Pulls_not_github"

let test_not_visible_is_a_failure_not_an_empty_list () =
  let graphql_not_found =
    ok_response
      {|{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","path":["repository"],
         "message":"Could not resolve to a Repository with the name 'o/wkbl'."}]}|}
  in
  List.iter
    (fun answer ->
      let http_post, _ = recording_stub [ answer ] in
      match Pulls.read_repository ~now ~http_post ~token:"t" "o/wkbl" |> failure_or_fail with
      | Pulls.Repository_not_visible -> ()
      | _ -> failf "a repository the reader cannot see must read as not visible")
    [ graphql_not_found ]

let test_rate_limit_carries_reset () =
  let limited =
    Ok
      { Pulls.status = 403
      ; body = {|{"message":"API rate limit exceeded"}|}
      ; rate_limit_remaining = Some 0
      ; rate_limit_reset = Some 1_790_003_600.
      }
  in
  let http_post, _ = recording_stub [ limited ] in
  match Pulls.read_repository ~now ~http_post ~token:"t" "o/r" |> failure_or_fail with
  | Pulls.Rate_limited { reset_at = Some at } ->
    Alcotest.(check (float 0.)) "GitHub's reset time" 1_790_003_600. at
  | _ -> failf "an exhausted limit must read as rate limited with its reset time"

let repository ~id ~url =
  { Repo_manager_types.id
  ; name = id
  ; url
  ; local_path = "repos/" ^ id
  ; aliases = []
  ; default_branch = "main"
  ; keepers = []
  ; status = Repo_manager_types.Active
  ; auto_sync = false
  ; sync_interval = 0
  ; created_at = Int64.zero
  ; updated_at = Int64.zero
  }

let register base_path =
  match
    Repo_store.save_all
      ~base_path
      [ repository ~id:"masc" ~url:"https://github.com/jeong-sik/masc.git"
      ; repository ~id:"mirror" ~url:"https://gitlab.example/o/r.git"
      ]
  with
  | Ok () -> ()
  | Error message -> failf "save_all: %s" message

let pulls_by_id snapshot =
  List.map
    (fun (entry : Pulls.repository_entry) -> entry.repository_id, entry.pulls)
    snapshot.Pulls.repositories

let test_reader_not_declared_reads_nothing () =
  let base_path = temp_base_path () in
  register base_path;
  let snapshot =
    Pulls.refresh ~now ~http_post:never_called ~base_path ~previous:Pulls.initial
  in
  (match snapshot.reader with
   | Pulls.Reader_not_declared -> ()
   | _ -> failf "no [repositories] pr_reader must read as not declared");
  match pulls_by_id snapshot with
  | [ ("masc", Pulls.Pulls_not_read); ("mirror", Pulls.Pulls_not_github) ] -> ()
  | _ -> failf "a GitHub repository stays unread and a non-GitHub one says so"

let test_reader_keeper_missing () =
  let base_path = temp_base_path () in
  register base_path;
  write_file
    (Config_dir_resolver.runtime_toml_path_for_base_path ~base_path)
    "[repositories]\npr_reader = \"nobody-here\"\n";
  let snapshot =
    Pulls.refresh ~now ~http_post:never_called ~base_path ~previous:Pulls.initial
  in
  match snapshot.reader with
  | Pulls.Reader_keeper_missing { keeper = "nobody-here" } -> ()
  | _ -> failf "a pr_reader naming no Keeper must say which Keeper is missing"

let test_unknown_key_is_refused () =
  let base_path = temp_base_path () in
  write_file
    (Config_dir_resolver.runtime_toml_path_for_base_path ~base_path)
    "[repositories]\npr_raeder = \"edgar\"\n";
  let snapshot =
    Pulls.refresh ~now ~http_post:never_called ~base_path ~previous:Pulls.initial
  in
  match snapshot.reader with
  | Pulls.Reader_declaration_invalid _ -> ()
  | _ -> failf "a misspelt key must not read as no declaration"

let test_github_slug () =
  List.iter
    (fun (remote, expected) ->
      Alcotest.(check (option string)) remote expected (Pulls.github_slug_of_remote remote))
    [ "https://github.com/jeong-sik/masc.git", Some "jeong-sik/masc"
    ; "git@github.com:jeong-sik/wkbl.git", Some "jeong-sik/wkbl"
    ; "ssh://git@github.com/jeong-sik/figma-mcp", Some "jeong-sik/figma-mcp"
    ; "https://gitlab.example/o/r.git", None
    ; "https://github.com/only-owner", None
    ]

let () =
  Alcotest.run
    "server_repository_pulls"
    [ ( "graphql"
      , [ Alcotest.test_case "two pages decode in order" `Quick test_decodes_two_pages
        ; Alcotest.test_case "unknown enum is counted" `Quick test_unknown_enum_is_counted
        ; Alcotest.test_case
            "not visible is a failure"
            `Quick
            test_not_visible_is_a_failure_not_an_empty_list
        ; Alcotest.test_case "rate limit carries reset" `Quick test_rate_limit_carries_reset
        ] )
    ; ( "reader"
      , [ Alcotest.test_case
            "not declared reads nothing"
            `Quick
            test_reader_not_declared_reads_nothing
        ; Alcotest.test_case "keeper missing" `Quick test_reader_keeper_missing
        ; Alcotest.test_case "unknown key refused" `Quick test_unknown_key_is_refused
        ; Alcotest.test_case "github slug" `Quick test_github_slug
        ] )
    ]
