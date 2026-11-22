(* The page [GET /api/v1/board] answers, one projection for both transports:
   the HTTP/1 route and the HTTP/2 gateway both read it from here. *)

open Server_utils

(* Both caps share a 2,000-post bounded read budget; exceeding either is
   explicitly declared via [signal_scan_truncated] or [succession_chain_scope]. *)
let signal_scan_cap = 2000
let chain_scan_cap = 2000

type succession_chain_scope =
  | Chain_scope_full
  | Chain_scope_bounded

let succession_chain_scope_to_string = function
  | Chain_scope_full -> "full"
  | Chain_scope_bounded -> "bounded"
;;

let succession_chain_scope_of_string = function
  | "full" -> Some Chain_scope_full
  | "bounded" -> Some Chain_scope_bounded
  | _ -> None
;;

let key_part = function
  | Some value -> Printf.sprintf "%d:%s" (String.length value) value
  | None -> "-"
;;

(* A blank filter is no filter. [?hearth=] used to filter to posts whose
   hearth is the empty string, an empty page, and cached it under the same key
   as the unfiltered page. *)
let filter_param request name =
  query_param request name
  |> Option.map String.trim
  |> Fun.flip Option.bind (fun s -> if s = "" then None else Some s)
;;

let is_verification_meta (meta : Yojson.Safe.t option) : bool =
  match meta with
  | Some (`Assoc fields) ->
    (match List.assoc_opt "kind" fields with
     | Some (`String k) ->
       let lk = String.lowercase_ascii (String.trim k) in
       lk = "verification" || lk = "verify" || lk = "system"
     | Some _ | None ->
       (match List.assoc_opt "source" fields with
        | Some (`String s) ->
          let ls = String.lowercase_ascii (String.trim s) in
          ls = "verification" || ls = "verify" || ls = "system"
        | Some _ | None ->
          Option.is_some (List.assoc_opt "verification_id" fields)))
  | Some _ | None -> false
;;

let is_verify_noise_title (title : string) : bool =
  let lower = String.lowercase_ascii (String.trim title) in
  String.starts_with ~prefix:"verify:" lower
  || String.starts_with ~prefix:"[verify]" lower
  || String.starts_with ~prefix:"[system]" lower
;;

let is_signal_post (p : Board.post) : bool =
  match p.post_kind with
  | Board.System_post -> false
  | Board.Human_post | Board.Automation_post ->
    if is_verification_meta p.meta_json then false
    else if is_verify_noise_title p.title then false
    else true
;;

type signal_page =
  { paged : Board.post list
  ; filtered_out_count : int
  ; has_more : bool
  ; signal_scan_truncated : bool
  }

let scan_signal_page
      ?(scan_cap = signal_scan_cap)
      ~exclude_automation
      ~offset
      ~limit
      fetch
  : signal_page
  =
  let offset = max 0 offset in
  let limit = max 1 limit in
  let needed = offset + limit + 1 in
  let effective_cap = max (max 1 scan_cap) needed in
  let keep_post (p : Board.post) =
    is_signal_post p
    && (not exclude_automation || Board.classify_post_kind p <> Board.Automation_post)
  in
  let rec loop scan_limit =
    let raw = fetch scan_limit in
    let raw_len = List.length raw in
    let kept = List.filter keep_post raw in
    let kept_len = List.length kept in
    let exhausted = raw_len < scan_limit in
    if kept_len >= needed || exhausted || scan_limit >= effective_cap
    then (
      let signal_scan_truncated =
        (not exhausted) && kept_len < needed && scan_limit >= effective_cap
      in
      { paged = kept |> drop offset |> take limit
      ; filtered_out_count = max 0 (raw_len - kept_len)
      ; has_more = kept_len > offset + limit
      ; signal_scan_truncated
      })
    else (
      let next_limit =
        if scan_limit > effective_cap / 2 then effective_cap else scan_limit * 2
      in
      loop next_limit)
  in
  (* Jump straight to [effective_cap] when [needed > effective_cap / 2] to skip
     a redundant half-cap doubling pass on deep offsets. *)
  let initial_limit =
    let doubled = if needed > effective_cap / 2 then effective_cap else needed * 2 in
    min effective_cap (max 1 doubled)
  in
  loop initial_limit
;;

let compute_succession_chains (posts : Board.post list)
  : (string, string * int) Hashtbl.t
  =
  let successor_of : (string, string) Hashtbl.t = Hashtbl.create 16 in
  let predecessor_of : (string, string) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun (p : Board.post) ->
       match p.closed with
       | Some { successor_id = Some succ; _ } ->
         let pid = Board.Post_id.to_string p.id in
         let sid = Board.Post_id.to_string succ in
         if pid <> sid then (
           Hashtbl.replace successor_of pid sid;
           if not (Hashtbl.mem predecessor_of sid) then
             Hashtbl.replace predecessor_of sid pid)
       | Some { successor_id = None; _ } | None -> ())
    posts;
  let result : (string, string * int) Hashtbl.t = Hashtbl.create 16 in
  let max_hops = max 16 (List.length posts + 2) in
  let resolve_chain start_id =
    let visited = Hashtbl.create 8 in
    let rec walk cur depth =
      if depth >= max_hops then (cur, depth)
      else (
        Hashtbl.replace visited cur ();
        match Hashtbl.find_opt predecessor_of cur with
        | None -> (cur, depth)
        | Some pred ->
          if Hashtbl.mem visited pred then (cur, depth)
          else walk pred (depth + 1))
    in
    walk start_id 0
  in
  let record_if_in_chain id =
    if not (Hashtbl.mem result id)
       && (Hashtbl.mem predecessor_of id || Hashtbl.mem successor_of id)
    then Hashtbl.replace result id (resolve_chain id)
  in
  Hashtbl.iter (fun pid sid -> record_if_in_chain pid; record_if_in_chain sid) successor_of;
  result
;;

let attach_chain_fields ~(chains : (string, string * int) Hashtbl.t) ~post_id json =
  let root_opt, depth =
    match Hashtbl.find_opt chains post_id with
    | Some (root_id, d) -> (Some root_id, d)
    | None -> (None, 0)
  in
  match json with
  | `Assoc fields ->
    `Assoc
      (fields
       @ [ ("succession_chain_root_id", Json_util.string_opt_to_json root_opt)
         ; ("chain_depth", `Int depth)
         ])
  | other -> other
