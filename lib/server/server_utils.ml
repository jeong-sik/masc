[@@@warning "-32-33-69"]

(** Parse query param from request target *)
let query_param request key =
  let uri = Uri.of_string request.Httpun.Request.target in
  Uri.get_query_param uri key

let int_query_param request key ~default =
  match query_param request key with
  | None -> default
  | Some s -> (try int_of_string s with Failure _ -> default)

let bool_query_param request key ~default =
  match query_param request key with
  | None -> default
  | Some s ->
      let v = String.lowercase_ascii (String.trim s) in
      if v = "1" || v = "true" || v = "yes" || v = "y" then true
      else if v = "0" || v = "false" || v = "no" || v = "n" then false
      else default

let clamp ~min_v ~max_v v = max min_v (min max_v v)

let take n lst =
  let rec loop acc remaining xs =
    if remaining <= 0 then List.rev acc
    else
      match xs with
      | [] -> List.rev acc
      | x :: rest -> loop (x :: acc) (remaining - 1) rest
  in
  loop [] n lst

let drop n lst =
  let rec loop remaining xs =
    if remaining <= 0 then xs
    else
      match xs with
      | [] -> []
      | _ :: rest -> loop (remaining - 1) rest
  in
  loop n lst

let iso8601_of_unix ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

let board_sort_order_of_request request =
  let to_sort = function
    | "trending" -> Board_dispatch.Trending
    | "recent" | "new" -> Board_dispatch.Recent
    | "updated" | "active" -> Board_dispatch.Updated
    | "discussed" | "comments" -> Board_dispatch.Discussed
    | _ -> Board_dispatch.Hot
  in
  match query_param request "sort_by" with
  | None -> Board_dispatch.Hot
  | Some sort -> to_sort (String.lowercase_ascii (String.trim sort))

let board_sort_label = function
  | Board_dispatch.Hot -> "hot"
  | Board_dispatch.Trending -> "trending"
  | Board_dispatch.Recent -> "recent"
  | Board_dispatch.Updated -> "updated"
  | Board_dispatch.Discussed -> "discussed"

let is_system_board_author author =
  author = "lodge-system" || author = "team-session"

let filter_board_posts ~exclude_system posts =
  if not exclude_system then posts
  else
    List.filter
      (fun (p : Board.post) ->
         Board.classify_post_kind p <> Board.System_post
         && not (is_system_board_author (Board.Agent_id.to_string p.author)))
      posts

let max_filtered_board_window = 5200

let board_fetch_limit ~exclude_system ~limit ~offset =
  let base = limit + offset in
  if exclude_system then max base max_filtered_board_window else base

let board_post_dashboard_json ~author_karma (p : Board.post) : Yojson.Safe.t =
  let base_fields =
    match Board_dispatch.post_to_yojson_with_karma p ~author_karma with
    | `Assoc fields -> fields
    | _ -> []
  in
  let fields =
    base_fields
    |> List.remove_assoc "title"
    |> List.remove_assoc "votes"
    |> List.remove_assoc "comment_count"
    |> List.remove_assoc "created_at_iso"
    |> List.remove_assoc "updated_at_iso"
    |> List.remove_assoc "hearth_count"
  in
  let score = p.votes_up - p.votes_down in
  `Assoc
    ( fields
      @ [
          ("title", `String p.title);
          ("body", `String p.body);
          ("votes", `Int score);
          ("comment_count", `Int p.reply_count);
          ("created_at_iso", `String (iso8601_of_unix p.created_at));
          ("updated_at_iso", `String (iso8601_of_unix p.updated_at));
          ("hearth_count", `Int (match p.hearth with Some _ -> 1 | None -> 0));
        ] )

let dashboard_compact_mode request =
  match query_param request "mode" with
  | Some s -> String.equal "compact" (String.lowercase_ascii (String.trim s))
  | None -> false

