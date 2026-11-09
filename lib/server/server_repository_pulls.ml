(* The data types, the JSON projection and the published value moved to
   Repository_pulls in [masc] (RFC keeper-world-state-shows-open-work S1).
   This module keeps the reader: the transport, the GraphQL query and its
   decoding, the reader credential, the refresh loop, the Lane Add-on GitHub
   read and the REST read. *)
open Repository_pulls

type response =
  { status : int
  ; body : string
  ; rate_limit_remaining : int option
  ; rate_limit_reset : float option
  ; retry_after_s : int option
  }

type http_post =
  url:string -> token:string -> body:Yojson.Safe.t -> (response, string) result

(* Defaults only: [\[repositories\] github_host]/[graphql_url] override both
   without touching code, so a GitHub Enterprise host is configuration, not a
   patch. *)
let default_github_host = "github.com"
let default_graphql_url = "https://api.github.com/graphql"

(* GitHub caps a connection page at 100 nodes; asking for the cap keeps a
   repository with fewer than 100 open pull requests at one request. *)
let page_size = 100

(* How many of a pull request's newest commits are searched for its author
   (RFC-0465 §2.1). Merge commits are skipped, so the window has to reach past
   a run of them. Measured 2026-09-23 over the open pull requests of
   jeong-sik/masc: the longest run of merge commits ending at the head was 1,
   the longest anywhere in the last 30 commits was 4. The measured GraphQL
   cost of a page goes from 1 to 2 points with this window. A window of only
   merge commits reads as no author, which counts the pull request as not a
   Keeper's rather than joining it to the wrong one. *)
let author_window = 10

(* --- Transport --- *)

let curl_meta_marker = "\n--MASC-GITHUB-META--\n"

(* [%header{...}] needs curl 7.84. An older curl prints the variable back
   unexpanded, which fails the number parse below and reads as "GitHub sent
   no such header" rather than as a wrong reset time. *)
let curl_write_out =
  curl_meta_marker
  ^ "%{http_code}\n%header{x-ratelimit-remaining}\n%header{x-ratelimit-reset}\n%header{retry-after}"

let curl_timeout_sec = 20

let response_of_curl_output output =
  match String_util.rfind_substring output curl_meta_marker with
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

(* One curl call. The token goes to curl on stdin ([-H @-]), never on the
   command line where other local users could read it from the process table.
   The [-H @-] option is written here, so no caller can leave it out; [options]
   are the ones that differ between calls. *)
let run_curl ~token ~url options =
  let argv =
    [ "curl"; "-q"; "-sS"; "--max-time"; Int.to_string curl_timeout_sec; "-H"; "@-" ]
    @ options
    @ [ "-w"; curl_write_out; url ]
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

let default_http_post ~url ~token ~body =
  run_curl
    ~token
    ~url
    [ "-H"
    ; "Content-Type: application/json"
    ; "-H"
    ; "Accept: application/json"
    ; "--data-binary"
    ; Yojson.Safe.to_string body
    ]

type http_get = url:string -> token:string -> (response, string) result

let default_http_get ~url ~token =
  run_curl ~token ~url [ "-H"; "Accept: application/vnd.github+json" ]

(* --- Remote slug --- *)

(* The text before and after the host in the three spellings git accepts:
   [https://<host>/], [git@<host>:], [ssh://git@<host>/]. *)
let github_remote_spellings = [ "https://", "/"; "git@", ":"; "ssh://git@", "/" ]

(* DNS names are case-insensitive (RFC 4343), so the host segment is compared
   in lower case. The scheme, the user and the [owner/repo] path keep their
   case. *)
let path_after_host ~host remote (lead, trail) =
  let lead_length = String.length lead in
  let host_length = String.length host in
  let prefix_length = lead_length + host_length + String.length trail in
  if String.length remote >= prefix_length
     && String.starts_with ~prefix:lead remote
     && String.equal (String.lowercase_ascii (String.sub remote lead_length host_length)) host
     && String.equal (String.sub remote (lead_length + host_length) (String.length trail)) trail
  then Some (String.sub remote prefix_length (String.length remote - prefix_length))
  else None

let strip_suffix ~suffix s =
  if String.ends_with ~suffix s
  then String.sub s 0 (String.length s - String.length suffix)
  else s

let github_slug_of_remote ?(host = default_github_host) remote =
  let remote = String.trim remote in
  let host = String.lowercase_ascii host in
  List.find_map (path_after_host ~host remote) github_remote_spellings
  |> Fun.flip Option.bind (fun path ->
    let slug = path |> strip_suffix ~suffix:"/" |> strip_suffix ~suffix:".git" in
    match String.split_on_char '/' slug with
    | [ owner; repo ] when owner <> "" && repo <> "" -> Some slug
    | _ -> None)

(* --- GraphQL --- *)

let query =
  {|query($owner: String!, $name: String!, $first: Int!, $after: String, $authorWindow: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, first: $first, after: $after, orderBy: {field: UPDATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number isDraft reviewDecision mergeable title headRefOid
        latestReviews(first: 10) { pageInfo { hasNextPage } nodes { state author { __typename login } commit { oid } } }
        head: commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        authored: commits(last: $authorWindow) { nodes { commit { parents { totalCount } author { name } } } }
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
          ; "authorWindow", `Int author_window
          ; ("after", match after with Some cursor -> `String cursor | None -> `Null)
          ] )
    ]

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

(* The check state is the head commit's, merge commit or not: the head is
   what GitHub ran the checks on. *)
let decode_checks node =
  match
    Option.bind
      (Json_util.assoc_member_opt "head" node)
      (Json_util.assoc_member_opt "nodes")
  with
  | Some (`List []) -> Some Checks_none
  | Some (`List (last :: _)) ->
    (* The query asks for [statusCheckRollup], so only an explicit [null]
       means "no checks"; a missing key is a shape this reader does not know. *)
    (match
       Option.bind
         (Json_util.assoc_member_opt "commit" last)
         (Json_util.assoc_member_opt "statusCheckRollup")
     with
     | None -> None
     | Some `Null -> Some Checks_none
     | Some rollup ->
       (match Json_util.assoc_member_opt "state" rollup with
        | Some (`String state) -> check_state_of_wire state
        | _ -> None))
  | _ -> None

let decode_review node =
  match Json_util.assoc_member_opt "reviewDecision" node with
  | Some `Null -> Some Review_none
  | None -> None
  | Some (`String decision) -> review_state_of_wire decision
  | Some _ -> None

let decode_mergeable node =
  match Json_util.assoc_member_opt "mergeable" node with
  | Some (`String state) -> mergeable_of_wire state
  | _ -> None

(* One commit of the author window: its parent count and author name.
   [Some (_, None)] is GitHub giving a [null] author or name. The query asks
   for both keys, so a missing one is a shape this reader does not know and
   reads [None]. *)
let decode_authored_commit node =
  let commit = Json_util.assoc_member_opt "commit" node in
  let parents =
    match
      Option.bind
        (Option.bind commit (Json_util.assoc_member_opt "parents"))
        (Json_util.assoc_member_opt "totalCount")
    with
    | Some (`Int count) -> Some count
    | _ -> None
  in
  let author =
    match Option.bind commit (Json_util.assoc_member_opt "author") with
    | None -> None
    | Some `Null -> Some None
    | Some author ->
      (match Json_util.assoc_member_opt "name" author with
       | Some `Null -> Some None
       | Some (`String name) -> Some (Some name)
       | _ -> None)
  in
  match parents, author with
  | Some parents, Some author -> Some (parents, author)
  | _ -> None

(* The author of the newest commit with one parent (RFC-0465 §2.1). A merge
   commit's author is whoever brought the base in -- GitHub's Update branch,
   an updater Keeper, a local [git merge] -- not who wrote the pull request.
   [Some None] is no such commit in the window, or GitHub giving that
   commit no author name. *)
let decode_author node =
  match
    Option.bind
      (Json_util.assoc_member_opt "authored" node)
      (Json_util.assoc_member_opt "nodes")
  with
  | Some (`List nodes) ->
    let rec newest_single_parent = function
      | [] -> Some None
      | commit :: older ->
        (match decode_authored_commit commit with
         | None -> None
         | Some (1, author) -> Some author
         | Some (_, _) -> newest_single_parent older)
    in
    newest_single_parent (List.rev nodes)
  | _ -> None

(* The columns below do not decide whether a row stands: a title, a head
   object id or a review list this reader cannot read is [None] or
   [Reviews_not_read] on that row, and the row stays. *)
let decode_string_member name node =
  match Json_util.assoc_member_opt name node with
  | Some (`String value) -> Some value
  | _ -> None

let decode_title node = decode_string_member "title" node
let decode_head_oid node = decode_string_member "headRefOid" node

(* A review state is shown as GitHub sent it when this build does not know it;
   nothing branches on that text. *)
let verdict_of_wire = function
  | "APPROVED" -> Verdict_approved
  | "CHANGES_REQUESTED" -> Verdict_changes_requested
  | "COMMENTED" -> Verdict_commented
  | "DISMISSED" -> Verdict_dismissed
  | "PENDING" -> Verdict_pending
  | other -> Verdict_unrecognized other

(* [__typename] of a GitHub actor. [null] is a deleted account; a key the
   query asked for but the answer lacks is an actor of unknown type. *)
let decode_actor node =
  match Json_util.assoc_member_opt "author" node with
  | Some `Null -> Actor_absent
  | Some (`Assoc _ as actor) ->
    let typename = decode_string_member "__typename" actor in
    let login = decode_string_member "login" actor in
    (match typename, login with
     | Some "User", Some login -> Actor_user login
     | Some "Bot", Some login -> Actor_bot login
     | Some _, _ | None, _ -> Actor_other { typename; login })
  | Some _ | None -> Actor_other { typename = None; login = None }

let decode_latest_review node =
  match decode_string_member "state" node with
  | None -> None
  | Some state ->
    let commit_oid =
      Option.bind (Json_util.assoc_member_opt "commit" node) (decode_string_member "oid")
    in
    Some { reviewer = decode_actor node; verdict = verdict_of_wire state; commit_oid }

(* One review that cannot be read makes the whole list unread: a list with a
   hole in it would answer "no review on the head" for a review it skipped. *)
let decode_latest_reviews node =
  match Json_util.assoc_member_opt "latestReviews" node with
  | Some (`Assoc _ as connection) ->
    let truncated =
      match
        Option.bind
          (Json_util.assoc_member_opt "pageInfo" connection)
          (Json_util.assoc_member_opt "hasNextPage")
      with
      | Some (`Bool truncated) -> Some truncated
      | _ -> None
    in
    (match truncated, Json_util.assoc_member_opt "nodes" connection with
     | Some truncated, Some (`List nodes) ->
       let rec read acc = function
         | [] -> Some (List.rev acc)
         | review :: rest ->
           (match decode_latest_review review with
            | Some review -> read (review :: acc) rest
            | None -> None)
       in
       (match read [] nodes with
        | Some reviews -> Reviews_read { reviews; truncated }
        | None -> Reviews_not_read)
     | _ -> Reviews_not_read)
  | _ -> Reviews_not_read

let decode_pull ~repo_slug node =
  match
    Json_util.assoc_member_opt "number" node, Json_util.assoc_member_opt "isDraft" node
  with
  | Some (`Int number), Some (`Bool draft) ->
    (match decode_checks node, decode_review node, decode_mergeable node, decode_author node with
     | Some checks, Some review, Some mergeable, Some author ->
       Some
         { repo_slug
         ; number
         ; draft
         ; checks
         ; review
         ; mergeable
         ; author
         ; title = decode_title node
         ; head_oid = decode_head_oid node
         ; reviews = decode_latest_reviews node
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
  match
    Json_util.assoc_member_opt "type" error, Json_util.assoc_member_opt "path" error
  with
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
              match Json_util.assoc_member_opt "message" error with
              | Some (`String message) -> message
              | _ -> Yojson.Safe.to_string error)
            errors
      }

let decode_page ~repo_slug (response : response) =
  match Yojson.Safe.from_string response.body with
  | exception Yojson.Json_error message -> Error (Response_unreadable message)
  | json ->
    (match Json_util.assoc_member_opt "errors" json with
     | Some (`List (_ :: _ as errors)) -> Error (failure_of_graphql_errors ~response errors)
     | _ ->
       let connection =
         Option.bind
           (Option.bind
              (Json_util.assoc_member_opt "data" json)
              (Json_util.assoc_member_opt "repository"))
           (Json_util.assoc_member_opt "pullRequests")
       in
       (match connection with
        | None -> Error (Response_unreadable "data.repository.pullRequests is absent")
        | Some connection ->
          (match
             Json_util.assoc_member_opt "nodes" connection,
             Json_util.assoc_member_opt "pageInfo" connection
           with
           | Some (`List nodes), Some page_info ->
             let pulls = List.filter_map (decode_pull ~repo_slug) nodes in
             let undecodable = List.length nodes - List.length pulls in
             (match
                Json_util.assoc_member_opt "hasNextPage" page_info,
                Json_util.assoc_member_opt "endCursor" page_info
              with
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

let read_repository ~now ~http_post ~token ?(graphql_url = default_graphql_url) repo_slug =
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

let repositories_table = Runtime_toml_namespace.(key Repositories)
let pr_reader_key = "pr_reader"
let github_host_key = "github_host"
let graphql_url_key = "graphql_url"
let known_keys = [ pr_reader_key; github_host_key; graphql_url_key ]

type endpoint =
  { github_host : string
  ; graphql_url : string
  }

type credential =
  { keeper : string
  ; token : string
  ; endpoint : endpoint
  }

(* A bare hostname: no scheme, port, path or userinfo can hide in it, so it is
   safe to compare against remote hosts and to hand to the token lane as the
   hosts.yml section. It is kept in lower case: DNS names are case-insensitive
   (RFC 4343), and gh lowercases the hostname before it writes hosts.yml
   (cli/cli pkg/cmd/auth/login/login.go). *)
let valid_hostname_char = function
  | 'a'..'z' | 'A'..'Z' | '0'..'9' | '.' | '-' -> true
  | _ -> false

let github_host_of_string raw =
  let host = String.trim raw in
  let length = String.length host in
  let rec chars_ok i =
    if i >= length then true else valid_hostname_char host.[i] && chars_ok (i + 1)
  in
  if length > 0 && chars_ok 0
  then Ok (String.lowercase_ascii host)
  else
    Error
      (Printf.sprintf
         "[%s] %s must be a bare hostname, got %S"
         repositories_table
         github_host_key
         raw)

(* https only: the reader token travels in the Authorization header, and a
   plaintext endpoint would publish it to the network. *)
let graphql_url_of_string raw =
  let url = String.trim raw in
  if String.starts_with ~prefix:"https://" url && String.length url > String.length "https://"
  then Ok url
  else
    Error
      (Printf.sprintf
         "[%s] %s must be an https:// URL, got %S"
         repositories_table
         graphql_url_key
         raw)

let endpoint_of_entries entries =
  let open Result.Syntax in
  let* github_host =
    match List.assoc_opt github_host_key entries with
    | None -> Ok default_github_host
    | Some (Otoml.TomlString raw) -> github_host_of_string raw
    | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _) | Some (Otoml.TomlBoolean _)
    | Some (Otoml.TomlOffsetDateTime _) | Some (Otoml.TomlLocalDateTime _)
    | Some (Otoml.TomlLocalDate _) | Some (Otoml.TomlLocalTime _) | Some (Otoml.TomlArray _)
    | Some (Otoml.TomlTable _) | Some (Otoml.TomlInlineTable _) | Some (Otoml.TomlTableArray _) ->
      Error
        (Printf.sprintf "[%s] %s must be a hostname string" repositories_table github_host_key)
  in
  let* graphql_url =
    match List.assoc_opt graphql_url_key entries with
    | None -> Ok default_graphql_url
    | Some (Otoml.TomlString raw) -> graphql_url_of_string raw
    | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _) | Some (Otoml.TomlBoolean _)
    | Some (Otoml.TomlOffsetDateTime _) | Some (Otoml.TomlLocalDateTime _)
    | Some (Otoml.TomlLocalDate _) | Some (Otoml.TomlLocalTime _) | Some (Otoml.TomlArray _)
    | Some (Otoml.TomlTable _) | Some (Otoml.TomlInlineTable _) | Some (Otoml.TomlTableArray _) ->
      Error
        (Printf.sprintf "[%s] %s must be a URL string" repositories_table graphql_url_key)
  in
  (* A non-default host without its endpoint has no valid reading: its slugs
     posted to api.github.com would all answer NOT_FOUND, one confusing row
     per repository. Refuse the declaration with the fix instead. An explicit
     default host, and a lone endpoint (a proxy in front of github.com), both
     still resolve. *)
  let url_set = Option.is_some (List.assoc_opt graphql_url_key entries) in
  if (not url_set) && not (String.equal github_host default_github_host)
  then
    Error
      (Printf.sprintf
         "[%s] %s %S needs an explicit %s: its slugs posted to %s would read as not visible"
         repositories_table
         github_host_key
         github_host
         graphql_url_key
         default_graphql_url)
  else Ok { github_host; graphql_url }

let reader_of_declaration ~(config : Workspace.config) ~endpoint keeper =
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
           ~hostname:endpoint.github_host
       with
       | Error refusal ->
         Error
           (Reader_token_unavailable
              { keeper; reason = Keeper_github_login_lane.stored_token_error_to_string refusal })
       | Ok token -> Ok { keeper; token; endpoint }))

let declaration_invalid fmt = Printf.ksprintf (fun m -> Error (Reader_declaration_invalid m)) fmt

let reader_of_table ~config entries =
  match List.find_opt (fun (key, _) -> not (List.exists (String.equal key) known_keys)) entries with
  | Some (key, _) -> declaration_invalid "[%s] has unknown key %S" repositories_table key
  | None ->
    (match List.assoc_opt pr_reader_key entries with
     | None -> Error Reader_not_declared
     | Some (Otoml.TomlString keeper) ->
       (* The endpoint keys are inert without a reader: a lone [github_host]
          still reads as not declared, and a reader with a bad endpoint is
          invalid rather than silently defaulted. *)
       (match endpoint_of_entries entries with
        | Error reason -> Error (Reader_declaration_invalid reason)
        | Ok endpoint -> reader_of_declaration ~config ~endpoint keeper)
     | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _) | Some (Otoml.TomlBoolean _)
     | Some (Otoml.TomlOffsetDateTime _) | Some (Otoml.TomlLocalDateTime _)
     | Some (Otoml.TomlLocalDate _) | Some (Otoml.TomlLocalTime _) | Some (Otoml.TomlArray _)
     | Some (Otoml.TomlTable _) | Some (Otoml.TomlInlineTable _) | Some (Otoml.TomlTableArray _) ->
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
          | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
          | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
          | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _)
          | Some (Otoml.TomlLocalTime _) | Some (Otoml.TomlArray _) | Some (Otoml.TomlTableArray _) -> declaration_invalid "[%s] must be a table" repositories_table)))

(* A digest, so the snapshot can tell a new token from the refused one without
   holding either. *)
let token_digest token = Digest.BLAKE256.(to_hex (string token))

(* A refusal is the endpoint's answer about the token, so both name it: the
   same token posted to another [graphql_url] has not been refused yet. *)
let presented_token ~token ~graphql_url : rejected_token =
  { token_digest = token_digest token; graphql_url }

let rejected_token_equal (a : rejected_token) (b : rejected_token) =
  String.equal a.token_digest b.token_digest && String.equal a.graphql_url b.graphql_url

(* GitHub's own answer about a credential or a quota, held until the fact it
   names can have changed: a refused token until hosts.yml holds another one
   or [graphql_url] names another endpoint, an exhausted limit until GitHub's
   reset time. Asking again sooner cannot get a different answer. *)
let held_answer ~now_s ~presented ~previously_rejected = function
  | Pulls_failed { failure = Token_rejected; _ } as held
    when Option.equal rejected_token_equal previously_rejected (Some presented) -> Some held
  | Pulls_failed { failure = Rate_limited { reset_at = Some reset_at }; _ } as held
    when now_s < reset_at -> Some held
  | Pulls_not_read
  | Pulls_not_github
  | Pulls_read _
  | Pulls_failed
      { failure =
          ( Repository_not_visible
          | Token_rejected
          | Rate_limited _
          | Forbidden _
          | Http_status _
          | Graphql_errors _
          | Transport_failed _
          | Response_unreadable _ )
      ; _
      } -> None

let is_token_rejected = function
  | Pulls_failed { failure = Token_rejected; _ } -> true
  | Pulls_not_read
  | Pulls_not_github
  | Pulls_read _
  | Pulls_failed
      { failure =
          ( Repository_not_visible
          | Rate_limited _
          | Forbidden _
          | Http_status _
          | Graphql_errors _
          | Transport_failed _
          | Response_unreadable _ )
      ; _
      } -> false

(* Listing the Keepers creates their directory when it is missing, and a
   failed mkdir raises. The raise is this list's failure, not the refresh's:
   the GitHub reads beside it still publish. *)
let list_keepers config =
  match Keeper_meta_store.keeper_names_result config with
  | Ok names -> Keepers_listed names
  | Error reason -> Keepers_list_failed reason
  | exception (Eio.Cancel.Cancelled _ as e) -> raise e
  | exception exn -> Keepers_list_failed ("keeper list read raised " ^ Printexc.to_string exn)

let refresh ~now ~http_post ~(config : Workspace.config) ~previous =
  let base_path = config.base_path in
  let now_s = now () in
  let keepers = list_keepers config in
  let credential = resolve_reader ~config in
  let reader =
    match credential with
    | Ok { keeper; token = _; endpoint = _ } -> Reader_ready { keeper }
    | Error reader -> reader
  in
  match Repo_store.load_all ~base_path with
  | Error reason ->
    { reader
    ; repositories_error = Some ("repository list unread: " ^ reason)
    ; repositories = previous.repositories
    ; keepers
    ; rejected_token = previous.rejected_token
    }
  | Ok repos ->
    let previous_pulls id =
      match
        List.find_opt (fun entry -> String.equal entry.repository_id id) previous.repositories
      with
      | Some entry -> entry.pulls
      | None -> Pulls_not_read
    in
    (* Without an accepted endpoint there is no configured host: remotes then
       parse against the default host, exactly as before, while [pulls]
       still says why nothing is read. *)
    let host =
      match credential with
      | Ok { endpoint; _ } -> endpoint.github_host
      | Error _ -> default_github_host
    in
    let entry (repo : Repo_manager_types.repository) =
      let slug = github_slug_of_remote ~host repo.url in
      let pulls =
        match slug, credential with
        | None, _ -> Pulls_not_github
        | Some slug, Ok { token; keeper = _; endpoint } ->
          (match
             held_answer
               ~now_s
               ~presented:(presented_token ~token ~graphql_url:endpoint.graphql_url)
               ~previously_rejected:previous.rejected_token
               (previous_pulls repo.id)
           with
           | Some held -> held
           | None -> read_repository ~now ~http_post ~token ~graphql_url:endpoint.graphql_url slug)
        (* An earlier read would show checks and reviews the server can no
           longer vouch for; [reader] says why nothing is read now. *)
        | Some _, Error _ -> Pulls_not_read
      in
      { repository_id = repo.id; url = repo.url; slug; pulls }
    in
    let repositories = List.map entry repos in
    let rejected_token =
      match credential with
      | Ok { token; keeper = _; endpoint }
        when List.exists (fun entry -> is_token_rejected entry.pulls) repositories ->
        Some (presented_token ~token ~graphql_url:endpoint.graphql_url)
      | Ok _ | Error _ -> None
    in
    { reader
    ; repositories_error = None
    ; repositories
    ; keepers
    ; rejected_token
    }

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
             ~previous:(Repository_pulls.current ())
         in
         Repository_pulls.publish next
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Server.warn "repository_pulls: refresh raised %s; keeping the previous rows"
           (Printexc.to_string exn);
         Repository_pulls.publish (refresh_raised ~previous:(Repository_pulls.current ()) exn));
      Eio.Time.sleep clock poll_interval_s;
      loop ()
    in
    loop ())

