type kind = Posts | Comments | Votes | Reactions

type selection = kind list

type payload =
  | Posts_payload of Board_core_persist.posts_snapshot
  | Comments_payload of string
  | Votes_payload of string
  | Reactions_payload of string

type t = payload list

let kind_of_payload = function
  | Posts_payload _ -> Posts | Comments_payload _ -> Comments
  | Votes_payload _ -> Votes | Reactions_payload _ -> Reactions

type outcome = {
  writes : (kind * (unit, Board_types.board_error) result) list;
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
  let reversed, settlement = List.fold_left
    (fun (reversed, settlement) content ->
       let result, settlement =
         try write content, settlement with
         | Board_posts_source.Reserved_settlement deferred ->
           (* This carrier follows a known primary success or nonwrite. The
              posts writer publishes success before finishing its diagnostic;
              nonwrites carry their typed error for normal retry marking. *)
           let settlement = match settlement with
             | Some _ -> settlement | None -> Some deferred in
           deferred.result, settlement in
       (kind_of_payload content, result) :: reversed, settlement)
    ([], None) batch in
  { writes = List.rev reversed; settlement }

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
         | Ok () -> posts, comments
         | Error _ ->
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
      | _, Ok () -> None
      | _, Error error -> Some error)
    outcome.writes
