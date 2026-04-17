(** Board_dispatch - Runtime backend selection for MASC Board

    Board now runs on the JSONL store only. Backend is selected once at
    server startup and fixed for the session.

    @since 0.6.0
*)

type sort_order = Hot | Trending | Recent | Updated | Discussed

type board_backend =
  | Jsonl of Board.store

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
  | Post_created of { post_id : string; author : string; title : string; content : string; hearth : string option }
  | Comment_added of { post_id : string; comment_id : string; author : string }
  | Post_voted of { post_id : string; voter : string; direction : Board.vote_direction }
  | Comment_voted of { comment_id : string; voter : string; direction : Board.vote_direction }

let backend_state : backend_state Atomic.t = Atomic.make Uninitialized
let flusher_started : bool Atomic.t = Atomic.make false

let start_flusher_actor ~sw store =
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Log.BoardLog.info "Board flusher actor started";
    while true do
      match Eio.Stream.take store.Board.flusher_inbox with
      | Board_types.Flush ->
          (try Board.flush_dirty store
           with exn -> Log.BoardLog.error "Flush failed: %s" (Printexc.to_string exn))
      | Board_types.Sweep ->
          (try ignore (Board.sweep store)
           with exn -> Log.BoardLog.error "Sweep failed: %s" (Printexc.to_string exn))
    done
  )

let ensure_flusher_actor store =
  match Eio_context.get_switch_opt () with
  | None -> ()
  | Some sw ->
      if Atomic.compare_and_set flusher_started false true then
        try start_flusher_actor ~sw store
        with exn ->
          Atomic.set flusher_started false;
          match exn with
          | Invalid_argument msg when String.equal msg "Switch finished!" ->
              Log.BoardLog.warn
                "Skipping board flusher actor startup on finished switch"
          | _ -> raise exn


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
  match Atomic.get backend_state with
  | Active _ -> true
  | Uninitialized -> false

let init_jsonl () =
  if match Atomic.get backend_state with Active _ -> true | Uninitialized -> false then
    Log.BoardLog.warn "already initialized, ignoring init_jsonl"
  else begin
    let store = Board.global () in
    let backend = Active (Jsonl store) in
    if Atomic.compare_and_set backend_state Uninitialized backend then begin
      ensure_flusher_actor store;
      Log.BoardLog.info "JSONL backend initialized"
    end else
      Log.BoardLog.warn "already initialized concurrently, ignoring init_jsonl"
  end

let reset_for_test () =
  Atomic.set backend_state Uninitialized;
  Atomic.set flusher_started false

let jsonl_forced () =
  match Env_config.Board.backend_opt () with
  | Some Env_config.Board.Jsonl -> true
  | Some (Env_config.Board.Pg | Env_config.Board.Unknown_backend _) | None -> false

let backend () =
  match Atomic.get backend_state with
  | Active (Jsonl store as backend) ->
      ensure_flusher_actor store;
      backend
  | Uninitialized ->
      Log.BoardLog.warn "backend() called before server init, auto-initializing JSONL";
      let store = Board.global () in
      let b = Jsonl store in
      let backend_val = Active b in
      let _ = Atomic.compare_and_set backend_state Uninitialized backend_val in
      match Atomic.get backend_state with
      | Active (Jsonl active_store as active_b) ->
          ensure_flusher_actor active_store;
          active_b
      | Uninitialized ->
          ensure_flusher_actor store;
          b

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
        let score_a =
          float_of_int (a.votes_up - a.votes_down + (a.reply_count * 2))
          /. (age_a ** 0.5)
        in
        let score_b =
          float_of_int (b.votes_up - b.votes_down + (b.reply_count * 2))
          /. (age_b ** 0.5)
        in
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

let create_post ~author ~content ?title ?body ~post_kind ?meta_json
    ?(visibility = Board.Internal)
    ?(ttl_hours = Board.Limits.default_ttl_hours) ?hearth ?thread_id () =
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
            (Post_created
               { post_id = pid; author = auth; title = post.title;
                 content = post.content; hearth = post.hearth });
          ok
      | Error _ as err -> err)

let get_post ~post_id =
  match backend () with
  | Jsonl store -> Board.get_post store ~post_id

let list_posts ?(visibility_filter = None) ?hearth ?author_filter ?post_kind_filter
    ?(sort_by = Hot) ?(exclude_system = false) ?(exclude_automation = false)
    ?(limit = 50) () =
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
      let needs_full_scan =
        Option.is_some author_filter
        ||
        match sort_by with
        | Hot -> false
        | Trending | Recent | Updated | Discussed -> true
      in
      let fetch_limit =
        if needs_full_scan then Board.Limits.max_posts else max limit 200
      in
      let posts =
        if needs_full_scan then
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

let get_comments ~post_id =
  match backend () with
  | Jsonl store -> Board.get_comments store ~post_id

let add_comment ~post_id ~author ~content ?parent_id
    ?(ttl_hours = Board.Limits.default_ttl_hours) () =
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
          | Error e ->
              Log.BoardLog.warn "board signal skipped: get_post failed for %s: %s"
                post_id (Board_types.show_board_error e));
          emit_board_sse_event
            (Comment_added { post_id; comment_id = cid; author = auth });
          ok
      | Error _ as err -> err)

let vote ~voter ~post_id ~direction =
  let result =
    match backend () with
    | Jsonl store -> Board.vote store ~voter ~post_id ~direction
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
  let result =
    match backend () with
    | Jsonl store -> Board.vote_comment store ~voter ~comment_id ~direction
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

let list_comments ?(limit = 1000) () =
  match backend () with
  | Jsonl store -> Board.list_comments store ~limit ()

let list_hearths () =
  match backend () with
  | Jsonl store -> Board.list_hearths store

let set_thread_id ~post_id ~thread_id =
  match backend () with
  | Jsonl store -> Board.set_thread_id store ~post_id ~thread_id

let delete_post ~post_id =
  match backend () with
  | Jsonl store -> Board.delete_post store ~post_id

let search ~query ~limit =
  match backend () with
  | Jsonl store ->
      let query_lower = String.lowercase_ascii query in
      let pattern = Re.str query_lower |> Re.compile in
      let matches_str s = Re.execp pattern (String.lowercase_ascii s) in
      let predicate (p : Board.post) =
        matches_str p.title
        || matches_str p.content
        || matches_str (Board.Agent_id.to_string p.author)
        || (match p.hearth with Some h -> matches_str h | None -> false)
      in
      Board.search_posts store ~predicate ~limit

let flush () =
  match Atomic.get backend_state with
  | Active (Jsonl store) -> Board.flush_dirty store
  | Uninitialized -> ()

let sweep () =
  match backend () with
  | Jsonl store -> Board.sweep store

let get_all_karma () =
  match backend () with
  | Jsonl store -> Board.get_all_karma store

let get_agent_karma ~agent_name =
  match backend () with
  | Jsonl store -> Board.get_agent_karma store ~agent_name

let post_to_yojson_with_karma (p : Board.post) ~author_karma =
  Board.post_to_yojson_with_karma p ~author_karma

let reclassify_posts ?(limit = 5200) ?(dry_run = true) () =
  match backend () with
  | Jsonl store -> Board.reclassify_posts store ~limit ~dry_run ()

let backend_name () =
  match Atomic.get backend_state with
  | Active (Jsonl _) -> "jsonl"
  | Uninitialized -> "uninitialized"
