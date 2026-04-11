(** Board_dispatch - Runtime backend selection for MASC Board

    Routes Board operations to either JSONL (Board.store) or PostgreSQL (Board_pg.t).
    Backend is selected once at server startup and fixed for the session.

    JSONL is the default backend for local/runtime simplicity.
    PostgreSQL is opt-in when explicitly requested.

    Control: MASC_BOARD_BACKEND env var ("jsonl" default, "pg" to force database mode).

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

type keeper_board_signal_kind =
  | Board_post_created
  | Board_comment_added

type keeper_board_signal = {
  kind : keeper_board_signal_kind;
  post_id : string;
  author : string;
  title : string;
  content : string;
  hearth : string option;
}

type board_sse_event =
  | Post_created of { post_id : string; author : string; title : string; hearth : string option }
  | Comment_added of { post_id : string; comment_id : string; author : string }
  | Post_voted of { post_id : string; voter : string; direction : Board.vote_direction }
  | Comment_voted of { comment_id : string; voter : string; direction : Board.vote_direction }

(** Current backend state. Single ref avoids contradictory initialized/backend pairs. *)
let backend_state : backend_state ref = ref Uninitialized

let board_mu = Eio.Mutex.create ()
let with_board_rw f = Eio_guard.with_mutex board_mu f
let with_board_ro f = Eio_guard.with_mutex_ro board_mu f

(* Hooks are WORM Atomic: set once at server bootstrap, read from any fiber.
   No mutex needed — Atomic.get/set are single-instruction operations. *)
let keeper_board_signal_hook : (keeper_board_signal -> unit) option Atomic.t = Atomic.make None

let set_keeper_board_signal_hook hook =
  Atomic.set keeper_board_signal_hook (Some hook)

let emit_keeper_board_signal signal =
  match Atomic.get keeper_board_signal_hook with
  | Some hook -> hook signal
  | None -> ()

let board_sse_hook : (board_sse_event -> unit) option Atomic.t = Atomic.make None

let set_board_sse_hook hook =
  Atomic.set board_sse_hook (Some hook)

let emit_board_sse_event event =
  match Atomic.get board_sse_hook with
  | Some hook -> Safe_ops.protect ~default:() (fun () -> hook event)
  | None -> ()

let is_initialized () =
  with_board_ro (fun () ->
    match !backend_state with
    | Active _ -> true
    | Uninitialized -> false)

(** Initialize PostgreSQL backend. Call during server startup when PG pool is available. *)
let init_pg pool =
  with_board_rw (fun () ->
    if match !backend_state with Active _ -> true | Uninitialized -> false then begin
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
        Error e)

(** Initialize JSONL backend. Default fallback. *)
let init_jsonl () =
  with_board_rw (fun () ->
    if match !backend_state with Active _ -> true | Uninitialized -> false then
      Log.BoardLog.warn "already initialized, ignoring init_jsonl"
    else begin
      backend_state := Active (Jsonl (Board.global ()));
      Log.BoardLog.info "JSONL backend initialized"
    end)

(** Reset for testing. Clears backend state so init can be called again. *)
let reset_for_test () =
  with_board_rw (fun () -> backend_state := Uninitialized)

(** Check MASC_BOARD_BACKEND env var. Returns true if JSONL is explicitly forced. *)
let jsonl_forced () =
  match Env_config.Board.backend_opt () with
  | Some s -> String.lowercase_ascii s = "jsonl"
  | None -> false

let pg_forced () =
  match Env_config.Board.backend_opt () with
  | Some s -> String.lowercase_ascii s = "pg"
  | None -> false

(** Get backend or fail.
    Normal path: Board is initialized by room_utils_backend_setup during server startup.
    Auto-init: JSONL fallback when startup init was skipped (tests, standalone tools). *)
let backend () =
  with_board_rw (fun () ->
    match !backend_state with
    | Active backend -> backend
    | Uninitialized ->
        Log.BoardLog.warn "backend() called before server init, auto-initializing JSONL";
        backend_state := Active (Jsonl (Board.global ()));
        Log.BoardLog.info "JSONL backend initialized";
        (match !backend_state with
         | Active backend -> backend
         | Uninitialized -> raise (Failure "[Board_dispatch] auto-init failed to activate backend")))

(** Get PostgreSQL pool if PG backend is active *)
let get_pg_pool () =
  with_board_ro (fun () ->
    match !backend_state with
    | Active (Postgres t) -> Some (Board_pg.get_pool t)
    | _ -> None)

(** {1 In-memory sort for JSONL mode} *)

let sort_posts_in_memory ~sort_by (posts : Board.post list) =
  match sort_by with
  | Hot ->
      List.sort (fun (a : Board.post) (b : Board.post) ->
        let score_a = a.votes_up - a.votes_down in
        let score_b = b.votes_up - b.votes_down in
        let cmp = compare score_b score_a in
        if cmp <> 0 then cmp
        else compare b.created_at a.created_at) posts
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

let normalize_author_filter = function
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some (String.lowercase_ascii trimmed)
  | None -> None

let agent_matches_author_filter ~needle (agent_id : Board.Agent_id.t) =
  let author = Board.Agent_id.to_string agent_id |> String.lowercase_ascii in
  String_util.contains_substring author needle

let matching_post_ids_for_comment_author_filter ~needle (comments : Board.comment list) =
  let matches = Hashtbl.create 64 in
  List.iter
    (fun (comment : Board.comment) ->
      if agent_matches_author_filter ~needle comment.author then
        Hashtbl.replace matches (Board.Post_id.to_string comment.post_id) true)
    comments;
  matches

(** {1 Dispatch Functions} *)

let create_post ~author ~content ?title ?body ~post_kind ?meta_json
    ?(visibility=Board.Internal)
    ?(ttl_hours=Board.Limits.default_ttl_hours) ?hearth ?thread_id () =
  match backend () with
  | Jsonl store ->
      (match
         Board.create_post store ~author ~content ?title ?body ~post_kind ?meta_json
           ~visibility ~ttl_hours ?hearth ?thread_id ()
       with
       | Ok post as ok ->
           let pid = Board.Post_id.to_string post.id in
           let auth = Board.Agent_id.to_string post.author in
           emit_keeper_board_signal
             {
               kind = Board_post_created;
               post_id = pid;
               author = auth;
               title = post.title;
               content = post.content;
               hearth = post.hearth;
             };
           emit_board_sse_event
             (Post_created { post_id = pid; author = auth;
                             title = post.title; hearth = post.hearth });
           ok
       | Error _ as err -> err)
  | Postgres t ->
      (match
         Board_pg.create_post t ~author ~content ?title ?body ~post_kind ?meta_json
           ~visibility ~ttl_hours ?hearth ?thread_id ()
       with
       | Ok post as ok ->
           let pid = Board.Post_id.to_string post.id in
           let auth = Board.Agent_id.to_string post.author in
           emit_keeper_board_signal
             {
               kind = Board_post_created;
               post_id = pid;
               author = auth;
               title = post.title;
               content = post.content;
               hearth = post.hearth;
             };
           emit_board_sse_event
             (Post_created { post_id = pid; author = auth;
                             title = post.title; hearth = post.hearth });
           ok
       | Error _ as err -> err)

let get_post ~post_id =
  match backend () with
  | Jsonl store -> Board.get_post store ~post_id
  | Postgres t -> Board_pg.get_post t ~post_id

let list_posts ?(visibility_filter=None) ?hearth ?author_filter ?post_kind_filter ?(sort_by=Hot)
    ?(exclude_system=false) ?(exclude_automation=false) ?(limit=50) () =
  let author_filter = normalize_author_filter author_filter in
  let apply_visibility_and_hearth_filters posts =
    let posts =
      match visibility_filter with
      | Some visibility ->
          List.filter (fun (post : Board.post) -> post.visibility = visibility) posts
      | None -> posts
    in
    match hearth with
    | Some hearth_name ->
        let hearth_name = String.lowercase_ascii (String.trim hearth_name) in
        List.filter (fun (post : Board.post) -> post.hearth = Some hearth_name) posts
    | None -> posts
  in
  let apply_post_kind_filter posts =
    posts
    |> List.filter (fun (p : Board.post) ->
           Board.post_matches_filters ~exclude_system ~exclude_automation p)
    |> (match post_kind_filter with
       | Some kind ->
           List.filter
             (fun (p : Board.post) -> Board.classify_post_kind p = kind)
       | None -> Fun.id)
  in
  match backend () with
  | Jsonl store ->
      let fetch_limit =
        if Option.is_some author_filter then Board.Limits.max_posts
        else max limit 200
      in
      let posts =
        if Option.is_some author_filter then
          Board.search_posts store ~predicate:(fun _ -> true) ~limit:fetch_limit
        else
          Board.list_posts store ~visibility_filter ?hearth ~limit:fetch_limit ()
      in
      let sorted =
        posts
        |> apply_visibility_and_hearth_filters
        |> sort_posts_in_memory ~sort_by
      in
      let filtered = apply_post_kind_filter sorted in
      let filtered =
        match author_filter with
        | None -> filtered
        | Some needle ->
            let matching_comment_post_ids =
              Board.list_comments store ~limit:max_int ()
              |> matching_post_ids_for_comment_author_filter ~needle
            in
            List.filter
              (fun (post : Board.post) ->
                agent_matches_author_filter ~needle post.author
                || Hashtbl.mem matching_comment_post_ids
                     (Board.Post_id.to_string post.id))
              filtered
      in
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
        Option.is_some post_kind_filter || exclude_system || exclude_automation
      in
      (* Over-fetch when post-query filtering is needed to avoid short results *)
      let fetch_limit = if needs_filter then max limit (limit * 3) else limit in
      let posts =
        Board_pg.list_posts t ~visibility_filter ?hearth ?author_filter
          ~sort_by:pg_sort ~limit:fetch_limit ()
      in
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
      (match Board.add_comment store ~post_id ~author ~content ?parent_id ~ttl_hours () with
       | Ok comment as ok ->
           let cid = Board.Comment_id.to_string comment.id in
           let auth = Board.Agent_id.to_string comment.author in
           (match Board.get_post store ~post_id with
            | Ok post ->
                emit_keeper_board_signal
                  {
                    kind = Board_comment_added;
                    post_id;
                    author = auth;
                    title = post.title;
                    content;
                    hearth = post.hearth;
                  }
            | Error e -> Log.BoardLog.warn "board signal skipped: get_post failed for %s: %s" post_id (Board_types.show_board_error e));
           emit_board_sse_event
             (Comment_added { post_id; comment_id = cid; author = auth });
           ok
       | Error _ as err -> err)
  | Postgres t ->
      (match Board_pg.add_comment t ~post_id ~author ~content ?parent_id ~ttl_hours () with
       | Ok comment as ok ->
           let cid = Board.Comment_id.to_string comment.id in
           let auth = Board.Agent_id.to_string comment.author in
           (match Board_pg.get_post t ~post_id with
            | Ok post ->
                emit_keeper_board_signal
                  {
                    kind = Board_comment_added;
                    post_id;
                    author = auth;
                    title = post.title;
                    content;
                    hearth = post.hearth;
                  }
            | Error e -> Log.BoardLog.warn "board signal skipped: pg get_post failed for %s: %s" post_id (Board_types.show_board_error e));
           emit_board_sse_event
             (Comment_added { post_id; comment_id = cid; author = auth });
           ok
       | Error _ as err -> err)

let vote ~voter ~post_id ~direction =
  let result = match backend () with
    | Jsonl store -> Board.vote store ~voter ~post_id ~direction
    | Postgres t -> Board_pg.vote_post t ~voter ~post_id ~direction
  in
  (match result with
   | Ok _score ->
       emit_board_sse_event
         (Post_voted { post_id; voter; direction })
   | Error e ->
       Log.BoardLog.warn
         "board vote failed: post_id=%s voter=%s: %s"
         post_id voter (Board_types.show_board_error e));
  result

let vote_comment ~voter ~comment_id ~direction =
  let result = match backend () with
    | Jsonl store -> Board.vote_comment store ~voter ~comment_id ~direction
    | Postgres t -> Board_pg.vote_comment t ~voter ~comment_id ~direction
  in
  (match result with
   | Ok _score ->
       emit_board_sse_event
         (Comment_voted { comment_id; voter; direction })
   | Error e ->
       Log.BoardLog.warn
         "board vote_comment failed: comment_id=%s voter=%s: %s"
         comment_id voter (Board_types.show_board_error e));
  result

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

let search ~query ~limit =
  match backend () with
  | Jsonl store ->
      (* Full-scan search: match query against content, author, hearth.
         Uses Board.search_posts to scan all posts (not limited by list_posts cap). *)
      let query_lower = String.lowercase_ascii query in
      let pattern = Re.str query_lower |> Re.compile in
      let matches_str s =
        Re.execp pattern (String.lowercase_ascii s)
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
  with_board_ro (fun () ->
    match !backend_state with
    | Active (Jsonl store) -> Board.flush_dirty store
    | _ -> ())

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

let reclassify_posts ?(limit=5200) ?(dry_run=true) () =
  match backend () with
  | Jsonl store -> Board.reclassify_posts store ~limit ~dry_run ()
  | Postgres t -> Board_pg.reclassify_posts t ~limit ~dry_run ()

(** Backend name for diagnostics *)
let backend_name () =
  with_board_ro (fun () ->
    match !backend_state with
    | Active (Jsonl _) -> "jsonl"
    | Active (Postgres _) -> "postgresql"
    | Uninitialized -> "uninitialized")
