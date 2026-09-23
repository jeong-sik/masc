type check_state =
  | Checks_passing
  | Checks_failing
  | Checks_running
  | Checks_none

type review_state =
  | Review_approved
  | Review_changes_requested
  | Review_waiting
  | Review_none

type mergeable =
  | Mergeable
  | Conflicting
  | Mergeable_unknown

type pull_request =
  { repo_slug : string
  ; number : int
  ; title : string
  ; head_branch : string
  ; draft : bool
  ; checks : check_state
  ; review : review_state
  ; mergeable : mergeable
  ; author : string option
  ; updated_at : float
  }

type failure =
  | Repository_not_visible
  | Token_rejected
  | Rate_limited of { reset_at : float option }
  | Forbidden of { status : int }
  | Http_status of { status : int }
  | Graphql_errors of { messages : string list }
  | Transport_failed of string
  | Response_unreadable of string

type repository_pulls =
  | Pulls_not_read
  | Pulls_read of
      { observed_at : float
      ; pulls : pull_request list
      ; undecodable : int
      }
  | Pulls_failed of
      { observed_at : float
      ; failure : failure
      }
  | Pulls_not_github

type reader =
  | Reader_not_declared
  | Reader_declaration_invalid of string
  | Reader_keeper_missing of { keeper : string }
  | Reader_token_unavailable of
      { keeper : string
      ; reason : string
      }
  | Reader_ready of { keeper : string }

type repository_entry =
  { repository_id : string
  ; url : string
  ; slug : string option
  ; pulls : repository_pulls
  }

type keeper_names =
  | Keepers_not_listed
  | Keepers_listed of string list
  | Keepers_list_failed of string

type snapshot =
  { reader : reader
  ; repositories_error : string option
  ; repositories : repository_entry list
  ; keepers : keeper_names
  ; rejected_token_digest : string option
  }

let initial =
  { reader = Reader_not_declared
  ; repositories_error = None
  ; repositories = []
  ; keepers = Keepers_not_listed
  ; rejected_token_digest = None
  }

type response =
  { status : int
  ; body : string
  ; rate_limit_remaining : int option
  ; rate_limit_reset : float option
  ; retry_after_s : int option
  }

type http_post =
  url:string -> token:string -> body:Yojson.Safe.t -> (response, string) result

let graphql_url = "https://api.github.com/graphql"
let github_hostname = "github.com"

(* GitHub caps a connection page at 100 nodes; asking for the cap keeps a
   repository with fewer than 100 open pull requests at one request. *)
let page_size = 100

(* --- Transport --- *)

let curl_meta_marker = "\n--MASC-GITHUB-META--\n"