;;

let succession_chains_cache_key ~reader ~base_path =
  Printf.sprintf "board:chains:%s:%s"
    (Masc_board_handlers.Board_access.cache_key reader)
    (key_part base_path)
;;

let encode_cached_chains
      (scope : succession_chain_scope)
      (chains : (string, string * int) Hashtbl.t)
  : Yojson.Safe.t
  =
  let entries =
    Hashtbl.fold
      (fun post_id (root_id, depth) acc ->
         (post_id, `List [ `String root_id; `Int depth ]) :: acc)
      chains
      []
  in
  `Assoc
    [ ("scope", `String (succession_chain_scope_to_string scope))
    ; ("chains", `Assoc entries)
    ]
;;

let decode_cached_chains (json : Yojson.Safe.t)
  : succession_chain_scope * (string, string * int) Hashtbl.t
  =
  if Dashboard_cache.is_timeout_envelope json then
    Chain_scope_bounded, Hashtbl.create 0
  else
    match json with
    | `Assoc fields ->
      let scope =
        match List.assoc_opt "scope" fields with
        | Some (`String s) ->
          (match succession_chain_scope_of_string s with
           | Some sc -> sc
           | None -> Chain_scope_bounded)
        | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _)
        | None -> Chain_scope_bounded
      in
      let table =
        match List.assoc_opt "chains" fields with
        | Some (`Assoc entries) ->
          let tbl = Hashtbl.create (max 16 (List.length entries)) in
          List.iter
            (fun (post_id, v) ->
               match v with
               | `List [ `String root_id; `Int depth ] ->
                 Hashtbl.replace tbl post_id (root_id, depth)
               | `List _ | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _
               | `Float _ | `String _ -> ())
            entries;
          tbl
        | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _)
        | None -> Hashtbl.create 0
      in
      scope, table
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Chain_scope_bounded, Hashtbl.create 0
;;

let cached_succession_chains
      ?(scan_cap = chain_scan_cap)
      ?fetch
      ~reader
      ~base_path
      ()
  : succession_chain_scope * (string, string * int) Hashtbl.t
  =
  let cap = max 1 scan_cap in
  let fetch_posts =
    match fetch with
    | Some f -> f
    | None ->
      fun limit ->
        Board_dispatch.list_posts ~reader ~sort_by:Board_dispatch.Recent
          ~exclude_system:false ~exclude_automation:false
          ~limit ()
  in
  let key = succession_chains_cache_key ~reader ~base_path in
  let cached_json =
    Dashboard_cache.get_or_compute key
      ~ttl:Server_dashboard_http_core_cache.realtime_cache_ttl_s
      (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
         let chain_posts = fetch_posts (cap + 1) in
         let scope, source =
           if List.length chain_posts > cap
           then Chain_scope_bounded, take cap chain_posts
           else Chain_scope_full, chain_posts
         in
         let chains = compute_succession_chains source in
         encode_cached_chains scope chains))
  in
  decode_cached_chains cached_json
;;

(* It is kept in the dashboard cache together with its serialized body and
   entity tag, so a read of an unchanged page sends the kept bytes rather than
   serializing and hashing every post again. The key holds the query and the
   reaction actor, each value prefixed with its length, so two different pages
   never share a key. The succession-chain graph lives in its own shared
   [board:chains:] entry keyed only by reader and base path so page/filter
   variants reuse one bounded scan. Every board write raises a board event, and
   the SSE hook drops every [board:list:] and [board:chains:] entry
   ([Server_dashboard_http_core_cache.invalidate_board_projections]) before it
   broadcasts that event. *)
let payload ?config ~reader ~reaction_actor request
  : Dashboard_cache.cached_payload
  =
  let hearth = filter_param request "hearth" in
  let sort_by = board_sort_order_of_request request in
  let exclude_system = bool_query_param request "exclude_system" ~default:false in
  let exclude_automation =
    bool_query_param request "exclude_automation" ~default:false
  in
  let signal_only = bool_query_param request "signal_only" ~default:false in
  let author_filter = filter_param request "author" in
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let base_fetch =
    board_fetch_limit ~exclude_system ~exclude_automation ~limit ~offset
  in
  let voter = match reaction_actor with
    | Some _ -> reaction_actor
    | None -> board_voter_query request
  in
  let base_path =
    match config with
    | Some config -> Some config.Workspace.base_path
    | None -> None
  in
  let signal_suffix = if signal_only then ":signal" else "" in
  let cache_key =
    Printf.sprintf "board:list:%s:%s:%s:%s:%b:%b:%s:%d:%d:%s:%s%s"
      (Masc_board_handlers.Board_access.cache_key reader)
      (key_part base_path)
      (key_part hearth)
      (board_sort_label sort_by)
      exclude_system exclude_automation
      (key_part author_filter)
      limit offset (key_part voter) (key_part reaction_actor)
      signal_suffix
  in
  Dashboard_cache.get_or_compute_payload cache_key
    ~ttl:Server_dashboard_http_core_cache.realtime_cache_ttl_s
    (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
       let page =
         if signal_only
         then
           (* Fetch with exclude_system=false & exclude_automation=false so
              [Board_dispatch.list_posts] never truncates a [Hot] slice before
              post-kind filtering; [scan_signal_page] applies both filters and
              tracks exact [filtered_out_count] and store exhaustion. *)
           scan_signal_page
             ~scan_cap:(max signal_scan_cap (offset + limit + 1))
             ~exclude_automation
             ~offset
             ~limit
             (fun scan_limit ->
               Board_dispatch.list_posts ~reader ?hearth ~sort_by
                 ~exclude_system:false ~exclude_automation:false
                 ?author_filter ~limit:scan_limit ())
         else (
           let probe_fetch = base_fetch + 1 in
           let raw =
             Board_dispatch.list_posts ~reader ?hearth ~sort_by
               ~exclude_system ~exclude_automation
               ?author_filter ~limit:probe_fetch ()
           in
           { paged = raw |> drop offset |> take limit
           ; filtered_out_count = 0
           ; has_more = List.length raw > offset + limit
           ; signal_scan_truncated = false
           })
       in
       (* Resolve succession chains from the shared reader/workspace cache
          (up to [chain_scan_cap] posts) so page/filter variants reuse one
          bounded scan and roots outside [offset]/[limit] keep their true
          [(root_id, depth)]. *)
       let chain_scope, chains =
         cached_succession_chains ~reader ~base_path ()
       in
       let karma_map = Board_dispatch.get_all_karma ~reader () in
       let get_karma author =
         match List.assoc_opt author karma_map with
         | Some karma -> karma
         | None -> 0
       in
       let paged = page.paged in
       let reaction_rows =
         board_reactions_batch ~reader
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
              let current_vote = board_current_vote_for_post ~reader ~voter ~post_id in
              let reactions = reactions_for (Board.Reaction_post, post_id) in
              board_post_dashboard_json
                ?reactions
                ?current_vote
                ~author_karma:(get_karma author) p
              |> attach_chain_fields ~chains ~post_id)
           paged
       in
       `Assoc
         [ ("posts", `List posts_json)
         ; ("count", `Int (List.length posts_json))
         ; ("limit", `Int limit)
         ; ("offset", `Int offset)
         ; ("sort_by", `String (board_sort_label sort_by))
         ; ("signal_only", `Bool signal_only)
         ; ("filtered_out_count", `Int page.filtered_out_count)
         ; ("has_more", `Bool page.has_more)
         ; ("signal_scan_truncated", `Bool page.signal_scan_truncated)
         ; ("succession_chain_scope", `String (succession_chain_scope_to_string chain_scope))
         ]))
;;
