
(** Parse query param from request target *)
let query_param request key =
  let uri = Uri.of_string request.Httpun.Request.target in
  Uri.get_query_param uri key

let int_query_param request key ~default =
  match query_param request key with
  | None -> default
  | Some s -> (Option.value ~default:default (int_of_string_opt s))

let bool_query_param request key ~default =
  match query_param request key with
  | None -> default
  | Some s ->
      let v = String.lowercase_ascii (String.trim s) in
      if v = "1" || v = "true" || v = "yes" || v = "y" then true
      else if v = "0" || v = "false" || v = "no" || v = "n" then false
      else default

let clamp ~min_v ~max_v v = max min_v (min max_v v)

let take = List.take
let drop = List.drop

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

let filter_board_posts ~exclude_system ~exclude_automation posts =
  posts
  |> List.filter
       (Board.post_matches_filters ~exclude_system ~exclude_automation)

let max_filtered_board_window = 5200

let board_fetch_limit ~exclude_system ~exclude_automation ~limit ~offset =
  let base = limit + offset in
  if exclude_system || exclude_automation then max base max_filtered_board_window
  else base

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

(** Extract a path parameter after a known prefix.
    Returns None if the path doesn't start with prefix or the parameter is empty.
    Prevents String.sub crash from bounds violations. *)
let extract_path_param ~prefix path =
  let plen = String.length prefix in
  let plen_total = String.length path in
  if plen_total > plen && String.sub path 0 plen = prefix then
    let param = String.trim (String.sub path plen (plen_total - plen)) in
    if String.length param > 0 then Some param else None
  else None

(** Standard query param: limit with default 50, clamped 1..200. *)
let standard_limit request =
  int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200

(** Standard query param: offset with default 0, min 0. *)
let standard_offset request =
  int_query_param request "offset" ~default:0 |> max 0