(* [%header{...}] needs curl 7.84. An older curl prints the variable back
   unexpanded, which fails the number parse below and reads as "GitHub sent
   no such header" rather than as a wrong reset time. *)
let curl_write_out =
  curl_meta_marker
  ^ "%{http_code}\n%header{x-ratelimit-remaining}\n%header{x-ratelimit-reset}\n%header{retry-after}"

let curl_timeout_sec = 20

let rfind_substring ~needle haystack =
  let n = String.length needle in
  let h = String.length haystack in
  let rec loop i =
    if i < 0 then None
    else if String.sub haystack i n = needle then Some i
    else loop (i - 1)
  in
  if n = 0 || n > h then None else loop (h - n)

let response_of_curl_output output =
  match rfind_substring ~needle:curl_meta_marker output with
  | None -> Error "curl output carried no status trailer"
  | Some idx ->
    let body = String.sub output 0 idx in
    let meta_start = idx + String.length curl_meta_marker in
    let meta = String.sub output meta_start (String.length output - meta_start) in
    (match String.split_on_char '\n' meta with
     | status_raw :: remaining_raw :: reset_raw :: retry_after_raw :: _ ->
       (match int_of_string_opt (String.trim status_raw) with
        | None | Some 0 -> Error "curl reported no HTTP status"
        | Some status ->
          Ok
            { status
            ; body
            ; rate_limit_remaining = int_of_string_opt (String.trim remaining_raw)
            ; rate_limit_reset = Option.map Float.of_int (int_of_string_opt (String.trim reset_raw))
            ; retry_after_s =
                (* GitHub sends delay-seconds; an HTTP-date or a negative
                   number is not a wait this reader can use, so it reads as
                   no header. *)
                (match int_of_string_opt (String.trim retry_after_raw) with
                 | Some seconds when seconds >= 0 -> Some seconds
                 | Some _ | None -> None)
            })
     | _ -> Error "curl status trailer is incomplete")

let default_http_post ~url ~token ~body =
  let argv =
    [ "curl"
    ; "-q"
    ; "-sS"
    ; "--max-time"
    ; Int.to_string curl_timeout_sec
    ; "-H"
    ; "@-"
    ; "-H"
    ; "Content-Type: application/json"
    ; "-H"
    ; "Accept: application/json"
    ; "--data-binary"
    ; Yojson.Safe.to_string body
    ; "-w"
    ; curl_write_out
    ; url
    ]
  in
  let status, stdout, stderr =
    Process_eio.run_argv_with_stdin_and_status_split
      ~timeout_sec:(Float.of_int (curl_timeout_sec + 5))
      ~stdin_content:("Authorization: bearer " ^ token ^ "\n")
      argv
  in
  match status with
  | Unix.WEXITED 0 -> response_of_curl_output stdout
  | Unix.WEXITED code ->
    Error (Printf.sprintf "curl exit code %d: %s" code (String.trim stderr))
  | Unix.WSIGNALED signal -> Error (Printf.sprintf "curl killed by signal %d" signal)
  | Unix.WSTOPPED signal -> Error (Printf.sprintf "curl stopped by signal %d" signal)

(* --- Remote slug --- *)

let github_remote_prefixes =
  [ "https://github.com/"; "git@github.com:"; "ssh://git@github.com/" ]

let strip_suffix ~suffix s =
  if String.ends_with ~suffix s
  then String.sub s 0 (String.length s - String.length suffix)
  else s

let github_slug_of_remote remote =
  let remote = String.trim remote in
  List.find_map
    (fun prefix ->
      if String.starts_with ~prefix remote
      then
        Some (String.sub remote (String.length prefix) (String.length remote - String.length prefix))
      else None)
    github_remote_prefixes
  |> Fun.flip Option.bind (fun path ->
    let slug = path |> strip_suffix ~suffix:"/" |> strip_suffix ~suffix:".git" in
    match String.split_on_char '/' slug with
    | [ owner; repo ] when owner <> "" && repo <> "" -> Some slug
    | _ -> None)

(* --- GraphQL --- *)

let query =
  {|query($owner: String!, $name: String!, $first: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, first: $first, after: $after, orderBy: {field: UPDATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title headRefName isDraft updatedAt reviewDecision mergeable
        commits(last: 10) { nodes { commit { parents { totalCount } author { name } statusCheckRollup { state } } } }
      }
    }
  }
}|}

let request_body ~owner ~name ~after =
  `Assoc
    [ "query", `String query
    ; ( "variables"
      , `Assoc
          [ "owner", `String owner
          ; "name", `String name
          ; "first", `Int page_size
          ; ("after", match after with Some cursor -> `String cursor | None -> `Null)
          ] )
    ]

let field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

(* The wire enums are read once, here. An unknown member is [None]: the row
   is counted as undecodable rather than shown as a state GitHub did not
   report. *)
let check_state_of_wire = function
  | "SUCCESS" -> Some Checks_passing
  | "FAILURE" | "ERROR" -> Some Checks_failing
  | "PENDING" | "EXPECTED" -> Some Checks_running
  | _ -> None

let review_state_of_wire = function
  | "APPROVED" -> Some Review_approved
  | "CHANGES_REQUESTED" -> Some Review_changes_requested
  | "REVIEW_REQUIRED" -> Some Review_waiting
  | _ -> None

let mergeable_of_wire = function
  | "MERGEABLE" -> Some Mergeable
  | "CONFLICTING" -> Some Conflicting
  | "UNKNOWN" -> Some Mergeable_unknown
  | _ -> None

