open Result.Syntax

type kind = Posts | Comments | Votes | Reactions | Policy

type purpose = Delete | Flush
type selection = { purpose : purpose; kinds : kind list }

type payload =
  | Posts_payload of Board_core_persist.posts_snapshot
  | Comments_payload of Board_core_persist.comments_snapshot
  | Votes_payload of string
  | Reactions_payload of string
  | Policy_payload of string

type t = { selection : selection; contents : payload list }

let kind_of_payload = function
  | Posts_payload _ -> Posts | Comments_payload _ -> Comments
  | Votes_payload _ -> Votes | Reactions_payload _ -> Reactions
  | Policy_payload _ -> Policy

type write_outcome =
  | Attempted of (unit, Board_types.board_error) result
  | Pending

type outcome = {
  writes : (kind * write_outcome) list;
  settlement : Board_posts_source.reserved_settlement option;
}

type retry = Retry_posts | Retry_comments

let all_kinds = [ Posts; Comments; Votes; Reactions ]
let for_delete = { purpose = Delete; kinds = all_kinds }
let for_sub_board_delete = { purpose = Delete; kinds = [ Posts; Policy ] }
let includes selection kind = List.mem kind selection.kinds

let for_flush ~dirty_posts ~dirty_comments ~votes_readable ~reactions_readable =
  let had_dirty = dirty_posts || dirty_comments in
  let kinds = List.filter
    (function
      | Posts -> dirty_posts
      | Comments -> dirty_comments
      | Votes -> had_dirty && votes_readable
      | Reactions -> had_dirty && reactions_readable
      | Policy -> false)
    all_kinds in
  { purpose = Flush; kinds }

let capture selection ~posts ~comments ~votes ~reactions ~policy =
  let rec gather reversed = function
    | [] -> Ok { selection; contents = List.rev reversed }
    | kind :: remaining ->
      let* content = match kind with
        | Posts -> Ok (Posts_payload (posts ()))
        | Comments -> Ok (Comments_payload (comments ()))
        | Votes -> Ok (Votes_payload (votes ()))
        | Reactions -> Ok (Reactions_payload (reactions ()))
        | Policy -> Result.map (fun bytes -> Policy_payload bytes) (policy ()) in
      gather (content :: reversed) remaining in
  gather [] selection.kinds

let persist batch ~write =
  let rec loop reversed = function
    | [] -> { writes = List.rev reversed; settlement = None }
    | content :: remaining ->
      let attempted = try Ok (write content) with
        | Board_posts_source.Reserved_settlement deferred -> Error deferred in
      let kind = kind_of_payload content in
      match attempted with
      | Ok result ->
        (match batch.selection.purpose, result with
         | Delete, Error _ ->
           let pending = List.map (fun content -> kind_of_payload content, Pending) remaining in
           { writes = List.rev_append reversed ((kind, Attempted result) :: pending);
             settlement = None }
         | Delete, Ok () | Flush, (Ok () | Error _) ->
           loop ((kind, Attempted result) :: reversed) remaining)
      | Error deferred ->
        let pending = List.map (fun content -> kind_of_payload content, Pending) remaining in
        { writes = List.rev_append reversed ((kind, Attempted deferred.result) :: pending);
          settlement = Some deferred }
  in
  loop [] batch.contents

let finish_settlement outcome = match outcome.settlement with
  | None -> ()
  | Some deferred -> raise (Board_posts_source.Reserved_settlement deferred)

let retry_for_kind = function
  | Posts | Votes | Reactions | Policy -> Retry_posts
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
