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
  Ok { Pulls.status = 200; body; rate_limit_remaining = Some 4990; rate_limit_reset = None; retry_after_s = None }

let pull_node
      ?(author = {|{"name":"edgar"}|})
      ?(mergeable = {|"mergeable":"MERGEABLE",|})
      ~number
      ~draft
      ~review
      ~rollup
      ()
  =
  Printf.sprintf
    {|{"number":%d,"isDraft":%b,
       "updatedAt":"2026-09-23T01:02:03Z","reviewDecision":%s,%s
       "authored":{"nodes":[{"commit":{"parents":{"totalCount":1},"author":%s}}]},
       "head":{"nodes":[{"commit":{"statusCheckRollup":%s}}]}}|}
    number
    draft
    review
    mergeable
    author
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
      [ pull_node ~number:38091 ~draft:true ~review:"null" ~rollup:"null" ()
      ; pull_node
          ~number:38054
          ~draft:false
          ~review:{|"APPROVED"|}
          ~rollup:{|{"state":"SUCCESS"}|} ()
      ]
  in
  let second =
    page
      ~has_next:false
      ~cursor:None
      [ pull_node
          ~number:38030
          ~draft:false
          ~review:{|"REVIEW_REQUIRED"|}
          ~rollup:{|{"state":"PENDING"}|} ()
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
      [ pull_node ~number:1 ~draft:false ~review:"null" ~rollup:{|{"state":"SUCCESS"}|} ()
      ; pull_node
          ~number:2
          ~draft:false
          ~review:"null"
          ~rollup:{|{"state":"QUEUED_FOR_SOMETHING_NEW"}|} ()
      ; pull_node ~number:3 ~draft:false ~review:{|"DISMISSED_NEW"|} ~rollup:"null" ()
      ; {|{"number":4,"isDraft":false,
          "updatedAt":"2026-09-23T01:02:03Z","reviewDecision":null,"mergeable":"MERGEABLE",
          "authored":{"nodes":[{"commit":{"parents":{"totalCount":1},"author":null}}]},
          "head":{"nodes":[{"commit":{}}]}}|}
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
      ; retry_after_s = None
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
    Pulls.refresh ~now ~http_post:never_called ~config:(Masc.Workspace.default_config base_path) ~previous:Pulls.initial
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
    Pulls.refresh ~now ~http_post:never_called ~config:(Masc.Workspace.default_config base_path) ~previous:Pulls.initial
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
    Pulls.refresh ~now ~http_post:never_called ~config:(Masc.Workspace.default_config base_path) ~previous:Pulls.initial
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
  let snapshot = Pulls.refresh ~now ~http_post ~config:(Masc.Workspace.default_config base_path) ~previous:Pulls.initial in
  (match snapshot.reader with
   | Pulls.Reader_ready { keeper } -> Alcotest.(check string) "reader" reader_keeper keeper
   | _ -> failf "a declared Keeper with a hosts.yml token must be ready");
  Alcotest.(check int) "one call" 1 !calls;
  Alcotest.(check (list string)) "the hosts.yml token is sent" [ "gho_from_hosts" ] !tokens;
  match masc_pulls snapshot with
  | Pulls.Pulls_read { pulls = []; undecodable = 0; _ } -> ()
  | _ -> failf "an empty page reads as no open pull requests"

(* A refresh that raises keeps the last rows but marks them; the next
   refresh that returns clears the mark from its own reading. *)
let test_a_raised_refresh_marks_the_rows_until_the_next_one_returns () =
  let base_path = ready_base_path ~token:"gho_from_hosts" in
  let config = Masc.Workspace.default_config base_path in
  let http_post, _, _ = counting_stub (ok_response (page ~has_next:false ~cursor:None [])) in
  let first = Pulls.refresh ~now ~http_post ~config ~previous:Pulls.initial in
  Alcotest.(check bool) "a returned refresh carries no mark" true
    (Option.is_none first.repositories_error);
  let raising ~url:_ ~token:_ ~body:_ = failwith "transport broke" in
  let raised =
    match Pulls.refresh ~now ~http_post:raising ~config ~previous:first with
    | _ -> failf "a transport that raises must escape refresh for start to catch"
    | exception (Failure _ as exn) -> Pulls.refresh_raised ~previous:first exn
  in
  Alcotest.(check bool) "the raise is said" true (Option.is_some raised.repositories_error);
  Alcotest.(check int) "the last rows stay"
    (List.length first.repositories) (List.length raised.repositories);
  let next = Pulls.refresh ~now ~http_post ~config ~previous:raised in
  Alcotest.(check bool) "the next returned refresh clears the mark" true
    (Option.is_none next.repositories_error)

(* A Remote_ssh Keeper's GitHub login lives on its endpoint. A hosts.yml in
   this host's directory for that Keeper was not written by its login, so the
   reader refuses it instead of sending it (RFC-0465 §4: no other credential). *)
let remote_endpoint_name = "pr-reader-box"

let test_remote_ssh_reader_is_refused () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = ready_base_path ~token:"gho_host_copy" in
  write_file
    (Config_dir_resolver.runtime_toml_path_for_base_path ~base_path)
    (Exec_ssh_endpoint.to_toml
       Exec_ssh_endpoint.
         { name = remote_endpoint_name
         ; host = "fixture.invalid"
         ; user = "masc"
         ; port = default_port
         ; identity_file = default_identity_file ~name:remote_endpoint_name
         ; known_hosts_file = default_known_hosts_file ~name:remote_endpoint_name
         ; remote_root = "/srv/masc/playground"
         ; connect_timeout_sec = 1
         ; max_concurrent_sessions = 2
         ; env_allowlist = []
         ; capabilities = []
         ; private_home = false
         }
     ^ Printf.sprintf "\n[repositories]\npr_reader = %S\n" reader_keeper);
  write_file
    (Config_dir_resolver.keeper_toml_path_for_base_path ~base_path reader_keeper)
    (Printf.sprintf
       "[keeper]\nsandbox_profile = \"remote_ssh\"\nremote_endpoint = %S\n"
       remote_endpoint_name);
  let config = Masc.Workspace.default_config base_path in
  let meta =
    match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String reader_keeper ]) with
    | Ok fixture ->
      { fixture with
        Masc.Keeper_meta_contract.sandbox_profile = Keeper_types_profile_sandbox.Remote_ssh
      }
    | Error detail -> failf "meta fixture: %s" detail
  in
  (match Masc.Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> failf "keeper meta persistence failed: %s" detail);
  let http_post, calls, _ =
    counting_stub (ok_response (page ~has_next:false ~cursor:None []))
  in
  let snapshot = Pulls.refresh ~now ~http_post ~config ~previous:Pulls.initial in
  (match snapshot.reader with
   | Pulls.Reader_token_unavailable { keeper; reason = _ } ->
     Alcotest.(check string) "the refusal names the reader" reader_keeper keeper
   | Pulls.Reader_ready _ -> failf "a Remote_ssh reader was answered from this host's hosts.yml"
   | _ -> failf "a Remote_ssh reader must be refused as token unavailable");
  Alcotest.(check int) "GitHub is not called" 0 !calls

