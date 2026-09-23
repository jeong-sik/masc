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
    {|{"number":%d,"title":"PR %d","headRefName":"%s","isCrossRepository":false,"isDraft":%b,
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

(* A workspace whose reader is ready: runtime.toml names [reader], the Keeper
   is declared, and its GitHub CLI holds [token] for github.com. One GitHub
   repository is registered. *)
let reader_keeper = "pr-reader"

let write_reader_token base_path token =
  match Masc.Keeper_github_identity.secret_files_of_base_path ~base_path ~keeper_name:reader_keeper with
  | [ hosts ] ->
    write_file
      hosts
      (Printf.sprintf "github.com:\n  user: reader\n  oauth_token: %s\n" token);
    Unix.chmod hosts 0o600
  | _ -> failf "expected one hosts.yml path for the reader"

let ready_base_path ~token =
  let base_path = temp_base_path () in
  (match
     Repo_store.save_all
       ~base_path
       [ repository ~id:"masc" ~url:"https://github.com/jeong-sik/masc.git" ]
   with
   | Ok () -> ()
   | Error message -> failf "save_all: %s" message);
  write_file
    (Config_dir_resolver.runtime_toml_path_for_base_path ~base_path)
    (Printf.sprintf "[repositories]\npr_reader = %S\n" reader_keeper);
  write_file
    (Config_dir_resolver.keeper_toml_path_for_base_path ~base_path reader_keeper)
    "[keeper]\n";
  write_reader_token base_path token;
  base_path

(* Answers every call with [answer] and counts the calls. *)
let counting_stub answer =
  let calls = ref 0 in
  let tokens = ref [] in
  let http_post ~url:_ ~token ~body:_ =
    incr calls;
    tokens := token :: !tokens;
    answer
  in
  http_post, calls, tokens

let masc_pulls snapshot =
  match pulls_by_id snapshot with
  | [ ("masc", pulls) ] -> pulls
  | _ -> failf "expected the one registered repository"

let test_reader_ready_reads_with_the_keeper_token () =
  let base_path = ready_base_path ~token:"gho_from_hosts" in
  let http_post, calls, tokens =
    counting_stub (ok_response (page ~has_next:false ~cursor:None []))
  in
  let snapshot = Pulls.refresh ~now ~http_post ~base_path ~previous:Pulls.initial in
  (match snapshot.reader with
   | Pulls.Reader_ready { keeper } -> Alcotest.(check string) "reader" reader_keeper keeper
   | _ -> failf "a declared Keeper with a hosts.yml token must be ready");
  Alcotest.(check int) "one call" 1 !calls;
  Alcotest.(check (list string)) "the hosts.yml token is sent" [ "gho_from_hosts" ] !tokens;
  match masc_pulls snapshot with
  | Pulls.Pulls_read { pulls = []; undecodable = 0; _ } -> ()
  | _ -> failf "an empty page reads as no open pull requests"

let test_rejected_token_is_not_sent_again () =
  let base_path = ready_base_path ~token:"gho_revoked" in
  let rejected =
    Ok { Pulls.status = 401; body = "{}"; rate_limit_remaining = None; rate_limit_reset = None }
  in
  let http_post, calls, _ = counting_stub rejected in
  let first = Pulls.refresh ~now ~http_post ~base_path ~previous:Pulls.initial in
  let later () = now () +. 60. in
  let second = Pulls.refresh ~now:later ~http_post ~base_path ~previous:first in
  Alcotest.(check int) "the same refused token is sent once" 1 !calls;
  (match masc_pulls second with
   | Pulls.Pulls_failed { failure = Pulls.Token_rejected; observed_at } ->
     Alcotest.(check (float 0.)) "the first refusal's time stands" (now ()) observed_at
   | _ -> failf "the refusal must stay on screen while the token is unchanged");
  (match second.rejected_token_digest with
   | Some digest ->
     Alcotest.(check bool) "the digest is not the token" false (String.equal digest "gho_revoked")
   | None -> failf "the refused token's digest must be kept");
  write_reader_token base_path "gho_new_login";
  let _third = Pulls.refresh ~now:later ~http_post ~base_path ~previous:second in
  Alcotest.(check int) "a new token is asked about" 2 !calls

let test_rate_limit_waits_for_reset () =
  let base_path = ready_base_path ~token:"gho_reader" in
  let reset_at = now () +. 600. in
  let limited =
    Ok
      { Pulls.status = 403
      ; body = {|{"message":"API rate limit exceeded"}|}
      ; rate_limit_remaining = Some 0
      ; rate_limit_reset = Some reset_at
      }
  in
  let http_post, calls, _ = counting_stub limited in
  let first = Pulls.refresh ~now ~http_post ~base_path ~previous:Pulls.initial in
  let before_reset () = reset_at -. 1. in
  let second = Pulls.refresh ~now:before_reset ~http_post ~base_path ~previous:first in
  Alcotest.(check int) "no call before GitHub's reset" 1 !calls;
  (match masc_pulls second with
   | Pulls.Pulls_failed { failure = Pulls.Rate_limited { reset_at = Some at }; _ } ->
     Alcotest.(check (float 0.)) "the reset time stands" reset_at at
   | _ -> failf "the limit must stay on screen until its reset");
  let after_reset () = reset_at in
  let _third = Pulls.refresh ~now:after_reset ~http_post ~base_path ~previous:second in
  Alcotest.(check int) "asked again at the reset" 2 !calls

(* --- RFC-0465 §0.2: a pull request belongs to the Keepers whose checkout of
   its repository is on its head branch. --- *)

module Control = Masc.Keeper_sandbox_control

let checkout_row ~path ~catalog branch : Control.freshness_row =
  { Control.row_checkout_path = path
  ; row_branch = branch
  ; row_catalog = catalog
  ; row_changed_files = None
  ; row_freshness = Control.Freshness_unavailable "not measured in this case"
  }

let scanned ?truncated rows =
  Pulls.Checkouts_read { Control.scan_rows = rows; scan_truncated = truncated }

let masc_repo =
  Control.Registered (repository ~id:"masc" ~url:"https://github.com/jeong-sik/masc.git")

let fork_node ~number ~branch =
  Printf.sprintf
    {|{"number":%d,"title":"PR %d","headRefName":"%s","isCrossRepository":true,"isDraft":false,
       "updatedAt":"2026-09-23T01:02:03Z","reviewDecision":null,
       "commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}|}
    number
    number
    branch

let three_pull_page =
  ok_response
    (page
       ~has_next:false
       ~cursor:None
       [ pull_node ~number:1 ~branch:"feat/join" ~draft:false ~review:"null" ~rollup:"null"
       ; pull_node ~number:2 ~branch:"feat/other" ~draft:true ~review:"null" ~rollup:"null"
       ; fork_node ~number:3 ~branch:"feat/join"
       ])

let fleet : Pulls.fleet_checkouts =
  Ok
    [ { Pulls.keeper = "alpha"
      ; checkouts = scanned [ checkout_row ~path:"repos/masc" ~catalog:masc_repo (Some "feat/join") ]
      }
    ; { Pulls.keeper = "beta"; checkouts = Checkouts_unread "playground root is unreadable" }
    ; { Pulls.keeper = "gamma"
      ; checkouts =
          scanned
            [ checkout_row ~path:"repos/masc" ~catalog:masc_repo (Some "main")
            ; checkout_row
                ~path:"repos/other"
                ~catalog:(Control.Origin_unavailable "git remote get-url timed out")
                None
            ]
      }
    ; { Pulls.keeper = "delta"
      ; checkouts =
          scanned [ checkout_row ~path:"repos/fork" ~catalog:Control.Unregistered (Some "feat/join") ]
      }
    ; { Pulls.keeper = "epsilon"
      ; checkouts = scanned [ checkout_row ~path:"repos/masc" ~catalog:masc_repo (Some "feat/Join") ]
      }
    ; { Pulls.keeper = "zeta"
      ; checkouts = scanned [ checkout_row ~path:"masc" ~catalog:masc_repo (Some "feat/other") ]
      }
      (* A microvm guest not booted in this process has no playground. *)
    ; { Pulls.keeper = "eta"; checkouts = Checkouts_absent }
      (* Discovery stopped after one checkout of another repository: a
         checkout of masc may be among those never seen. *)
    ; { Pulls.keeper = "theta"
      ; checkouts =
          scanned
            ~truncated:(Masc.Keeper_playground_checkouts.Checkout_budget_exhausted { budget = 32 })
            [ checkout_row ~path:"repos/fork" ~catalog:Control.Unregistered (Some "feat/other") ]
      }
    ]

let json_pulls snapshot =
  let json = Pulls.snapshot_to_yojson snapshot in
  let open Yojson.Safe.Util in
  match json |> member "repositories" |> to_list with
  | [ repo ] -> repo |> member "pulls" |> member "pulls" |> to_list
  | _ -> failf "expected the one registered repository in the JSON"

let join_of json =
  let open Yojson.Safe.Util in
  ( json |> member "number" |> to_int
  , json |> member "keepers" |> to_option (fun ks -> List.map to_string (to_list ks))
  , ( json |> member "keepers_unread" |> to_int_option
    , json |> member "keepers_error" |> to_string_option ) )

let join_testable =
  Alcotest.(list (triple int (option (list string)) (pair (option int) (option string))))

let catalog_ids = function
  | Ok repos -> List.map (fun (r : Repo_manager_types.repository) -> r.id) repos
  | Error message -> failf "the join must hand inspection the catalog, got %s" message

let pulls_read () =
  let base_path = ready_base_path ~token:"gho_join" in
  let http_post, _, _ = counting_stub three_pull_page in
  base_path, Pulls.refresh ~now ~http_post ~base_path ~previous:Pulls.initial

let test_keepers_join_by_exact_branch () =
  let base_path, read = pulls_read () in
  (* The pull requests are published before any Keeper is inspected. *)
  Alcotest.check
    join_testable
    "before the join"
    [ 1, None, (None, Some "Keeper checkouts were not inspected")
    ; 2, None, (None, Some "Keeper checkouts were not inspected")
    ; 3, None, (None, Some "Keeper checkouts were not inspected")
    ]
    (List.map join_of (json_pulls read));
  let inspections = ref [] in
  let inspect_checkouts ~catalog =
    inspections := catalog_ids catalog :: !inspections;
    fleet
  in
  let joined = Pulls.join_keepers ~now ~inspect_checkouts ~base_path read in
  Alcotest.(check (list (list string)))
    "one inspection per refresh, with the catalog loaded once"
    [ [ "masc" ] ]
    !inspections;
  (* alpha and zeta are on the head branches. beta's playground, one of
     gamma's origins and theta's stopped discovery were not read, so each may
     be on either branch; eta has no playground. delta's checkout is another
     repository, epsilon's branch differs in case. #3 is a fork's
     [feat/join], which no checkout of this repository can be on. *)
  Alcotest.check
    join_testable
    "keepers per pull request"
    [ 1, Some [ "alpha" ], (Some 3, None)
    ; 2, Some [ "zeta" ], (Some 3, None)
    ; 3, Some [], (Some 0, None)
    ]
    (List.map join_of (json_pulls joined));
  (* The next refresh keeps the join until the next join replaces it. *)
  let http_post, _, _ = counting_stub three_pull_page in
  let next = Pulls.refresh ~now ~http_post ~base_path ~previous:joined in
  Alcotest.check
    join_testable
    "the previous join stands between refresh and join"
    (List.map join_of (json_pulls joined))
    (List.map join_of (json_pulls next))

let test_unlisted_keepers_say_so () =
  let base_path, read = pulls_read () in
  let joined =
    Pulls.join_keepers
      ~now
      ~inspect_checkouts:(fun ~catalog:_ -> Error "keepers directory unreadable")
      ~base_path
      read
  in
  Alcotest.check
    join_testable
    "no pull request reads as having no Keeper"
    [ 1, None, (None, Some "keepers directory unreadable")
    ; 2, None, (None, Some "keepers directory unreadable")
    ; 3, None, (None, Some "keepers directory unreadable")
    ]
    (List.map join_of (json_pulls joined))

let test_no_open_pull_means_no_inspection () =
  let refuse ~catalog:_ = failf "no open pull request was read, so no checkout is inspected" in
  (* Reader not declared: nothing read. *)
  let base_path = temp_base_path () in
  register base_path;
  let unread = Pulls.refresh ~now ~http_post:never_called ~base_path ~previous:Pulls.initial in
  let _ = Pulls.join_keepers ~now ~inspect_checkouts:refuse ~base_path unread in
  (* Read, but the repository has no open pull request. *)
  let base_path = ready_base_path ~token:"gho_empty" in
  let http_post, _, _ = counting_stub (ok_response (page ~has_next:false ~cursor:None [])) in
  let empty = Pulls.refresh ~now ~http_post ~base_path ~previous:Pulls.initial in
  let _ = Pulls.join_keepers ~now ~inspect_checkouts:refuse ~base_path empty in
  ()

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
        ; Alcotest.test_case
            "ready reader reads with the keeper token"
            `Quick
            test_reader_ready_reads_with_the_keeper_token
        ] )
    ; ( "provider limits"
      , [ Alcotest.test_case
            "rejected token is not sent again"
            `Quick
            test_rejected_token_is_not_sent_again
        ; Alcotest.test_case "rate limit waits for reset" `Quick test_rate_limit_waits_for_reset
        ] )
    ; ( "keepers on branch"
      , [ Alcotest.test_case
            "joined by exact branch"
            `Quick
            test_keepers_join_by_exact_branch
        ; Alcotest.test_case "unlisted keepers say so" `Quick test_unlisted_keepers_say_so
        ; Alcotest.test_case
            "no open pull request means no inspection"
            `Quick
            test_no_open_pull_means_no_inspection
        ] )
    ]
