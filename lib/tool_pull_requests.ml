module R = Repository_pulls
module P = Repository_pulls_placement

type selection =
  | Needs_only
  | Every_placement
  | Only of P.placement

type request =
  { repository : string option
  ; selection : selection
  ; mine : bool
  ; limit : int
  }

let default_limit = 20
let max_limit = 100
let title_max_bytes = 120
let needs_name = "needs"
let every_name = "all"

let selections =
  (needs_name, Needs_only)
  :: (every_name, Every_placement)
  :: List.map (fun placement -> P.to_string placement, Only placement) P.all
;;

let selection_names = List.map fst selections

let selection_of_args args : (selection, Tool_args.field_error) result =
  let received = Tool_args.get_string args "placement" needs_name in
  match List.assoc_opt received selections with
  | Some selection -> Ok selection
  | None ->
    Error
      { Tool_args.field = "placement"
      ; constraint_violated = Tool_args.One_of selection_names
      ; message =
          Printf.sprintf "placement must be one of: %s" (String.concat ", " selection_names)
      ; expected = Some (String.concat "|" selection_names)
      ; received = Some received
      }
;;

let request_of_args args =
  match
    ( selection_of_args args
    , Tool_args.validate_int_range args "limit" ~min_v:1 ~max_v:max_limit ~default:default_limit )
  with
  | Ok selection, Ok limit ->
    Ok
      { repository = Tool_args.get_string_opt args "repository"
      ; selection
      ; mine = Tool_args.get_bool args "mine" false
      ; limit
      }
  | Error error, Ok _ | Ok _, Error error -> Error [ error ]
  | Error first, Error second -> Error [ first; second ]
;;

type refusal =
  | Unknown_repository of
      { requested : string
      ; registered : string list
      }
  | Nothing_read of Yojson.Safe.t
  | Keepers_unread

(* One pull request with what the answer derives from it once. *)
type row =
  { pull : R.pull_request
  ; placement : P.placement
  ; head_review : R.head_review
  ; keeper : string option
  }

type context =
  { now : float
  ; caller : string
  ; request : request
  ; keepers : R.keeper_names
  }

let string_or_null = function
  | Some value -> `String value
  | None -> `Null
;;

let title_preview title =
  let title = String.trim title in
  if String.length title <= title_max_bytes
  then title
  else String_util.utf8_prefix ~max_bytes:title_max_bytes title ^ "..."
;;

let display_name (entry : R.repository_entry) =
  match entry.slug with
  | Some slug -> slug
  | None -> entry.repository_id
;;

let keeper_of keepers pull =
  match keepers with
  | R.Keepers_listed names -> R.keeper_of_author ~keepers:names pull
  | R.Keepers_not_listed | R.Keepers_list_failed _ -> None
;;

let row_of ~keepers (pull : R.pull_request) =
  { pull
  ; placement = P.placement_of pull
  ; head_review = R.head_review_of pull
  ; keeper = keeper_of keepers pull
  }
;;

let is_callers ~caller row = Option.equal String.equal row.keeper (Some caller)

let head_review_rank = function
  | R.Not_reviewed_on_head -> 0
  | R.Review_history_incomplete -> 1
  | R.Reviewed_on_head -> 2
  | R.Head_review_unknown -> 3
;;

let sort_key ~caller row =
  ( P.rank row.placement
  , (if is_callers ~caller row then 0 else 1)
  , head_review_rank row.head_review
  , row.pull.R.number )
;;

let selected context row =
  let by_selection =
    match context.request.selection with
    | Needs_only ->
      (match row.placement with
       | P.Needs _ -> true
       | P.Not_listed _ -> false)
    | Every_placement -> true
    | Only placement -> P.equal placement row.placement
  in
  by_selection && ((not context.request.mine) || is_callers ~caller:context.caller row)
;;

let review_json ~head_oid (review : R.latest_review) =
  let base =
    [ "reviewer", R.actor_to_yojson review.reviewer
    ; "verdict", `String (R.verdict_to_string review.verdict)
    ; ( "on_head"
      , match head_oid with
        | Some head -> `Bool (R.review_on_head ~head review)
        | None -> `Null )
    ]
  in
  match review.verdict with
  | R.Verdict_unrecognized raw -> `Assoc (base @ [ "verdict_raw", `String raw ])
  | R.Verdict_approved
  | R.Verdict_changes_requested
  | R.Verdict_commented
  | R.Verdict_dismissed
  | R.Verdict_pending -> `Assoc base
;;

let reviews_json (pull : R.pull_request) =
  match pull.reviews with
  | R.Reviews_not_read -> `Assoc [ "state", `String "not_read" ]
  | R.Reviews_read { reviews; truncated } ->
    `Assoc
      [ "state", `String "read"
      ; "truncated", `Bool truncated
      ; "latest", `List (List.map (review_json ~head_oid:pull.head_oid) reviews)
      ]
;;

let row_json row =
  let pull = row.pull in
  `Assoc
    [ "number", `Int pull.R.number
    ; "placement", `String (P.to_string row.placement)
    ; "title", string_or_null (Option.map title_preview pull.R.title)
    ; "draft", `Bool pull.R.draft
    ; "checks", `String (R.check_state_to_string pull.R.checks)
    ; "review", `String (R.review_state_to_string pull.R.review)
    ; "mergeable", `String (R.mergeable_to_string pull.R.mergeable)
    ; "head_review", `String (R.head_review_to_string row.head_review)
    ; "head_oid", string_or_null pull.R.head_oid
    ; "author", string_or_null pull.R.author
    ; "keeper", string_or_null row.keeper
    ; "reviews", reviews_json pull
    ]