let test_rejected_token_is_not_sent_again () =
  let base_path = ready_base_path ~token:"gho_revoked" in
  let rejected =
    Ok { Pulls.status = 401; body = "{}"; rate_limit_remaining = None; rate_limit_reset = None; retry_after_s = None }
  in
  let http_post, calls, _ = counting_stub rejected in
  let first = Pulls.refresh ~now ~http_post ~config:(Masc.Workspace.default_config base_path) ~previous:Pulls.initial in
  let later () = now () +. 60. in
  let second = Pulls.refresh ~now:later ~http_post ~config:(Masc.Workspace.default_config base_path) ~previous:first in
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
  let _third = Pulls.refresh ~now:later ~http_post ~config:(Masc.Workspace.default_config base_path) ~previous:second in
  Alcotest.(check int) "a new token is asked about" 2 !calls

(* GitHub's secondary rate limit: 403 with [retry-after] while the primary
   quota still has requests left. Reading it as a plain 403 would ask again
   every 60 s during the wait GitHub asked for. *)
let test_secondary_limit_waits_for_retry_after () =
  let base_path = ready_base_path ~token:"gho_reader" in
  let retry_after_s = 120 in
  let limited =
    Ok
      { Pulls.status = 403
      ; body = {|{"message":"You have exceeded a secondary rate limit."}|}
      ; rate_limit_remaining = Some 4000
      ; rate_limit_reset = Some (now () +. 3000.)
      ; retry_after_s = Some retry_after_s
      }
  in
  let http_post, calls, _ = counting_stub limited in
  let config = Masc.Workspace.default_config base_path in
  let first = Pulls.refresh ~now ~http_post ~config ~previous:Pulls.initial in
  let wait_ends = now () +. Float.of_int retry_after_s in
  (match masc_pulls first with
   | Pulls.Pulls_failed { failure = Pulls.Rate_limited { reset_at = Some at }; _ } ->
     Alcotest.(check (float 0.)) "retry-after is the wait, not the primary reset" wait_ends at
   | _ -> failf "403 with retry-after must read as rate limited");
  let during () = wait_ends -. 1. in
  let second = Pulls.refresh ~now:during ~http_post ~config ~previous:first in
  Alcotest.(check int) "no call during retry-after" 1 !calls;
  let after () = wait_ends in
  let _third = Pulls.refresh ~now:after ~http_post ~config ~previous:second in
  Alcotest.(check int) "asked again when retry-after ends" 2 !calls