let decode_checks node =
  match Option.bind (field "commits" node) (field "nodes") with
  | Some (`List []) -> Some Checks_none
  | Some (`List nodes) ->
    (* [commits(last: N)] returns its window oldest first, so the head commit
       is the last node. The query asks for [statusCheckRollup], so only an
       explicit [null] means "no checks"; a missing key is a shape this reader
       does not know. *)
    (match List.rev nodes with
     | [] -> Some Checks_none
     | head :: _ ->
       (match Option.bind (field "commit" head) (field "statusCheckRollup") with
        | None -> None
        | Some `Null -> Some Checks_none
        | Some rollup ->
          (match field "state" rollup with
           | Some (`String state) -> check_state_of_wire state
           | _ -> None)))
  | _ -> None

let decode_review node =
  match field "reviewDecision" node with
  | Some `Null -> Some Review_none
  | None -> None
  | Some (`String decision) -> review_state_of_wire decision
  | Some _ -> None

let decode_mergeable node =
  match field "mergeable" node with
  | Some (`String state) -> mergeable_of_wire state
  | _ -> None

(* [Some None] is GitHub saying there is no author name to read: no commit,
   a [null] author, or a [null] name. The query asks for
   [parents { totalCount }] and [author { name }], so a missing key is a shape
   this reader does not know and reads [None].

   A merge commit (two or more parents) does not say who wrote the pull
   request: GitHub's "Update branch", pr-updater's update-branch and a local
   [git merge origin/main] all make one, and its author is whoever brought the
   base in. The author is the most recent commit with one parent. A window
   that is all merge commits reads [Some None]: the pull request is counted as
   no Keeper's rather than attached to the wrong one. *)
let decode_author node =
  match Option.bind (field "commits" node) (field "nodes") with
  | Some (`List []) -> Some None
  | Some (`List nodes) ->
    let rec newest_single_parent = function
      | [] -> Some None
      | node :: rest ->
        (match Option.bind (field "commit" node) (field "parents") with
         | None -> None
         | Some parents ->
           (match field "totalCount" parents with
            | Some (`Int 1) ->
              (match Option.bind (field "commit" node) (field "author") with
               | None -> None
               | Some `Null -> Some None
               | Some author ->
                 (match field "name" author with
                  | Some `Null -> Some None
                  | Some (`String name) -> Some (Some name)
                  | _ -> None))
            | Some (`Int _) -> newest_single_parent rest
            | _ -> None))
    in
    newest_single_parent (List.rev nodes)
  | _ -> None

let decode_pull ~repo_slug node =
  match
    ( field "number" node
    , field "title" node
    , field "headRefName" node
    , field "isDraft" node
    , field "updatedAt" node )
  with
  | ( Some (`Int number)
    , Some (`String title)
    , Some (`String head_branch)
    , Some (`Bool draft)
    , Some (`String updated_raw) ) ->
    (match
       ( Time_codec.parse_rfc3339_opt updated_raw
       , decode_checks node
       , decode_review node
       , decode_mergeable node
       , decode_author node )
     with
     | Some updated_at, Some checks, Some review, Some mergeable, Some author ->
       Some
         { repo_slug
         ; number
         ; title
         ; head_branch
         ; draft
         ; checks
         ; review
         ; mergeable
         ; author
         ; updated_at
         }
     | _ -> None)
  | _ -> None

type graphql_error_kind =
  | Error_not_found
  | Error_rate_limited
  | Error_other

(* Only a NOT_FOUND on the repository itself means the reader cannot see the
   repository; one on a nested field says nothing about the repository. *)
let graphql_error_kind error =
  match field "type" error, field "path" error with
  | Some (`String "NOT_FOUND"), Some (`List [ `String "repository" ]) -> Error_not_found
  | Some (`String "RATE_LIMITED"), _ -> Error_rate_limited
  | _ -> Error_other

type page =
  { page_pulls : pull_request list
  ; page_undecodable : int
  ; next_cursor : string option
  }

let failure_of_graphql_errors ~(response : response) errors =
  let kinds = List.map graphql_error_kind errors in
  if List.mem Error_rate_limited kinds
  then Rate_limited { reset_at = response.rate_limit_reset }
  else if List.mem Error_not_found kinds
  then Repository_not_visible
  else
    Graphql_errors
      { messages =
          List.map
            (fun error ->
              match field "message" error with
              | Some (`String message) -> message
              | _ -> Yojson.Safe.to_string error)
            errors
      }