(* --- Lane Add-on GitHub reads --- *)

let lane_addon_github ~now ~http_post ~(config : Workspace.config) : Lane_addon_records.github =
  fun ~repository_id ->
  match resolve_reader ~config with
  | Error reader -> Error ("the PR reader is not ready: " ^ Yojson.Safe.to_string (reader_to_yojson reader))
  | Ok { token; endpoint; keeper = _ } ->
    (match Repo_store.find ~base_path:config.base_path repository_id with
     | Error detail -> Error detail
     | Ok repo ->
       (match github_slug_of_remote ~host:endpoint.github_host repo.Repo_manager_types.url with
        | None -> Error (Printf.sprintf "repository %s has no remote on %s" repository_id endpoint.github_host)
        | Some slug ->
          let owner, name =
            match String.index_opt slug '/' with
            | Some i -> String.sub slug 0 i, String.sub slug (i + 1) (String.length slug - i - 1)
            | None -> slug, ""
          in
          let failed failure = Error (Yojson.Safe.to_string (failure_to_yojson failure)) in
          let post body =
            match http_post ~url:endpoint.graphql_url ~token ~body with
            | Error message -> failed (Transport_failed message)
            | Ok response ->
              (match failure_of_status ~now_s:(now ()) response with
               | Some failure -> failed failure
               | None ->
                 (match Yojson.Safe.from_string response.body with
                  | exception Yojson.Json_error message -> failed (Response_unreadable message)
                  | json ->
                    (match Json_util.assoc_member_opt "errors" json with
                     | Some (`List (_ :: _ as errors)) -> failed (failure_of_graphql_errors ~response errors)
                     | Some _ | None -> Ok json)))
          in
          Ok { Lane_addon_records.owner; name; post }))

(* --- REST reads --- *)

let rest_api_url = "https://api.github.com"

type rest_failure =
  | Reader_not_ready of reader
  | Reader_host_not_github of string
  | Rest_transport_failed of string

let rest_get ~http_get ~(config : Workspace.config) ~path =
  match resolve_reader ~config with
  | Error reader -> Error (Reader_not_ready reader)
  | Ok { token; endpoint; keeper = _ } ->
    if not (String.equal endpoint.github_host default_github_host)
    then Error (Reader_host_not_github endpoint.github_host)
    else (
      match http_get ~url:(rest_api_url ^ path) ~token with
      | Ok response -> Ok response
      | Error message -> Error (Rest_transport_failed message))