let test_plain_403_is_forbidden () =
  let forbidden =
    Ok
      { Pulls.status = 403
      ; body = {|{"message":"Resource protected by organization SAML enforcement."}|}
      ; rate_limit_remaining = Some 4000
      ; rate_limit_reset = None
      ; retry_after_s = None
      }
  in
  let http_post, _ = recording_stub [ forbidden ] in
  match Pulls.read_repository ~now ~http_post ~token:"t" "o/r" |> failure_or_fail with
  | Pulls.Forbidden { status = 403 } -> ()
  | _ -> failf "403 without an exhausted limit or retry-after is forbidden"

let test_rate_limit_waits_for_reset () =
  let base_path = ready_base_path ~token:"gho_reader" in
  let reset_at = now () +. 600. in
  let limited =
    Ok
      { Pulls.status = 403
      ; body = {|{"message":"API rate limit exceeded"}|}
      ; rate_limit_remaining = Some 0
      ; rate_limit_reset = Some reset_at
      ; retry_after_s = None
      }
  in
  let http_post, calls, _ = counting_stub limited in
  let first = Pulls.refresh ~now ~http_post ~config:(Masc.Workspace.default_config base_path) ~previous:Pulls.initial in
  let before_reset () = reset_at -. 1. in
  let second = Pulls.refresh ~now:before_reset ~http_post ~config:(Masc.Workspace.default_config base_path) ~previous:first in
  Alcotest.(check int) "no call before GitHub's reset" 1 !calls;
  (match masc_pulls second with
   | Pulls.Pulls_failed { failure = Pulls.Rate_limited { reset_at = Some at }; _ } ->
     Alcotest.(check (float 0.)) "the reset time stands" reset_at at
   | _ -> failf "the limit must stay on screen until its reset");
  let after_reset () = reset_at in
  let _third = Pulls.refresh ~now:after_reset ~http_post ~config:(Masc.Workspace.default_config base_path) ~previous:second in
  Alcotest.(check int) "asked again at the reset" 2 !calls