let decode_page ~repo_slug (response : response) =
  match Yojson.Safe.from_string response.body with
  | exception Yojson.Json_error message -> Error (Response_unreadable message)
  | json ->
    (match field "errors" json with
     | Some (`List (_ :: _ as errors)) -> Error (failure_of_graphql_errors ~response errors)
     | _ ->
       let connection =
         Option.bind (Option.bind (field "data" json) (field "repository")) (field "pullRequests")
       in
       (match connection with
        | None -> Error (Response_unreadable "data.repository.pullRequests is absent")
        | Some connection ->
          (match field "nodes" connection, field "pageInfo" connection with
           | Some (`List nodes), Some page_info ->
             let pulls = List.filter_map (decode_pull ~repo_slug) nodes in
             let undecodable = List.length nodes - List.length pulls in
             (match field "hasNextPage" page_info, field "endCursor" page_info with
              | Some (`Bool false), _ ->
                Ok { page_pulls = pulls; page_undecodable = undecodable; next_cursor = None }
              | Some (`Bool true), Some (`String cursor) ->
                Ok
                  { page_pulls = pulls
                  ; page_undecodable = undecodable
                  ; next_cursor = Some cursor
                  }
              | _ -> Error (Response_unreadable "pageInfo has no usable next page cursor"))
           | _ -> Error (Response_unreadable "pullRequests has no nodes or pageInfo"))))

(* GitHub's secondary rate limit answers 403 or 429 with [retry-after] while
   [x-ratelimit-remaining] is still above 0. Its wait is the one GitHub names
   first; asking during it can get the integration blocked, and the token is
   the reader Keeper's own account token. *)
let rate_limited ~now_s (response : response) =
  let reset_at =
    match response.retry_after_s with
    | Some seconds -> Some (now_s +. Float.of_int seconds)
    | None -> response.rate_limit_reset
  in
  Rate_limited { reset_at }

let failure_of_status ~now_s (response : response) =
  match response.status with
  | 401 -> Some Token_rejected
  | 429 -> Some (rate_limited ~now_s response)
  | 403 when response.rate_limit_remaining = Some 0 || Option.is_some response.retry_after_s ->
    Some (rate_limited ~now_s response)
  | 403 -> Some (Forbidden { status = 403 })
  | status when status >= 200 && status < 300 -> None
  | status -> Some (Http_status { status })

let read_repository ~now ~http_post ~token repo_slug =
  let owner, name =
    match String.index_opt repo_slug '/' with
    | Some i ->
      String.sub repo_slug 0 i, String.sub repo_slug (i + 1) (String.length repo_slug - i - 1)
    | None -> repo_slug, ""
  in
  let failed failure = Pulls_failed { observed_at = now (); failure } in
  let rec read_pages ~after ~seen_cursors ~pulls ~undecodable =
    match http_post ~url:graphql_url ~token ~body:(request_body ~owner ~name ~after) with
    | Error message -> failed (Transport_failed message)
    | Ok response ->
      (match failure_of_status ~now_s:(now ()) response with
       | Some failure -> failed failure
       | None ->
         (match decode_page ~repo_slug response with
          | Error failure -> failed failure
          | Ok page ->
            let pulls = List.rev_append page.page_pulls pulls in
            let undecodable = undecodable + page.page_undecodable in
            (match page.next_cursor with
             | None -> Pulls_read { observed_at = now (); pulls = List.rev pulls; undecodable }
             | Some cursor when List.mem cursor seen_cursors ->
               (* A cursor GitHub already handed out would page forever. *)
               failed (Response_unreadable "GitHub repeated a page cursor")
             | Some cursor ->
               read_pages
                 ~after:(Some cursor)
                 ~seen_cursors:(cursor :: seen_cursors)
                 ~pulls
                 ~undecodable)))
  in
  read_pages ~after:None ~seen_cursors:[] ~pulls:[] ~undecodable:0

(* --- Reader --- *)

let repositories_table = "repositories"
let pr_reader_key = "pr_reader"

type credential =
  { keeper : string
  ; token : string
  }

let reader_of_declaration ~(config : Workspace.config) keeper =
  let base_path = config.base_path in
  let keeper = String.trim keeper in
  if not (Keeper_config.validate_name keeper)
  then Error (Reader_declaration_invalid (Keeper_config.invalid_name_error keeper))
  else (
    match Config_dir_resolver.keeper_toml_path_opt_for_base_path ~base_path keeper with
    | None -> Error (Reader_keeper_missing { keeper })
    | Some _ ->
      (* The login lane, not the host directory: a Remote_ssh Keeper's login
         lives on its endpoint, and this host reading its own directory for
         that Keeper would answer with a token the Keeper never wrote. *)
      (match
         Keeper_github_login_lane.stored_token
           ~config
           ~keeper_name:keeper
           ~hostname:github_hostname
       with
       | Error refusal ->
         Error
           (Reader_token_unavailable
              { keeper; reason = Keeper_github_login_lane.stored_token_error_to_string refusal })
       | Ok token -> Ok { keeper; token }))

let declaration_invalid fmt = Printf.ksprintf (fun m -> Error (Reader_declaration_invalid m)) fmt

let reader_of_table ~config entries =
  match List.find_opt (fun (key, _) -> not (String.equal key pr_reader_key)) entries with
  | Some (key, _) -> declaration_invalid "[%s] has unknown key %S" repositories_table key
  | None ->
    (match List.assoc_opt pr_reader_key entries with
     | None -> Error Reader_not_declared
     | Some (Otoml.TomlString keeper) -> reader_of_declaration ~config keeper
     | Some _ ->
       declaration_invalid "[%s] %s must be a Keeper name string" repositories_table pr_reader_key)

let resolve_reader ~(config : Workspace.config) =
  let base_path = config.base_path in
  let path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path in
  if not (Sys.file_exists path)
  then Error Reader_not_declared
  else (
    match Safe_ops.read_file_safe path with
    | Error reason -> Error (Reader_declaration_invalid reason)
    | Ok text ->
      (match Otoml.Parser.from_string_result text with
       | Error reason -> Error (Reader_declaration_invalid reason)
       | Ok toml ->
         (match Otoml.find_opt toml Fun.id [ repositories_table ] with
          | None -> Error Reader_not_declared
          | Some (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) ->
            reader_of_table ~config entries
          | Some _ -> declaration_invalid "[%s] must be a table" repositories_table)))

(* A digest, so the snapshot can tell a new token from the refused one without
   holding either. *)
let token_digest token = Digest.BLAKE256.(to_hex (string token))

(* GitHub's own answer about a credential or a quota, held until the fact it
   names can have changed: a refused token until hosts.yml holds another one,
   an exhausted limit until GitHub's reset time. Asking again sooner cannot get
   a different answer. *)
let held_answer ~now_s ~digest ~previous_digest = function
  | Pulls_failed { failure = Token_rejected; _ } as held
    when Option.equal String.equal previous_digest (Some digest) -> Some held
  | Pulls_failed { failure = Rate_limited { reset_at = Some reset_at }; _ } as held
    when now_s < reset_at -> Some held
  | Pulls_not_read | Pulls_not_github | Pulls_read _ | Pulls_failed _ -> None

let is_token_rejected = function
  | Pulls_failed { failure = Token_rejected; _ } -> true
  | Pulls_not_read | Pulls_not_github | Pulls_read _ | Pulls_failed _ -> false

(* Listing the Keepers creates their directory when it is missing, and a
   failed mkdir raises. The raise is this list's failure, not the refresh's:
   the GitHub reads beside it still publish. *)
let list_keepers config =
  match Keeper_meta_store.keeper_names_result config with
  | Ok names -> Keepers_listed names
  | Error reason -> Keepers_list_failed reason
  | exception (Eio.Cancel.Cancelled _ as e) -> raise e
  | exception exn -> Keepers_list_failed ("keeper list read raised " ^ Printexc.to_string exn)

(* Exact match: git records the author name as the runtime exported it, and
   a Keeper name that differs in case is another name. *)
let keeper_of_author ~keepers pull =
  match pull.author with
  | Some author when List.exists (String.equal author) keepers -> Some author
  | Some _ | None -> None

let refresh ~now ~http_post ~(config : Workspace.config) ~previous =
  let base_path = config.base_path in
  let now_s = now () in
  let keepers = list_keepers config in
  let credential = resolve_reader ~config in
  let reader =
    match credential with
    | Ok { keeper; token = _ } -> Reader_ready { keeper }
    | Error reader -> reader
  in
  match Repo_store.load_all ~base_path with
  | Error reason ->
    { reader
    ; repositories_error = Some ("repository list unread: " ^ reason)
    ; repositories = previous.repositories
    ; keepers
    ; rejected_token_digest = previous.rejected_token_digest
    }
  | Ok repos ->
    let previous_pulls id =
      match
        List.find_opt (fun entry -> String.equal entry.repository_id id) previous.repositories
      with
      | Some entry -> entry.pulls
      | None -> Pulls_not_read
    in
    let entry (repo : Repo_manager_types.repository) =
      let slug = github_slug_of_remote repo.url in
      let pulls =
        match slug, credential with
        | None, _ -> Pulls_not_github
        | Some slug, Ok { token; keeper = _ } ->
          (match
             held_answer
               ~now_s
               ~digest:(token_digest token)
               ~previous_digest:previous.rejected_token_digest
               (previous_pulls repo.id)
           with
           | Some held -> held
           | None -> read_repository ~now ~http_post ~token slug)
        (* An earlier read would show checks and reviews the server can no
           longer vouch for; [reader] says why nothing is read now. *)
        | Some _, Error _ -> Pulls_not_read
      in
      { repository_id = repo.id; url = repo.url; slug; pulls }
    in
    let repositories = List.map entry repos in
    let rejected_token_digest =
      match credential with
      | Ok { token; keeper = _ }
        when List.exists (fun entry -> is_token_rejected entry.pulls) repositories ->
        Some (token_digest token)
      | Ok _ | Error _ -> None
    in
    { reader
    ; repositories_error = None
    ; repositories
    ; keepers
    ; rejected_token_digest
    }

(* --- JSON --- *)

let check_state_to_string = function
  | Checks_passing -> "passing"
  | Checks_failing -> "failing"
  | Checks_running -> "running"
  | Checks_none -> "none"

let review_state_to_string = function
  | Review_approved -> "approved"
  | Review_changes_requested -> "changes_requested"
  | Review_waiting -> "waiting"
  | Review_none -> "none"

let mergeable_to_string = function
  | Mergeable -> "mergeable"
  | Conflicting -> "conflicting"
  | Mergeable_unknown -> "unknown"

let string_or_null = function
  | Some value -> `String value
  | None -> `Null

(* ["keeper"] is [null] both for a pull request no Keeper authored and while
   the Keeper list is unread; the snapshot's ["keepers"] state tells the two
   apart. *)
let pull_request_to_yojson ~keepers pull =
  let keeper =
    match keepers with
    | Keepers_listed names -> keeper_of_author ~keepers:names pull
    | Keepers_not_listed | Keepers_list_failed _ -> None
  in
  `Assoc
    [ "repo_slug", `String pull.repo_slug
    ; "number", `Int pull.number
    ; "title", `String pull.title
    ; "head_branch", `String pull.head_branch
    ; "draft", `Bool pull.draft
    ; "checks", `String (check_state_to_string pull.checks)
    ; "review", `String (review_state_to_string pull.review)
    ; "mergeable", `String (mergeable_to_string pull.mergeable)
    ; "author", string_or_null pull.author
    ; "keeper", string_or_null keeper
    ; "updated_at", `Float pull.updated_at
    ]

let failure_to_yojson = function
  | Repository_not_visible -> `Assoc [ "kind", `String "repository_not_visible" ]
  | Token_rejected -> `Assoc [ "kind", `String "token_rejected" ]
  | Rate_limited { reset_at } ->
    `Assoc
      [ "kind", `String "rate_limited"
      ; ("reset_at", match reset_at with Some at -> `Float at | None -> `Null)
      ]
  | Forbidden { status } -> `Assoc [ "kind", `String "forbidden"; "status", `Int status ]
  | Http_status { status } -> `Assoc [ "kind", `String "http_status"; "status", `Int status ]
  | Graphql_errors { messages } ->
    `Assoc
      [ "kind", `String "graphql_errors"
      ; "messages", `List (List.map (fun m -> `String m) messages)
      ]
  | Transport_failed message ->
    `Assoc [ "kind", `String "transport_failed"; "message", `String message ]
  | Response_unreadable message ->
    `Assoc [ "kind", `String "response_unreadable"; "message", `String message ]

let repository_pulls_to_yojson ~keepers = function
  | Pulls_not_read -> `Assoc [ "state", `String "not_read" ]
  | Pulls_not_github -> `Assoc [ "state", `String "not_github" ]
  | Pulls_read { observed_at; pulls; undecodable } ->
    `Assoc
      [ "state", `String "read"
      ; "observed_at", `Float observed_at
      ; "pulls", `List (List.map (pull_request_to_yojson ~keepers) pulls)
      ; "undecodable", `Int undecodable
      ]
  | Pulls_failed { observed_at; failure } ->
    `Assoc
      [ "state", `String "failed"
      ; "observed_at", `Float observed_at
      ; "failure", failure_to_yojson failure
      ]

let reader_to_yojson = function
  | Reader_not_declared -> `Assoc [ "state", `String "not_declared" ]
  | Reader_declaration_invalid reason ->
    `Assoc [ "state", `String "declaration_invalid"; "reason", `String reason ]
  | Reader_keeper_missing { keeper } ->
    `Assoc [ "state", `String "keeper_missing"; "keeper", `String keeper ]
  | Reader_token_unavailable { keeper; reason } ->
    `Assoc
      [ "state", `String "token_unavailable"; "keeper", `String keeper; "reason", `String reason ]
  | Reader_ready { keeper } -> `Assoc [ "state", `String "ready"; "keeper", `String keeper ]

let entry_to_yojson ~keepers entry =
  `Assoc
    [ "repository_id", `String entry.repository_id
    ; "url", `String entry.url
    ; ("slug", match entry.slug with Some slug -> `String slug | None -> `Null)
    ; "pulls", repository_pulls_to_yojson ~keepers entry.pulls
    ]

let keeper_names_to_yojson = function
  | Keepers_not_listed -> `Assoc [ "state", `String "not_listed" ]
  | Keepers_listed _ -> `Assoc [ "state", `String "listed" ]
  | Keepers_list_failed reason ->
    `Assoc [ "state", `String "list_failed"; "reason", `String reason ]

let snapshot_to_yojson snapshot =
  let keepers = snapshot.keepers in
  `Assoc
    [ "reader", reader_to_yojson snapshot.reader
    ; ( "repositories_error"
      , match snapshot.repositories_error with
        | Some reason -> `String reason
        | None -> `Null )
    ; "keepers", keeper_names_to_yojson keepers
    ; "repositories", `List (List.map (entry_to_yojson ~keepers) snapshot.repositories)
    ]


(* --- Projection --- *)

let projection = Atomic.make initial
let current () = Atomic.get projection

(* RFC-0465 §3: pull request state changes at the pace a person reads it, and
   three repositories every 60 s spend about 4% of the reader account's
   5000 GraphQL points an hour. *)
(* The previous rows stay, but not as a current reading: a refresh that
   raises on every tick would otherwise show the last good counts
   indefinitely with nothing saying they stopped updating. The next refresh
   that returns sets [repositories_error] from its own reading. *)
let refresh_raised ~previous exn =
  { previous with repositories_error = Some ("refresh raised " ^ Printexc.to_string exn) }

let poll_interval_s = 60.0

let start ~sw ~clock ~config =
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      (try
         let next =
           refresh
             ~now:(fun () -> Eio.Time.now clock)
             ~http_post:default_http_post
             ~config
             ~previous:(current ())
         in
         Atomic.set projection next
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Server.warn "repository_pulls: refresh raised %s; keeping the previous rows"
           (Printexc.to_string exn);
         Atomic.set projection (refresh_raised ~previous:(current ()) exn));
      Eio.Time.sleep clock poll_interval_s;
      loop ()
    in
    loop ())
