(** Board_dispatch - Runtime backend selection for MASC Board

    Routes Board operations to either JSONL (Board.store) or PostgreSQL (Board_pg.t).
    Backend is selected once at server startup and fixed for the session.

    PG is the primary backend when MASC_POSTGRES_URL is available.
    JSONL serves as fallback when PG is unavailable or explicitly selected.

    Control: MASC_BOARD_BACKEND env var ("pg" default, "jsonl" to force file-based).

    @since 0.6.0
*)

(** Sort order for post listing (PG uses SQL ORDER BY, JSONL sorts in-memory) *)
type sort_order = Hot | Trending | Recent | Updated | Discussed

(** Backend variant *)
type board_backend =
  | Jsonl of Board.store
  | Postgres of Board_pg.t

type backend_state =
  | Uninitialized
  | Active of board_backend

(** Current backend state. Single ref avoids contradictory initialized/backend pairs. *)
let backend_state : backend_state ref = ref Uninitialized

let is_initialized () =
  match !backend_state with
  | Active _ -> true
  | Uninitialized -> false

(** Initialize PostgreSQL backend. Call during server startup when PG pool is available. *)
let init_pg pool =
  if is_initialized () then begin
    Log.BoardLog.warn "already initialized, ignoring init_pg";
    Ok ()
  end else
  match Board_pg.create pool with
  | Ok t ->
      backend_state := Active (Postgres t);
      Log.BoardLog.info "PostgreSQL backend initialized";
      Ok ()
  | Error e ->
      Log.BoardLog.warn "PG init failed, falling back to JSONL: %s"
        (Board.show_board_error e);
      Error e

(** Initialize JSONL backend. Default fallback. *)
let init_jsonl () =
  if is_initialized () then
    Log.BoardLog.warn "already initialized, ignoring init_jsonl"
  else begin
    backend_state := Active (Jsonl (Board.global ()));
    Log.BoardLog.info "JSONL backend initialized"
  end

(** Reset for testing. Clears backend state so init can be called again. *)
let reset_for_test () =
  backend_state := Uninitialized

(** Check MASC_BOARD_BACKEND env var. Returns true if JSONL is explicitly forced. *)
let jsonl_forced () =
  match Sys.getenv_opt "MASC_BOARD_BACKEND" with
  | Some s -> String.lowercase_ascii (String.trim s) = "jsonl"
  | None -> false

(** Get backend or fail.
    Normal path: Board is initialized by room_utils_backend_setup during server startup.
    Auto-init: JSONL fallback when startup init was skipped (tests, standalone tools). *)
let backend () =
  match !backend_state with
  | Active backend -> backend
  | Uninitialized ->
      Log.BoardLog.warn "backend() called before server init, auto-initializing JSONL";
      init_jsonl ();
      (match !backend_state with
       | Active backend -> backend
       | Uninitialized -> failwith "[Board_dispatch] auto-init failed to activate backend")

(** Get PostgreSQL pool if PG backend is active (for Board_listener) *)
let get_pg_pool () =
  match !backend_state with
  | Active (Postgres t) -> Some (Board_pg.get_pool t)
  | _ -> None

(** {1 In-memory sort for JSONL mode} *)

let sort_posts_in_memory ~sort_by (posts : Board.post list) =
  match sort_by with
  | Hot -> posts  (* Board.list_posts already sorts by score *)
  | Recent ->
      List.sort (fun (a : Board.post) (b : Board.post) ->
        compare b.created_at a.created_at) posts
  | Updated ->
      List.sort (fun (a : Board.post) (b : Board.post) ->
        compare b.updated_at a.updated_at) posts
  | Trending ->
      let now = Time_compat.now () in
      List.sort (fun (a : Board.post) (b : Board.post) ->
        let age_a = max 1.0 ((now -. a.created_at) /. 3600.0) in
        let age_b = max 1.0 ((now -. b.created_at) /. 3600.0) in
        let score_a = float_of_int (a.votes_up - a.votes_down + a.reply_count * 2)
                      /. (age_a ** 0.5) in
        let score_b = float_of_int (b.votes_up - b.votes_down + b.reply_count * 2)
                      /. (age_b ** 0.5) in
        compare score_b score_a) posts
  | Discussed ->
      List.sort (fun (a : Board.post) (b : Board.post) ->
        let cmp = compare b.reply_count a.reply_count in
        if cmp <> 0 then cmp else compare b.created_at a.created_at) posts

(** {1 Dispatch Functions} *)

let create_post ~author ~content ?title ?body ?post_kind ?meta_json
    ?(visibility=Board.Internal)
    ?(ttl_hours=Board.Limits.default_ttl_hours) ?hearth ?thread_id () =
  match backend () with
  | Jsonl store ->
      Board.create_post store ~author ~content ?title ?body ?post_kind ?meta_json
        ~visibility ~ttl_hours ?hearth ?thread_id ()
  | Postgres t ->
      Board_pg.create_post t ~author ~content ?title ?body ?post_kind ?meta_json
        ~visibility ~ttl_hours ?hearth ?thread_id ()

let get_post ~post_id =
  match backend () with
  | Jsonl store -> Board.get_post store ~post_id
  | Postgres t -> Board_pg.get_post t ~post_id