(* --- Author, mergeable, Keeper join (RFC-0465: join by the newest
   single-parent commit's author, because a Keeper leaves the branch once its
   pull request is open and a merge commit's author only brought the base in) --- *)

let no_commit_node ~number =
  Printf.sprintf
    {|{"number":%d,"isDraft":false,
       "updatedAt":"2026-09-23T01:02:03Z","reviewDecision":null,"mergeable":"UNKNOWN",
       "authored":{"nodes":[]},"head":{"nodes":[]}}|}
    number

let test_author_and_mergeable_decode () =
  let body =
    page
      ~has_next:false
      ~cursor:None
      [ pull_node ~number:1 ~draft:false ~review:"null" ~rollup:"null" ()
      ; pull_node
          ~author:"null"
          ~mergeable:{|"mergeable":"CONFLICTING",|}
          ~number:2
          ~draft:false
          ~review:"null"
          ~rollup:"null"
          ()
      ; pull_node
          ~author:{|{"name":null}|}
          ~number:3
          ~draft:false
          ~review:"null"
          ~rollup:"null"
          ()
      ; no_commit_node ~number:4
      ]
  in
  let http_post, _ = recording_stub [ ok_response body ] in
  let pulls, undecodable = Pulls.read_repository ~now ~http_post ~token:"t" "o/r" |> read_or_fail in
  Alcotest.(check int) "every row decodes" 0 undecodable;
  let facts =
    List.map
      (fun (p : Pulls.pull_request) ->
        ( p.number
        , p.author
        , match p.mergeable with
          | Pulls.Mergeable -> "mergeable"
          | Pulls.Conflicting -> "conflicting"
          | Pulls.Mergeable_unknown -> "unknown" ))
      pulls
  in
  Alcotest.(check (list (triple int (option string) string)))
    "author name, or none where GitHub gives no node or name"
    [ 1, Some "edgar", "mergeable"
    ; 2, None, "conflicting"
    ; 3, None, "mergeable"
    ; 4, None, "unknown"
    ]
    facts

let test_unknown_mergeable_or_missing_author_is_counted () =
  let body =
    page
      ~has_next:false
      ~cursor:None
      [ pull_node
          ~mergeable:{|"mergeable":"SOMETHING_NEW",|}
          ~number:1
          ~draft:false
          ~review:"null"
          ~rollup:"null"
          ()
      ; pull_node ~mergeable:"" ~number:2 ~draft:false ~review:"null" ~rollup:"null" ()
      ; {|{"number":3,"isDraft":false,
          "updatedAt":"2026-09-23T01:02:03Z","reviewDecision":null,"mergeable":"MERGEABLE",
          "authored":{"nodes":[{"commit":{"parents":{"totalCount":1}}}]},
          "head":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}|}
      ; pull_node ~author:"{}" ~number:4 ~draft:false ~review:"null" ~rollup:"null" ()
      ; pull_node ~number:5 ~draft:false ~review:"null" ~rollup:"null" ()
      ]
  in
  let http_post, _ = recording_stub [ ok_response body ] in
  let pulls, undecodable = Pulls.read_repository ~now ~http_post ~token:"t" "o/r" |> read_or_fail in
  Alcotest.(check int)
    "an unknown mergeable word, a missing mergeable, a missing author or name key are counted"
    4
    undecodable;
  Alcotest.(check (list int)) "none of them is shown as a known state" [ 5 ]
    (List.map (fun (p : Pulls.pull_request) -> p.number) pulls)

(* The head is a merge commit (GitHub's Update branch, an updater Keeper, a
   local [git merge origin/main]): the author is the commit under it that has
   one parent, while the check state stays the head's. *)
let authored_node ~parents ~author =
  Printf.sprintf {|{"commit":{"parents":{"totalCount":%d},"author":{"name":%S}}}|} parents author

let merge_head_node ~number ~authored ~head_rollup =
  Printf.sprintf
    {|{"number":%d,"isDraft":false,
       "updatedAt":"2026-09-23T01:02:03Z","reviewDecision":null,"mergeable":"MERGEABLE",
       "authored":{"nodes":[%s]},
       "head":{"nodes":[{"commit":{"statusCheckRollup":%s}}]}}|}
    number
    (String.concat "," authored)
    head_rollup

let test_a_merge_commit_head_keeps_the_writing_keeper () =
  let body =
    page
      ~has_next:false
      ~cursor:None
      [ merge_head_node
          ~number:1
          ~authored:
            [ authored_node ~parents:1 ~author:"older-keeper"
            ; authored_node ~parents:1 ~author:"edgar"
            ; authored_node ~parents:2 ~author:"pr-updater"
            ]
          ~head_rollup:{|{"state":"PENDING"}|}
      ; merge_head_node
          ~number:2
          ~authored:
            [ authored_node ~parents:1 ~author:"edgar"
            ; authored_node ~parents:2 ~author:"jeong-sik"
            ; authored_node ~parents:2 ~author:"pr-updater"
            ]
          ~head_rollup:{|{"state":"FAILURE"}|}
      ; merge_head_node
          ~number:3
          ~authored:
            [ authored_node ~parents:2 ~author:"pr-updater"
            ; authored_node ~parents:2 ~author:"pr-updater"
            ]
          ~head_rollup:"null"
      ]
  in
  let http_post, _ = recording_stub [ ok_response body ] in
  let pulls, undecodable = Pulls.read_repository ~now ~http_post ~token:"t" "o/r" |> read_or_fail in
  Alcotest.(check int) "every row decodes" 0 undecodable;
  let keepers = [ "edgar"; "older-keeper"; "pr-updater"; "jeong-sik" ] in
  let facts =
    List.map
      (fun (p : Pulls.pull_request) ->
        ( p.number
        , Pulls.keeper_of_author ~keepers p
        , match p.checks with
          | Pulls.Checks_passing -> "passing"
          | Pulls.Checks_failing -> "failing"
          | Pulls.Checks_running -> "running"
          | Pulls.Checks_none -> "none" ))
      pulls
  in
  Alcotest.(check (list (triple int (option string) string)))
    "the Keeper under the merge commits, and the head's check state"
    [ 1, Some "edgar", "running"
    ; 2, Some "edgar", "failing"
    ; 3, None, "none"
    ]
    facts

let test_the_query_reads_head_checks_and_an_author_window () =
  let seen = ref None in
  let http_post ~url:_ ~token:_ ~body =
    seen := Some body;
    ok_response (page ~has_next:false ~cursor:None [])
  in
  let _ = Pulls.read_repository ~now ~http_post ~token:"t" "o/r" in
  match !seen with
  | Some (`Assoc fields) ->
    let query =
      match List.assoc_opt "query" fields with
      | Some (`String query) -> query
      | _ -> failf "no query"
    in
    let contains needle =
      let n = String.length needle and h = String.length query in
      let rec at i = i + n <= h && (String.sub query i n = needle || at (i + 1)) in
      at 0
    in
    Alcotest.(check bool) "checks come from the head commit" true
      (contains "head: commits(last: 1)");
    Alcotest.(check bool) "the author window reads each commit's parent count" true
      (contains "parents { totalCount }");
    (match List.assoc_opt "variables" fields with
     | Some (`Assoc vars) ->
       Alcotest.(check bool) "the window size is sent" true
         (match List.assoc_opt "authorWindow" vars with
          | Some (`Int size) -> size > 1
          | _ -> false)
     | _ -> failf "no variables")
  | _ -> failf "no request was sent"

let pull ~number ~author =
  { Pulls.repo_slug = "jeong-sik/masc"
  ; number
  ; draft = false
  ; checks = Pulls.Checks_none
  ; review = Pulls.Review_none
  ; mergeable = Pulls.Mergeable
  ; author
  ; updated_at = now ()
  }

let test_join_is_exact () =
  let keepers = [ "edgar"; "lucia" ] in
  let join author = Pulls.keeper_of_author ~keepers (pull ~number:1 ~author) in
  Alcotest.(check (option string)) "exact name" (Some "edgar") (join (Some "edgar"));
  Alcotest.(check (option string)) "case differs" None (join (Some "Edgar"));
  Alcotest.(check (option string)) "a person" None (join (Some "jeong-sik"));
  Alcotest.(check (option string)) "no author" None (join None)

let pulls_json snapshot =
  let json = Pulls.snapshot_to_yojson snapshot in
  let open Yojson.Safe.Util in
  ( member "keepers" json
  , json |> member "repositories" |> to_list |> List.concat_map (fun entry ->
      entry |> member "pulls" |> member "pulls" |> to_list) )

let snapshot_with ~keepers pulls =
  { Pulls.initial with
    keepers
  ; repositories =
      [ { Pulls.repository_id = "masc"
        ; url = "https://github.com/jeong-sik/masc.git"
        ; slug = Some "jeong-sik/masc"
        ; pulls = Pulls.Pulls_read { observed_at = now (); pulls; undecodable = 0 }
        }
      ]
  }

let test_json_shape () =
  let snapshot =
    snapshot_with
      ~keepers:(Pulls.Keepers_listed [ "edgar" ])
      [ pull ~number:1 ~author:(Some "edgar")
      ; { (pull ~number:2 ~author:(Some "Edgar")) with mergeable = Pulls.Conflicting }
      ; { (pull ~number:3 ~author:None) with mergeable = Pulls.Mergeable_unknown }
      ]
  in
  let keepers, rows = pulls_json snapshot in
  Alcotest.(check string) "keeper list state" {|{"state":"listed"}|} (Yojson.Safe.to_string keepers);
  let open Yojson.Safe.Util in
  let fields row = row |> member "author", row |> member "keeper", row |> member "mergeable" in
  let expected =
    [ `String "edgar", `String "edgar", `String "mergeable"
    ; `String "Edgar", `Null, `String "conflicting"
    ; `Null, `Null, `String "unknown"
    ]
  in
  List.iter2
    (fun row (author, keeper, mergeable) ->
      let a, k, m = fields row in
      Alcotest.(check string) "author" (Yojson.Safe.to_string author) (Yojson.Safe.to_string a);
      Alcotest.(check string) "keeper" (Yojson.Safe.to_string keeper) (Yojson.Safe.to_string k);
      Alcotest.(check string) "mergeable" (Yojson.Safe.to_string mergeable) (Yojson.Safe.to_string m))
    rows
    expected;
  Alcotest.(check (list string))
    "row keys"
    [ "repo_slug"; "number"; "draft"; "checks"; "review"; "mergeable"
    ; "author"; "keeper"; "updated_at" ]
    (keys (List.hd rows))

(* A Keeper directory that cannot be listed: the snapshot says so instead of
   reading as an empty Keeper list. *)
let test_unreadable_keeper_list_is_visible () =
  if Unix.geteuid () = 0 then Alcotest.skip ();
  let base_path = temp_base_path () in
  register base_path;
  let config = Masc.Workspace.default_config base_path in
  let keepers_dir = Masc.Workspace.keepers_runtime_dir config in
  mkdir_p keepers_dir;
  Unix.chmod keepers_dir 0o000;
  let snapshot =
    Fun.protect
      ~finally:(fun () -> Unix.chmod keepers_dir 0o700)
      (fun () -> Pulls.refresh ~now ~http_post:never_called ~config ~previous:Pulls.initial)
  in
  (match snapshot.keepers with
   | Pulls.Keepers_list_failed _ -> ()
   | Pulls.Keepers_listed _ -> failf "an unreadable Keeper directory must not read as an empty Keeper list"
   | Pulls.Keepers_not_listed -> failf "a refresh must list the Keepers");
  let open Yojson.Safe.Util in
  let keepers = Pulls.snapshot_to_yojson snapshot |> member "keepers" in
  Alcotest.(check string) "state" "list_failed" (keepers |> member "state" |> to_string);
  Alcotest.(check bool) "the reason is carried" true (keepers |> member "reason" |> to_string <> "")

(* [.masc] is read-only and holds no [keepers] directory, so listing the
   Keepers fails to create that directory and raises. The refresh still
   returns and publishes the repositories it read. *)
let test_a_raising_keeper_list_does_not_drop_the_refresh () =
  if Unix.geteuid () = 0 then Alcotest.skip ();
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_base_path () in
  register base_path;
  let config = Masc.Workspace.default_config base_path in
  let masc_dir = Masc.Workspace.masc_root_dir config in
  Alcotest.(check bool) "fixture: no keepers directory yet" false
    (Sys.file_exists (Masc.Workspace.keepers_runtime_dir config));
  Unix.chmod masc_dir 0o500;
  let snapshot =
    Fun.protect
      ~finally:(fun () -> Unix.chmod masc_dir 0o700)
      (fun () ->
        (match Masc.Keeper_meta_store.keeper_names_result config with
         | _ -> failf "the fixture must make the Keeper list read raise"
         | exception (Eio.Cancel.Cancelled _ as e) -> raise e
         | exception _ -> ());
        Pulls.refresh
          ~now
          ~http_post:never_called
          ~config
          ~previous:(snapshot_with ~keepers:(Pulls.Keepers_listed [ "edgar" ]) []))
  in
  (match snapshot.keepers with
   | Pulls.Keepers_list_failed reason ->
     Alcotest.(check bool) "the reason names the raise" true
       (String.starts_with ~prefix:"keeper list read raised" reason)
   | Pulls.Keepers_listed _ -> failf "the previous Keeper list must not stand after a raise"
   | Pulls.Keepers_not_listed -> failf "a refresh must list the Keepers");
  Alcotest.(check bool) "the rows are this refresh's" true
    (Option.is_none snapshot.repositories_error);
  match pulls_by_id snapshot with
  | [ ("masc", Pulls.Pulls_not_read); ("mirror", Pulls.Pulls_not_github) ] -> ()
  | _ -> failf "the registered repositories must be published beside the failed Keeper list"

(* The repository list cannot be read: the previous rows stand, and the
   Keeper list is still read for this refresh. *)
let test_unread_repositories_still_list_keepers () =
  let base_path = temp_base_path () in
  write_file (Config_dir_resolver.repositories_toml_path ~base_path) "not = [toml";
  let previous =
    snapshot_with ~keepers:Pulls.Keepers_not_listed [ pull ~number:1 ~author:(Some "edgar") ]
  in
  let snapshot =
    Pulls.refresh
      ~now
      ~http_post:never_called
      ~config:(Masc.Workspace.default_config base_path)
      ~previous
  in
  Alcotest.(check bool) "the rows are marked old" true (Option.is_some snapshot.repositories_error);
  Alcotest.(check int) "the previous rows stand" 1 (List.length snapshot.repositories);
  match snapshot.keepers with
  | Pulls.Keepers_listed [] -> ()
  | Pulls.Keepers_listed _ -> failf "this workspace persists no Keeper"
  | Pulls.Keepers_list_failed reason -> failf "the Keeper list must be read: %s" reason
  | Pulls.Keepers_not_listed -> failf "the previous Keeper state must not stand"

(* While the list is unread, a pull whose author is a Keeper's name is not
   called that Keeper's; the snapshot state is what says the join is off. *)
let test_unlisted_keepers_join_nothing () =
  let _, rows =
    pulls_json
      (snapshot_with
         ~keepers:(Pulls.Keepers_list_failed "keeper directory unreadable")
         [ pull ~number:1 ~author:(Some "edgar") ])
  in
  match rows with
  | [ row ] ->
    Alcotest.(check bool) "no keeper while unlisted" true (Yojson.Safe.Util.member "keeper" row = `Null)
  | _ -> failf "expected one pull request"

(* The authoring Keeper is not the reader: persisting the reader's meta
   would make its token lookup read its full declaration. *)
let authoring_keeper = "edgar"

let test_persisted_keeper_is_joined () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = ready_base_path ~token:"gho_reader" in
  let config = Masc.Workspace.default_config base_path in
  let meta =
    match Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String authoring_keeper ]) with
    | Ok fixture -> fixture
    | Error detail -> failf "meta fixture: %s" detail
  in
  (match Masc.Keeper_meta_store.replace_snapshot config meta with
   | Ok () -> ()
   | Error detail -> failf "keeper meta persistence failed: %s" detail);
  let author name = Printf.sprintf {|{"name":%S}|} name in
  let node ~number name =
    pull_node ~author:(author name) ~number ~draft:false ~review:"null" ~rollup:"null" ()
  in
  let body =
    page
      ~has_next:false
      ~cursor:None
      [ node ~number:1 authoring_keeper; node ~number:2 (String.capitalize_ascii authoring_keeper) ]
  in
  let http_post, _, _ = counting_stub (ok_response body) in
  let snapshot = Pulls.refresh ~now ~http_post ~config ~previous:Pulls.initial in
  (match snapshot.keepers with
   | Pulls.Keepers_listed names ->
     Alcotest.(check (list string)) "the persisted Keeper" [ authoring_keeper ] names
   | _ -> failf "a persisted Keeper must be listed");
  let _, rows = pulls_json snapshot in
  Alcotest.(check (list string))
    "only the exact author name is a Keeper"
    [ Yojson.Safe.to_string (`String authoring_keeper); "null" ]
    (List.map (fun row -> Yojson.Safe.to_string (Yojson.Safe.Util.member "keeper" row)) rows)

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
        ; Alcotest.test_case "author and mergeable decode" `Quick test_author_and_mergeable_decode
        ; Alcotest.test_case "a merge commit head keeps the writing Keeper" `Quick
            test_a_merge_commit_head_keeps_the_writing_keeper
        ; Alcotest.test_case "query reads head checks and an author window" `Quick
            test_the_query_reads_head_checks_and_an_author_window
        ; Alcotest.test_case
            "unknown mergeable or missing author is counted"
            `Quick
            test_unknown_mergeable_or_missing_author_is_counted
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
        ; Alcotest.test_case
            "a raised refresh marks the rows until the next one returns"
            `Quick
            test_a_raised_refresh_marks_the_rows_until_the_next_one_returns
        ; Alcotest.test_case
            "remote_ssh reader is refused"
            `Quick
            test_remote_ssh_reader_is_refused
        ] )
    ; ( "provider limits"
      , [ Alcotest.test_case
            "rejected token is not sent again"
            `Quick
            test_rejected_token_is_not_sent_again
        ; Alcotest.test_case "rate limit waits for reset" `Quick test_rate_limit_waits_for_reset
        ; Alcotest.test_case
            "secondary limit waits for retry-after"
            `Quick
            test_secondary_limit_waits_for_retry_after
        ; Alcotest.test_case "plain 403 is forbidden" `Quick test_plain_403_is_forbidden
        ] )
    ; ( "keeper join"
      , [ Alcotest.test_case "join is exact" `Quick test_join_is_exact
        ; Alcotest.test_case "json shape" `Quick test_json_shape
        ; Alcotest.test_case
            "unreadable keeper list is visible"
            `Quick
            test_unreadable_keeper_list_is_visible
        ; Alcotest.test_case
            "a raising keeper list does not drop the refresh"
            `Quick
            test_a_raising_keeper_list_does_not_drop_the_refresh
        ; Alcotest.test_case
            "unread repositories still list keepers"
            `Quick
            test_unread_repositories_still_list_keepers
        ; Alcotest.test_case
            "unlisted keepers join nothing"
            `Quick
            test_unlisted_keepers_join_nothing
        ; Alcotest.test_case "persisted keeper is joined" `Quick test_persisted_keeper_is_joined
        ] )
    ]
