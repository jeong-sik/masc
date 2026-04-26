(** Parse query param from request target *)
let query_param request key =
  let uri = Uri.of_string request.Httpun.Request.target in
  Uri.get_query_param uri key
;;

let int_query_param request key ~default =
  match query_param request key with
  | None -> default
  | Some s -> Option.value ~default (int_of_string_opt s)
;;

let bool_query_param request key ~default =
  match query_param request key with
  | None -> default
  | Some s ->
    let v = String.lowercase_ascii (String.trim s) in
    if v = "1" || v = "true" || v = "yes" || v = "y"
    then true
    else if v = "0" || v = "false" || v = "no" || v = "n"
    then false
    else default
;;

let clamp ~min_v ~max_v v = max min_v (min max_v v)
let take = List.take
let drop = List.drop

let iso8601_of_unix ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf
    "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900)
    (tm.tm_mon + 1)
    tm.tm_mday
    tm.tm_hour
    tm.tm_min
    tm.tm_sec
;;

(** Issue #8449 PR C: HTTP query-param sort_by parser. Delegates to
    [Board_dispatch.sort_order_of_string_opt] (canonical + documented
    aliases new/active/comments) instead of duplicating the inline
    match. HTTP semantics keep the "default to Hot" fallback for
    missing or invalid query params — graceful UI degradation, not
    silent data corruption. *)
let board_sort_order_of_request request =
  match query_param request "sort_by" with
  | None -> Board_dispatch.Hot
  | Some sort ->
    (match Board_dispatch.sort_order_of_string_opt sort with
     | Some s -> s
     | None -> Board_dispatch.Hot)
;;

(** Issue #8449 PR C: thin alias over the Variant SSOT helper. *)
let board_sort_label = Board_dispatch.sort_order_to_string

let filter_board_posts ~exclude_system ~exclude_automation posts =
  posts |> List.filter (Board.post_matches_filters ~exclude_system ~exclude_automation)
;;

let board_actor_key ~kind id = kind ^ ":" ^ String.lowercase_ascii (String.trim id)

let board_actor_keeper_identity raw =
  let raw = String.trim raw in
  if raw = ""
  then None
  else (
    match Keeper_registry.find_by_agent_name raw with
    | Some entry ->
      Some (entry.name, Some entry.meta.agent_name, "keeper_registry_agent_name")
    | None ->
      (match Keeper_registry.find_by_name raw with
       | Some entry ->
         Some (entry.name, Some entry.meta.agent_name, "keeper_registry_name")
       | None ->
         (match Keeper_identity.canonical_keeper_name_from_agent_name raw with
          | Some name -> Some (name, Some raw, "keeper_alias_contract")
          | None -> None)))
;;

let board_actor_identity_json raw : Yojson.Safe.t =
  let raw = String.trim raw in
  match board_actor_keeper_identity raw with
  | Some (keeper_name, runtime_agent_name, source) ->
    let runtime_fields =
      match runtime_agent_name with
      | Some runtime
        when String.trim runtime <> "" && not (String.equal runtime keeper_name) ->
        [ "runtime_agent_name", `String runtime ]
      | _ -> []
    in
    `Assoc
      ([ "kind", `String "keeper"
       ; "id", `String keeper_name
       ; "key", `String (board_actor_key ~kind:"keeper" keeper_name)
       ; "display_name", `String keeper_name
       ; "raw", `String raw
       ; "source", `String source
       ]
       @ runtime_fields)
  | None ->
    `Assoc
      [ "kind", `String "agent"
      ; "id", `String raw
      ; "key", `String (board_actor_key ~kind:"agent" raw)
      ; "display_name", `String raw
      ; "raw", `String raw
      ; "source", `String "raw_agent"
      ]
;;

let board_actor_entity raw =
  match board_actor_keeper_identity raw with
  | Some (keeper_name, _, _) -> Activity_graph.entity ~kind:"keeper" keeper_name
  | None -> Activity_graph.entity ~kind:"agent" (String.trim raw)
;;

let board_actor_author_for_write raw =
  match board_actor_keeper_identity raw with
  | Some (keeper_name, _, _) -> keeper_name
  | None -> String.trim raw
;;

let max_filtered_board_window = 5200

let board_fetch_limit ~exclude_system ~exclude_automation ~limit ~offset =
  let base = limit + offset in
  if exclude_system || exclude_automation
  then max base max_filtered_board_window
  else base
;;

let board_comment_dashboard_json (c : Board.comment) : Yojson.Safe.t =
  let author = Board.Agent_id.to_string c.author in
  match Board.comment_to_yojson c with
  | `Assoc fields ->
    `Assoc (fields @ [ "author_identity", board_actor_identity_json author ])
  | other -> other
;;

let board_post_dashboard_json ~author_karma (p : Board.post) : Yojson.Safe.t =
  let author = Board.Agent_id.to_string p.author in
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
    (fields
     @ [ "title", `String p.title
       ; "body", `String p.body
       ; "votes", `Int score
       ; "comment_count", `Int p.reply_count
       ; "created_at_iso", `String (iso8601_of_unix p.created_at)
       ; "updated_at_iso", `String (iso8601_of_unix p.updated_at)
       ; ( "hearth_count"
         , `Int
             (match p.hearth with
              | Some _ -> 1
              | None -> 0) )
       ; "author_identity", board_actor_identity_json author
       ])
;;

let dashboard_compact_mode request =
  match query_param request "mode" with
  | Some s -> String.equal "compact" (String.lowercase_ascii (String.trim s))
  | None -> false
;;

(** Extract a path parameter after a known prefix.
    Returns None if the path doesn't start with prefix or the parameter is empty.
    Prevents String.sub crash from bounds violations. *)
let extract_path_param ~prefix path =
  let plen = String.length prefix in
  let plen_total = String.length path in
  if plen_total > plen && String.sub path 0 plen = prefix
  then (
    let param = String.trim (String.sub path plen (plen_total - plen)) in
    if String.length param > 0 then Some param else None)
  else None
;;

(** Standard query param: limit with default 50, clamped 1..200. *)
let standard_limit request =
  int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200
;;

(** Standard query param: offset with default 0, min 0. *)
let standard_offset request = int_query_param request "offset" ~default:0 |> max 0
