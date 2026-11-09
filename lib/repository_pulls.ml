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

type actor =
  | Actor_user of string
  | Actor_bot of string
  | Actor_other of
      { typename : string option
      ; login : string option
      }
  | Actor_absent

type review_verdict =
  | Verdict_approved
  | Verdict_changes_requested
  | Verdict_commented
  | Verdict_dismissed
  | Verdict_pending
  | Verdict_unrecognized of string

type latest_review =
  { reviewer : actor
  ; verdict : review_verdict
  ; commit_oid : string option
  }

type latest_reviews =
  | Reviews_not_read
  | Reviews_read of
      { reviews : latest_review list
      ; truncated : bool
      }

type pull_request =
  { repo_slug : string
  ; number : int
  ; draft : bool
  ; checks : check_state
  ; review : review_state
  ; mergeable : mergeable
  ; author : string option
  ; title : string option
  ; head_oid : string option
  ; reviews : latest_reviews
  }

type head_review =
  | Reviewed_on_head
  | Not_reviewed_on_head
  | Review_history_incomplete
  | Head_review_unknown

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

type rejected_token =
  { token_digest : string
  ; graphql_url : string
  }

type snapshot =
  { reader : reader
  ; repositories_error : string option
  ; repositories : repository_entry list
  ; keepers : keeper_names
  ; rejected_token : rejected_token option
  }

let initial =
  { reader = Reader_not_declared
  ; repositories_error = None
  ; repositories = []
  ; keepers = Keepers_not_listed
  ; rejected_token = None
  }

(* Exact match: git records the author name as the runtime exported it, and
   a Keeper name that differs in case is another name. *)
let keeper_of_author ~keepers pull =
  match pull.author with
  | Some author when List.exists (String.equal author) keepers -> Some author
  | Some _ | None -> None

(* Only the review's commit and the head's object id are compared. *)
let head_review_of pull =
  match pull.head_oid, pull.reviews with
  | None, (Reviews_not_read | Reviews_read _) | Some _, Reviews_not_read -> Head_review_unknown
  | Some head, Reviews_read { reviews; truncated } ->
    if List.exists
         (fun (review : latest_review) -> Option.equal String.equal review.commit_oid (Some head))
         reviews
    then Reviewed_on_head
    else if truncated
    then Review_history_incomplete
    else Not_reviewed_on_head

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

let actor_to_yojson = function
  | Actor_user login -> `Assoc [ "kind", `String "user"; "login", `String login ]
  | Actor_bot login -> `Assoc [ "kind", `String "bot"; "login", `String login ]
  | Actor_other { typename; login } ->
    `Assoc
      [ "kind", `String "other"; "typename", string_or_null typename; "login", string_or_null login ]
  | Actor_absent -> `Assoc [ "kind", `String "absent" ]

let verdict_to_string = function
  | Verdict_approved -> "approved"
  | Verdict_changes_requested -> "changes_requested"
  | Verdict_commented -> "commented"
  | Verdict_dismissed -> "dismissed"
  | Verdict_pending -> "pending"
  | Verdict_unrecognized _ -> "unrecognized"

let head_review_to_string = function
  | Reviewed_on_head -> "reviewed_on_head"
  | Not_reviewed_on_head -> "not_reviewed_on_head"
  | Review_history_incomplete -> "review_history_incomplete"
  | Head_review_unknown -> "unknown"

let latest_review_to_yojson ~head_oid (review : latest_review) =
  `Assoc
    [ "reviewer", actor_to_yojson review.reviewer
    ; "verdict", `String (verdict_to_string review.verdict)
    ; ( "verdict_raw"
      , match review.verdict with
        | Verdict_unrecognized raw -> `String raw
        | Verdict_approved | Verdict_changes_requested | Verdict_commented | Verdict_dismissed
        | Verdict_pending -> `Null )
    ; "commit_oid", string_or_null review.commit_oid
    ; ( "on_head"
      , match head_oid with
        | Some head -> `Bool (Option.equal String.equal review.commit_oid (Some head))
        | None -> `Null )
    ]

let latest_reviews_to_yojson ~head_oid = function
  | Reviews_not_read -> `Assoc [ "state", `String "not_read" ]
  | Reviews_read { reviews; truncated } ->
    `Assoc
      [ "state", `String "read"
      ; "truncated", `Bool truncated
      ; "latest", `List (List.map (latest_review_to_yojson ~head_oid) reviews)
      ]

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
    ; "draft", `Bool pull.draft
    ; "checks", `String (check_state_to_string pull.checks)
    ; "review", `String (review_state_to_string pull.review)
    ; "mergeable", `String (mergeable_to_string pull.mergeable)
    ; "author", string_or_null pull.author
    ; "keeper", string_or_null keeper
    ; "title", string_or_null pull.title
    ; "head_oid", string_or_null pull.head_oid
    ; "head_review", `String (head_review_to_string (head_review_of pull))
    ; "reviews", latest_reviews_to_yojson ~head_oid:pull.head_oid pull.reviews
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
let publish snapshot = Atomic.set projection snapshot
let current () = Atomic.get projection
