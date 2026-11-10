type kind = Posts | Comments | Votes | Reactions

type selection = kind list

type payload =
  | Posts_payload of Board_core_persist.posts_snapshot
  | Comments_payload of Board_core_persist.comments_snapshot
  | Votes_payload of string
  | Reactions_payload of string

type t = payload list

let kind_of_payload = function
  | Posts_payload _ -> Posts | Comments_payload _ -> Comments
  | Votes_payload _ -> Votes | Reactions_payload _ -> Reactions

type write_outcome =
  | Attempted of (unit, Board_types.board_error) result
  | Pending

type outcome = {
  writes : (kind * write_outcome) list;
  settlement : Board_posts_source.reserved_settlement option;
}

type retry = Retry_posts | Retry_comments

let for_delete = [ Posts; Comments; Votes; Reactions ]

let for_flush ~dirty_posts ~dirty_comments ~votes_readable ~reactions_readable =
  let had_dirty = dirty_posts || dirty_comments in
  List.filter
    (function
      | Posts -> dirty_posts
      | Comments -> dirty_comments
      | Votes -> had_dirty && votes_readable
      | Reactions -> had_dirty && reactions_readable)
    for_delete

let capture selection ~posts ~comments ~votes ~reactions =
  List.fold_left
    (fun reversed kind ->
       let content = match kind with
         | Posts -> Posts_payload (posts ())
         | Comments -> Comments_payload (comments ())
         | Votes -> Votes_payload (votes ())
         | Reactions -> Reactions_payload (reactions ()) in
       content :: reversed)
    []
    selection
  |> List.rev

let persist batch ~write =
  let rec loop reversed = function
    | [] -> { writes = List.rev reversed; settlement = None }
    | content :: remaining ->
      let attempted = try Ok (write content) with
        | Board_posts_source.Reserved_settlement deferred -> Error deferred in
      let kind = kind_of_payload content in
      match attempted with
      | Ok result -> loop ((kind, Attempted result) :: reversed) remaining
      | Error deferred ->
        let pending = List.map (fun content -> kind_of_payload content, Pending) remaining in
        { writes = List.rev_append reversed ((kind, Attempted deferred.result) :: pending);
          settlement = Some deferred }
  in
  loop [] batch

let finish_settlement outcome = match outcome.settlement with
  | None -> ()
  | Some deferred -> raise (Board_posts_source.Reserved_settlement deferred)

let retry_for_kind = function
  | Posts | Votes | Reactions -> Retry_posts
  | Comments -> Retry_comments

let retries outcome =
  let posts, comments =
    List.fold_left
      (fun (posts, comments) (kind, result) ->
         match result with
         | Attempted (Ok ()) -> posts, comments
         | Attempted (Error _) | Pending ->
           (match retry_for_kind kind with
            | Retry_posts -> true, comments
            | Retry_comments -> posts, true))
      (false, false)
      outcome.writes
  in
  match posts, comments with
  | true, true -> [ Retry_posts; Retry_comments ]
  | true, false -> [ Retry_posts ]
  | false, true -> [ Retry_comments ]
  | false, false -> []

let errors outcome =
  List.filter_map
    (function
      | _, Attempted (Ok ()) | _, Pending -> None
      | _, Attempted (Error error) -> Some error)
    outcome.writes
