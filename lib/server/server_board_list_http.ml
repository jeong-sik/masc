(* The page [GET /api/v1/board] answers, one projection for both transports:
   the HTTP/1 route and the HTTP/2 gateway both read it from here. *)

open Server_utils

(* It is kept in the dashboard cache under a key of every input that changes
   it, together with its serialized body and entity tag, so a read of an
   unchanged page sends the kept bytes rather than serializing and hashing
   every post again. A board write drops every [board:list:] entry
   ([Server_dashboard_http_core_cache.invalidate_board_projections]). *)
let payload ?config ~reaction_actor request
  : Dashboard_cache.cached_payload
  =
  let hearth = query_param request "hearth" in
  let sort_by = board_sort_order_of_request request in
  let exclude_system = bool_query_param request "exclude_system" ~default:false in
  let exclude_automation =
    bool_query_param request "exclude_automation" ~default:false
  in
  let author_query =
    query_param request "author"
    |> Option.map String.trim
    |> Fun.flip Option.bind (fun s -> if s = "" then None else Some s)
  in
  let author_filter = Option.map board_actor_author_for_write author_query in
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let base_fetch = board_fetch_limit ~exclude_system ~exclude_automation ~limit ~offset in
  let voter = board_voter_query request in
  let cache_part = function
    | Some value -> value
    | None -> ""
  in
  let base_path =
    match config with
    | Some config -> config.Workspace.base_path
    | None -> ""
  in
  let cache_key =
    Printf.sprintf "board:list:%s:%s:%s:%b:%b:%s:%d:%d:%s:%s"
      base_path
      (cache_part hearth)
      (board_sort_label sort_by)
      exclude_system exclude_automation
      (cache_part author_query)
      limit offset (cache_part voter) (cache_part reaction_actor)
  in
  Dashboard_cache.get_or_compute_payload cache_key
    ~ttl:Server_dashboard_http_core_cache.realtime_cache_ttl_s
    (fun () ->
       Domain_pool_ref.submit_io_or_inline (fun () ->
         let posts =
           Board_dispatch.list_posts ?hearth ~sort_by ~exclude_system
             ~exclude_automation ?author_filter ~limit:base_fetch ()
         in
         let karma_map = Board_dispatch.get_all_karma () in
         let get_karma author =
           match List.assoc_opt author karma_map with
           | Some karma -> karma
           | None -> 0
         in
         let paged = posts |> drop offset |> take limit in
         let reaction_rows =
           board_reactions_batch
             ~targets:
               (List.map
                  (fun (p : Board.post) ->
                     (Board.Reaction_post, Board.Post_id.to_string p.id))
                  paged)
             ~voter:reaction_actor
         in
         let reactions_for = board_reactions_lookup reaction_rows in
         let posts_json =
           List.map
             (fun (p : Board.post) ->
                let author = Board.Agent_id.to_string p.author in
                let post_id = Board.Post_id.to_string p.id in
                let current_vote = board_current_vote_for_post ~voter ~post_id in
                let reactions = reactions_for (Board.Reaction_post, post_id) in
                board_post_dashboard_json
                  ~reactions
                  ?current_vote
                  ~author_karma:(get_karma author) p)
             paged
         in
         `Assoc
           [ ("posts", `List posts_json)
           ; ("count", `Int (List.length posts_json))
           ; ("limit", `Int limit)
           ; ("offset", `Int offset)
           ; ("sort_by", `String (board_sort_label sort_by))
           ]))
;;