let list_posts ?(visibility_filter=None) ?hearth ?post_kind_filter ?(sort_by=Hot)
    ?(exclude_automation=false) ?(limit=50) () =
  let apply_post_kind_filter posts =
    match (post_kind_filter, exclude_automation) with
    | Some kind, _ ->
        List.filter
          (fun (p : Board.post) -> Board.classify_post_kind p = kind)
          posts
    | None, true ->
        List.filter (fun (p : Board.post) ->
          Board.classify_post_kind p <> Board.Automation_post) posts
    | None, false -> posts
  in
  match backend () with
  | Jsonl store ->
      let fetch_limit = max limit 200 in
      let posts = Board.list_posts store ~visibility_filter ?hearth ~limit:fetch_limit () in
      let sorted = sort_posts_in_memory ~sort_by posts in
      let filtered = apply_post_kind_filter sorted in
      Board.take limit filtered
  | Postgres t ->
      let pg_sort = match sort_by with
        | Hot -> Board_pg.Hot
        | Trending -> Board_pg.Trending
        | Recent -> Board_pg.Recent
        | Updated -> Board_pg.Updated
        | Discussed -> Board_pg.Discussed
      in
      let needs_filter =
        Option.is_some post_kind_filter || exclude_automation
      in
      (* Over-fetch when post-query filtering is needed to avoid short results *)
      let fetch_limit = if needs_filter then max limit (limit * 3) else limit in
      let posts = Board_pg.list_posts t ~visibility_filter ?hearth ~sort_by:pg_sort ~limit:fetch_limit () in
      let filtered = apply_post_kind_filter posts in
      Board.take limit filtered

let get_comments ~post_id =
  match backend () with
  | Jsonl store -> Board.get_comments store ~post_id
  | Postgres t -> Board_pg.get_comments t ~post_id

let add_comment ~post_id ~author ~content ?parent_id
    ?(ttl_hours=Board.Limits.default_ttl_hours) () =
  match backend () with
  | Jsonl store ->
      Board.add_comment store ~post_id ~author ~content ?parent_id ~ttl_hours ()
  | Postgres t ->
      Board_pg.add_comment t ~post_id ~author ~content ?parent_id ~ttl_hours ()

let vote ~voter ~post_id ~direction =
  match backend () with
  | Jsonl store -> Board.vote store ~voter ~post_id ~direction
  | Postgres t -> Board_pg.vote_post t ~voter ~post_id ~direction

let vote_comment ~voter ~comment_id ~direction =
  match backend () with
  | Jsonl store -> Board.vote_comment store ~voter ~comment_id ~direction
  | Postgres t -> Board_pg.vote_comment t ~voter ~comment_id ~direction

let stats () =
  match backend () with
  | Jsonl store -> Board.stats store
  | Postgres t -> Board_pg.stats t

let list_comments ?(limit=1000) () =
  match backend () with
  | Jsonl store -> Board.list_comments store ~limit ()
  | Postgres t -> Board_pg.list_comments t ~limit ()

let list_hearths () =
  match backend () with
  | Jsonl store -> Board.list_hearths store
  | Postgres t -> Board_pg.list_hearths t

let set_thread_id ~post_id ~thread_id =
  match backend () with
  | Jsonl store -> Board.set_thread_id store ~post_id ~thread_id
  | Postgres t -> Board_pg.set_thread_id t ~post_id ~thread_id

let delete_post ~post_id =
  match backend () with
  | Jsonl store -> Board.delete_post store ~post_id
  | Postgres t -> Board_pg.delete_post t ~post_id

let delete_posts_by_predicate ~predicate ?(limit=5200) () =
  list_posts ~sort_by:Recent ~limit ()
  |> List.fold_left
       (fun acc (post : Board.post) ->
         if predicate post then
           match delete_post ~post_id:(Board.Post_id.to_string post.id) with
           | Ok () -> acc + 1
           | Error _ -> acc
         else
           acc)
       0

let search ~query ~limit =
  match backend () with
  | Jsonl store ->
      (* Full-scan search: match query against content, author, hearth.
         Uses Board.search_posts to scan all posts (not limited by list_posts cap). *)
      let query_lower = String.lowercase_ascii query in
      let pattern = Str.regexp_string query_lower in
      let matches_str s =
        try ignore (Str.search_forward pattern (String.lowercase_ascii s) 0); true
        with Not_found -> false
      in
      let predicate (p : Board.post) =
        matches_str p.title
        || matches_str p.content
        || matches_str (Board.Agent_id.to_string p.author)
        || (match p.hearth with Some h -> matches_str h | None -> false)
      in
      Board.search_posts store ~predicate ~limit
  | Postgres t ->
      Board_pg.search t ~query ~limit

(** Flush dirty state (JSONL only, PG commits immediately) *)
let flush () =
  match !backend_state with
  | Active (Jsonl store) -> Board.flush_dirty store
  | _ -> ()

(** Sweep expired posts and comments *)
let sweep () =
  match backend () with
  | Jsonl store -> Board.sweep store
  | Postgres t -> Board_pg.sweep t

(** {1 Karma Functions} *)

let get_all_karma () =
  match backend () with
  | Jsonl store -> Board.get_all_karma store
  | Postgres t -> Board_pg.get_all_karma t

let get_agent_karma ~agent_name =
  match backend () with
  | Jsonl store -> Board.get_agent_karma store ~agent_name
  | Postgres t -> Board_pg.get_agent_karma t ~agent_name

(** Post to JSON with karma (delegates to Board for flair extraction) *)
let post_to_yojson_with_karma (p : Board.post) ~author_karma =
  Board.post_to_yojson_with_karma p ~author_karma

(** Backend name for diagnostics *)
let backend_name () =
  match !backend_state with
  | Active (Jsonl _) -> "jsonl"
  | Active (Postgres _) -> "postgresql"
  | Uninitialized -> "uninitialized"
