module Store = Workspace_verification_store

type http_get =
  url:string
  -> headers:(string * string) list
  -> (int * string, string) result

let github_hostname = "github.com"
let api_host = "https://api.github.com"
let timeout_sec = 10

let default_http_get ~url ~headers =
  match
    Tool_local_runtime_http.http_get_text_with_status_with_headers
      ~timeout_sec
      ~headers
      url
  with
  | Error detail -> Error detail
  | Ok (Some status, body) -> Ok (status, body)
  (* curl exited 0 without a status line: there is no answer to read, and a
     missing status must not be folded into one of GitHub's. *)
  | Ok (None, _) -> Error "the GitHub request returned no HTTP status"
;;

let failed detail = Store.Change_lookup_failed detail

(* GitHub answers a pull request with [merged], [merge_commit_sha], [title] and
   [changed_files]. Each is read as the type the API documents; a field that is
   absent or of another type fails the whole lookup rather than being defaulted,
   because a snapshot that silently says "0 files, not merged" is worse than
   one that says it could not be read. *)
let snapshot_of_json json =
  let field name = Yojson.Safe.Util.member name json in
  let string_field name =
    match field name with
    | `String value -> Ok value
    | other ->
      Error
        (Printf.sprintf
           "pull request field %s must be a string, got %s"
           name
           (Yojson.Safe.to_string other))
  in
  match field "merged", field "changed_files" with
  | `Bool merged, `Int changed_files ->
    (match string_field "title" with
     | Error detail -> Error detail
     | Ok title ->
       let merge_commit =
         match field "merge_commit_sha" with
         | `String sha when not (String.equal (String.trim sha) "") -> Some sha
         | _ -> None
       in
       Ok (Store.Change_seen { merged; merge_commit; title; changed_files }))
  | `Bool _, other ->
    Error
      (Printf.sprintf
         "pull request field changed_files must be an integer, got %s"
         (Yojson.Safe.to_string other))
  | other, _ ->
    Error
      (Printf.sprintf
         "pull request field merged must be a boolean, got %s"
         (Yojson.Safe.to_string other))
;;

let lookup ~http_get ~token ~repository ~pull_request =
  match token with
  | Error detail ->
    failed (Printf.sprintf "no GitHub token for this producer: %s" detail)
  | Ok token ->
    let url = Printf.sprintf "%s/repos/%s/pulls/%d" api_host repository pull_request in
    let headers =
      [ "Accept", "application/vnd.github+json"
      ; "Authorization", "Bearer " ^ token
      ; "X-GitHub-Api-Version", "2022-11-28"
      ]
    in
    (match http_get ~url ~headers with
     | Error detail -> failed (Printf.sprintf "GitHub request failed: %s" detail)
     | Ok (200, body) ->
       (match Yojson.Safe.from_string body with
        | json ->
          (match snapshot_of_json json with
           | Ok seen -> seen
           | Error detail -> failed detail)
        | exception Yojson.Json_error detail ->
          failed (Printf.sprintf "GitHub answered unreadable JSON: %s" detail))
     | Ok (404, _) ->
       failed
         (Printf.sprintf
            "%s#%d is not visible to this producer's GitHub identity"
            repository
            pull_request)
     | Ok (status, _) -> failed (Printf.sprintf "GitHub answered HTTP %d" status))
;;

let reader ~(config : Workspace_utils_backend_setup.config) ~worker ~repository
      ~pull_request
  =
  let token =
    Keeper_github_identity.stored_token
      ~base_path:config.Workspace.base_path
      ~keeper_name:worker
      ~hostname:github_hostname
  in
  lookup ~http_get:default_http_get ~token ~repository ~pull_request
;;
