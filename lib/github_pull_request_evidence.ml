module Store = Workspace_verification_store

let github_api_prefix = "https://api.github.com/repos/"
let fetch_timeout_sec = 15

let api_url (locator : Store.pull_request_locator) =
  Printf.sprintf
    "%s%s/%s/pulls/%d"
    github_api_prefix
    locator.owner
    locator.repo
    locator.number

let string_member json key =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String value) -> Some value
     | Some _ | None -> None)
  | _ -> None

let bool_member json key =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Bool value) -> Some value
     | Some _ | None -> None)
  | _ -> None

let get ~accept url =
  Tool_local_runtime_http.http_get_text_with_status_with_headers
    ~timeout_sec:fetch_timeout_sec
    ~headers:
      [ "Accept", accept
      ; "X-GitHub-Api-Version", "2022-11-28"
      ; "User-Agent", "masc-verification-evidence"
      ]
    ~follow_redirects:true
    url

let fetch_metadata locator =
  match get ~accept:"application/vnd.github+json" (api_url locator) with
  | Error detail -> Error (Store.Pull_request_transport detail)
  | Ok (Some 200, body) ->
    (match Yojson.Safe.from_string body with
     | exception Yojson.Json_error detail ->
       Error (Store.Pull_request_payload_invalid detail)
     | json ->
       let head_sha =
         match json with
         | `Assoc fields ->
           (match List.assoc_opt "head" fields with
            | Some head -> string_member head "sha"
            | None -> None)
         | _ -> None
       in
       (match
          ( string_member json "state"
          , bool_member json "merged"
          , bool_member json "draft"
          , head_sha
          , string_member json "title" )
        with
        | Some state, Some merged, Some draft, Some head_sha, Some title ->
          Ok (state, merged, draft, head_sha, title)
        | _ ->
          Error
            (Store.Pull_request_payload_invalid
               "pull-request object is missing state/merged/draft/head.sha/title")))
  | Ok (Some status, _) -> Error (Store.Pull_request_http_status status)
  | Ok (None, _) ->
    Error (Store.Pull_request_transport "no HTTP status from GitHub")

let fetch_diff locator =
  (* One byte of headroom over the cap distinguishes "exactly cap" from
     "curl stopped at the cap": a body longer than the cap is truncated
     to it and flagged. *)
  let cap = Store.verification_evidence_max_bytes in
  match
    Tool_local_runtime_http.http_get_text_with_status_with_headers
      ~timeout_sec:fetch_timeout_sec
      ~headers:
        [ "Accept", "application/vnd.github.v3.diff"
        ; "X-GitHub-Api-Version", "2022-11-28"
        ; "User-Agent", "masc-verification-evidence"
        ]
      ~follow_redirects:true
      ~max_response_bytes:(cap + 1)
      (api_url locator)
  with
  | Error detail -> Error (Store.Pull_request_transport detail)
  | Ok (Some 200, body) ->
    let bytes = String.length body in
    if bytes > cap
    then Ok (String.sub body 0 cap, bytes, true)
    else Ok (body, bytes, false)
  | Ok (Some status, _) -> Error (Store.Pull_request_http_status status)
  | Ok (None, _) ->
    Error (Store.Pull_request_transport "no HTTP status from GitHub")

let inspect locator =
  match fetch_metadata locator with
  | Error _ as error -> error
  | Ok (state, merged, draft, head_sha, title) ->
    (match fetch_diff locator with
     | Error _ as error -> error
     | Ok (diff, diff_bytes, diff_truncated) ->
       Ok
         { Store.url = Store.pull_request_locator_url locator
         ; state
         ; merged
         ; draft
         ; head_sha
         ; title
         ; diff
         ; diff_bytes
         ; diff_truncated
         })

let install () = Store.install_pull_request_inspector inspect