;;

let counts_json rows =
  `Assoc
    (List.map
       (fun placement ->
          ( P.to_string placement
          , `Int (List.length (List.filter (fun row -> P.equal row.placement placement) rows)) ))
       P.all)
;;

let mergeable_unknown_count pulls =
  List.length
    (List.filter
       (fun (pull : R.pull_request) ->
          match pull.mergeable with
          | R.Mergeable_unknown -> true
          | R.Mergeable | R.Conflicting -> false)
       pulls)
;;

let age_sec ~now observed_at = Float.to_int (Float.max 0. (now -. observed_at))

let entry_json context (entry : R.repository_entry) =
  let repository = "repository", `String (display_name entry) in
  match entry.pulls with
  | R.Pulls_not_read -> `Assoc [ repository; "state", `String "not_read" ]
  | R.Pulls_not_github ->
    `Assoc [ repository; "state", `String "not_github"; "url", `String entry.url ]
  | R.Pulls_failed { observed_at; failure } ->
    `Assoc
      [ repository
      ; "state", `String "failed"
      ; "observed_at", `Float observed_at
      ; "age_sec", `Int (age_sec ~now:context.now observed_at)
      ; "failure", R.failure_to_yojson failure
      ]
  | R.Pulls_read { observed_at; pulls; undecodable } ->
    let rows = List.map (row_of ~keepers:context.keepers) pulls in
    let matched =
      List.sort
        (fun first second ->
           compare
             (sort_key ~caller:context.caller first)
             (sort_key ~caller:context.caller second))
        (List.filter (selected context) rows)
    in
    let shown = List.take context.request.limit matched in
    `Assoc
      [ repository
      ; "state", `String "read"
      ; "observed_at", `Float observed_at
      ; "age_sec", `Int (age_sec ~now:context.now observed_at)
      ; "open", `Int (List.length pulls)
      ; "undecodable", `Int undecodable
      ; "mergeable_unknown", `Int (mergeable_unknown_count pulls)
      ; "counts", counts_json rows
      ; "matched", `Int (List.length matched)
      ; "shown", `Int (List.length shown)
      ; "pulls", `List (List.map row_json shown)
      ]
;;

let is_read (entry : R.repository_entry) =
  match entry.pulls with
  | R.Pulls_read _ -> true
  | R.Pulls_not_read | R.Pulls_failed _ | R.Pulls_not_github -> false
;;

let reader_is_ready = function
  | R.Reader_ready _ -> true
  | R.Reader_not_declared
  | R.Reader_declaration_invalid _
  | R.Reader_keeper_missing _
  | R.Reader_token_unavailable _ -> false
;;

let keepers_are_listed = function
  | R.Keepers_listed _ -> true
  | R.Keepers_not_listed | R.Keepers_list_failed _ -> false
;;

let entries_asked_for request (snapshot : R.snapshot) =
  match request.repository with
  | None -> Ok snapshot.repositories
  | Some requested ->
    (match
       List.filter
         (fun entry -> String.equal (display_name entry) requested)
         snapshot.repositories
     with
     | [] ->
       Error
         (Unknown_repository
            { requested; registered = List.map display_name snapshot.repositories })
     | found -> Ok found)
;;

let answer ~now ~caller request (snapshot : R.snapshot) =
  if request.mine && not (keepers_are_listed snapshot.keepers)
  then Error Keepers_unread
  else
    Result.bind (entries_asked_for request snapshot) (fun entries ->
      let context = { now; caller; request; keepers = snapshot.keepers } in
      let body =
        `Assoc
          [ "reader", R.reader_to_yojson snapshot.reader
          ; "repositories_error", string_or_null snapshot.repositories_error
          ; "keepers_listed", `Bool (keepers_are_listed snapshot.keepers)
          ; "repositories", `List (List.map (entry_json context) entries)
          ]
      in
      (* An empty list answers only when the reader is ready and the list was
         read: then nothing is registered. Any other empty or unread answer
         would read as "no open pull requests". *)
      let nothing_to_read =
        match entries with
        | [] -> reader_is_ready snapshot.reader && Option.is_none snapshot.repositories_error
        | _ :: _ -> false
      in
      if List.exists is_read entries || nothing_to_read
      then Ok body
      else Error (Nothing_read body))
;;

let refusal_result ~tool_name ~start_time = function
  | Unknown_repository { requested; registered } ->
    let known =
      match registered with
      | [] -> "no repository is registered"
      | names -> "registered: " ^ String.concat ", " names
    in
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Policy_rejection
      ~start_time
      ~data:
        (`Assoc
            [ "requested", `String requested
            ; "registered", `List (List.map (fun name -> `String name) registered)
            ])
      (Printf.sprintf "repository %s is not one the server reads; %s" requested known)
  | Nothing_read data ->
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Dependency_unavailable
      ~start_time
      ~data
      "the server holds no reading of the repositories asked for; data carries the reader and each repository state"
  | Keepers_unread ->
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Dependency_unavailable
      ~start_time
      "the server has not read the Keeper list, so no pull request can be attributed to a Keeper"
;;

let handle ~tool_name ~start_time ~caller args =
  match request_of_args args with
  | Error errors -> Tool_args.validation_error_result ~tool_name ~start_time errors
  | Ok request ->
    (match answer ~now:(Time_compat.now ()) ~caller request (R.current ()) with
     | Ok data -> Tool_result.make_ok ~tool_name ~start_time ~data ()
     | Error refusal -> refusal_result ~tool_name ~start_time refusal)
;;
