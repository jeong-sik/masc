type kind = Posts | Comments | Votes | Reactions

type selection = kind list

type t = (kind * string) list

type 'error outcome = (kind * (unit, 'error) result) list

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

let capture selection ~read =
  List.fold_left
    (fun reversed kind ->
       let content = read kind in
       (kind, content) :: reversed)
    []
    selection
  |> List.rev

let persist batch ~write =
  List.fold_left
    (fun reversed (kind, content) ->
       let result = write kind content in
       (kind, result) :: reversed)
    []
    batch
  |> List.rev

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
      outcome
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
    outcome
