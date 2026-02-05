(** Board_dispatch - Runtime backend selection for MASC Board

    Routes Board operations to either JSONL (Board.store) or PostgreSQL (Board_pg.t).
    Backend is selected once at server startup and fixed for the session.

    @since 0.6.0
*)

(** Sort order for post listing (PG uses SQL ORDER BY, JSONL sorts in-memory) *)
type sort_order = Hot | Trending | Recent | Updated | Discussed

(** Backend variant *)
type board_backend =
  | Jsonl of Board.store
  | Postgres of Board_pg.t

(** Current backend. Set once at server startup, guarded against double-init. *)
let current_backend : board_backend option ref = ref None
let initialized = ref false

(** Initialize PostgreSQL backend. Call during server startup when PG pool is available. *)
let init_pg pool =
  if !initialized then begin
    Printf.eprintf "[Board_dispatch] WARNING: already initialized, ignoring init_pg\n%!";
    Ok ()
  end else
  match Board_pg.create pool with
  | Ok t ->
      current_backend := Some (Postgres t);
      initialized := true;
      Printf.eprintf "[Board_dispatch] PostgreSQL backend initialized.\n%!";
      Ok ()
  | Error e ->
      Printf.eprintf "[Board_dispatch] PG init failed, falling back to JSONL: %s\n%!"
        (Board.show_board_error e);
      Error e

(** Initialize JSONL backend. Default fallback. *)
let init_jsonl () =
  if !initialized then
    Printf.eprintf "[Board_dispatch] WARNING: already initialized, ignoring init_jsonl\n%!"
  else begin
    current_backend := Some (Jsonl (Board.global ()));
    initialized := true;
    Printf.eprintf "[Board_dispatch] JSONL backend initialized.\n%!"
  end

(** Reset for testing. Clears backend state so init can be called again. *)
let reset_for_test () =
  current_backend := None;
  initialized := false

(** Get backend or fail *)
let backend () =
  match !current_backend with
  | Some b -> b
  | None ->
      (* Auto-init JSONL as safe default *)
      init_jsonl ();
      (* init_jsonl always sets current_backend *)
      match !current_backend with
      | Some b -> b
      | None -> failwith "[Board_dispatch] init_jsonl failed to set backend"

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

let create_post ~author ~content ?(visibility=Board.Internal)
    ?(ttl_hours=Board.Limits.default_ttl_hours) ?hearth ?thread_id () =
  match backend () with
  | Jsonl store ->
      Board.create_post store ~author ~content ~visibility ~ttl_hours ?hearth ?thread_id ()
  | Postgres t ->
      Board_pg.create_post t ~author ~content ~visibility ~ttl_hours ?hearth ?thread_id ()

let get_post ~post_id =
  match backend () with
  | Jsonl store -> Board.get_post store ~post_id
  | Postgres t -> Board_pg.get_post t ~post_id

let list_posts ?(visibility_filter=None) ?hearth ?(sort_by=Hot) ?(limit=50) () =
  match backend () with
  | Jsonl store ->
      (* Fetch large pool, then sort by requested order, then take limit.
         Board.list_posts sorts by score internally, so we fetch more
         to avoid truncation before re-sorting. *)
      let fetch_limit = max limit 200 in
      let posts = Board.list_posts store ~visibility_filter ?hearth ~limit:fetch_limit () in
      let sorted = sort_posts_in_memory ~sort_by posts in
      let rec take n lst = match n, lst with
        | 0, _ | _, [] -> []
        | n, x :: xs -> x :: take (n - 1) xs
      in
      take limit sorted
  | Postgres t ->
      let pg_sort = match sort_by with
        | Hot -> Board_pg.Hot
        | Trending -> Board_pg.Trending
        | Recent -> Board_pg.Recent
        | Updated -> Board_pg.Updated
        | Discussed -> Board_pg.Discussed
      in
      Board_pg.list_posts t ~visibility_filter ?hearth ~sort_by:pg_sort ~limit ()

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

let search ~query ~limit =
  match backend () with
  | Jsonl store ->
      (* JSONL: reuse existing in-memory search logic *)
      let all_posts = Board.list_posts store ~limit:(max limit 100) () in
      let query_lower = String.lowercase_ascii query in
      let pattern = Str.regexp_string query_lower in
      let matches_str s =
        try ignore (Str.search_forward pattern (String.lowercase_ascii s) 0); true
        with Not_found -> false
      in
      List.filter (fun (p : Board.post) ->
        matches_str p.content
        || matches_str (Board.Agent_id.to_string p.author)
        || (match p.hearth with Some h -> matches_str h | None -> false)
      ) all_posts
      |> List.filteri (fun i _ -> i < limit)
  | Postgres t ->
      Board_pg.search t ~query ~limit

(** Flush dirty state (JSONL only, PG commits immediately) *)
let flush () =
  match !current_backend with
  | Some (Jsonl store) -> Board.flush_dirty store
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
  match !current_backend with
  | Some (Jsonl _) -> "jsonl"
  | Some (Postgres _) -> "postgresql"
  | None -> "uninitialized"
