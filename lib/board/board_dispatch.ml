module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Board_dispatch - Runtime backend selection for MASC Board

    Board now runs on the JSONL store only. Backend is selected once at
    server startup and fixed for the session.

    @since 0.6.0
*)

type sort_order = Hot | Trending | Recent | Updated | Discussed

(** Issue #8449: SSOT helpers for [sort_order]. Three call sites used to
    own private parsers and a separate Variant in [Board_tool]; this PR
    A introduces the canonical helpers here so the schema enum can derive
    from the Variant. PR B will collapse the duplicate Variant; PR C
    will route [server_utils] through these parsers.

    All constructors are nullary so [List.map] works. *)
let all_sort_orders = [ Hot; Trending; Recent; Updated; Discussed ]

let sort_order_to_string = function
  | Hot -> "hot"
  | Trending -> "trending"
  | Recent -> "recent"
  | Updated -> "updated"
  | Discussed -> "discussed"

let valid_sort_order_strings = List.map sort_order_to_string all_sort_orders

(** Canonical parser shared by Board_tool and HTTP query-param handling. *)
let sort_order_of_string_opt s =
  match String.lowercase_ascii (String.trim s) with
  | "hot" -> Some Hot
  | "trending" -> Some Trending
  | "recent" -> Some Recent
  | "updated" -> Some Updated
  | "discussed" -> Some Discussed
  | _ -> None

type board_backend =
  | Jsonl of Board.store

(** Marker carried inside [Active] tracking whether the flusher fiber has
    been spawned for the current backend.  [Eio.Fiber.fork_daemon] returns
    [unit], so there's no cancel handle to thread through; the [bool]
    placeholder keeps the structural fact - "we are active and the flusher
    is (or is not) running" - inseparable from the backend itself.

    Tier D D-7: this used to live in a sibling [flusher_started : bool
    Atomic.t], which allowed [Active && not flusher_started] /
    [not Active && flusher_started] to be representable across two
    independent CAS sites.  Folding the flag in collapses that surface. *)
type flusher_handle = bool

type backend_state =
  | Uninitialized
  | Active of board_backend * flusher_handle

type board_signal_kind =
  | Board_post_created
  | Board_comment_added

type board_signal = {
  kind : board_signal_kind;
  post_id : string;
  author : string;
  title : string;
  content : string;
  hearth : string option;
  updated_at : float option;
}

type board_sse_event =
  | Post_created of {
      post_id : string;
      author : string;
      title : string;
      content : string;
      post_kind : Board.post_kind;
      hearth : string option;
    }
  | Comment_added of { post_id : string; comment_id : string; author : string }
  | Post_voted of { post_id : string; voter : string; direction : Board.vote_direction }
  | Comment_voted of { comment_id : string; voter : string; direction : Board.vote_direction }
  | Reaction_changed of {
      target_type : Board.reaction_target_type;
      target_id : string;
      user_id : string;
      emoji : string;
      reacted : bool;
    }

let backend_state : backend_state Atomic.t = Atomic.make Uninitialized
let flusher_start_cas_retries = 3
let flusher_start_backoff_base_s = 0.001
let flusher_start_backoff_cap_s = 0.02
let forced_flusher_start_cas_conflicts_for_test : int Atomic.t = Atomic.make 0

let flusher_start_backoff_delay_s ~attempt =
  let rec pow2 acc n =
    if n <= 0 then acc else pow2 (acc *. 2.0) (n - 1)
  in
  Float.min flusher_start_backoff_cap_s
    (flusher_start_backoff_base_s *. pow2 1.0 attempt)

let sleep_flusher_start_backoff ~attempt =
  let delay = flusher_start_backoff_delay_s ~attempt in
  match Eio_context.get_clock_opt () with
  | Some clock -> Eio.Time.sleep clock delay
  | None -> Time_compat.sleep delay

let consume_forced_flusher_start_cas_conflict_for_test () =
  let rec loop () =
    let remaining = Atomic.get forced_flusher_start_cas_conflicts_for_test in
    if remaining <= 0 then false
    else if Atomic.compare_and_set forced_flusher_start_cas_conflicts_for_test
        remaining (remaining - 1)
    then true
    else loop ()
  in
  loop ()

let force_flusher_start_cas_conflicts_for_test count =
  Atomic.set forced_flusher_start_cas_conflicts_for_test (Int.max 0 count)

let flusher_started_for_test () =
  match Atomic.get backend_state with
  | Active (_, true) -> true
  | Active (_, false) | Uninitialized -> false

let flusher_start_backoff_delay_for_test ~attempt =
  flusher_start_backoff_delay_s ~attempt

let start_flusher_actor ~sw store =
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Log.BoardLog.info "Board flusher actor started";
    while true do
      match Eio.Stream.take store.Board.flusher_inbox with
      | Board_types.Flush ->
          (try Board.flush_dirty store
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn -> Log.BoardLog.error "Flush failed: %s" (Printexc.to_string exn))
      | Board_types.Sweep ->
          (try
             let swept = Board.sweep store in
             ignore swept
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn -> Log.BoardLog.error "Sweep failed: %s" (Printexc.to_string exn))
    done
  )

(** CAS [Active (b, false) -> Active (b, true)] for the current [b], then
    spawn the flusher daemon.  If the CAS loses to another fiber, retry a
    bounded number of times with short exponential backoff while the state
    still needs a flusher; if another fiber already flipped the flag,
    return.  On daemon-spawn failure, roll the flag back so a later caller
    can retry.

    Pre-D-7 this was a sibling [Atomic.compare_and_set flusher_started
    false true]; the flag now lives in the variant so it cannot drift
    away from the [Active] state. *)
let ensure_flusher_actor store =
  match Eio_context.get_switch_opt () with
  | None -> ()
  | Some sw ->
      let rec loop attempts_left =
        let current = Atomic.get backend_state in
        match current with
        | Uninitialized -> ()
        | Active (_, true) -> ()
        | Active (b, false) ->
            let cas_won =
              if consume_forced_flusher_start_cas_conflict_for_test () then false
              else Atomic.compare_and_set backend_state current (Active (b, true))
            in
            if cas_won then
              try start_flusher_actor ~sw store
              with exn ->
                (* Roll the flag back so a future caller can retry.  Only
                   roll back if the state hasn't been swapped out from
                   under us. *)
                let _ : bool =
                  Atomic.compare_and_set backend_state
                    (Active (b, true)) (Active (b, false))
                in
                match exn with
                | Invalid_argument msg when String.equal msg "Switch finished!" ->
                    Board_metrics_hooks.inc_dispatch_flusher_start_outcome
                      ~outcome:Switch_finished;
                    Log.BoardLog.warn
                      "Skipping board flusher actor startup on finished switch"
                | _ -> raise exn
            else if attempts_left > 0 then begin
              Eio.Fiber.yield ();
              sleep_flusher_start_backoff
                ~attempt:(flusher_start_cas_retries - attempts_left);
              loop (attempts_left - 1)
            end else begin
              Board_metrics_hooks.inc_dispatch_flusher_start_outcome
                ~outcome:Cas_exhausted;
              Log.BoardLog.warn
                "Board flusher actor startup CAS contention exhausted; retrying on next backend access"
            end
      in
      loop flusher_start_cas_retries


let board_signal_hook : (board_signal -> unit) option Atomic.t = Atomic.make None

let set_board_signal_hook hook =
  Atomic.set board_signal_hook (Some hook)

let emit_board_signal signal =
  match Atomic.get board_signal_hook with
  | Some hook ->
      (try hook signal
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.BoardLog.error "Board signal hook failed: %s"
             (Printexc.to_string exn))
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
    let backend = Active (Jsonl store, false) in
    if Atomic.compare_and_set backend_state Uninitialized backend then begin
      ensure_flusher_actor store;
      Log.BoardLog.info "JSONL backend initialized"
    end else
      Log.BoardLog.warn "already initialized concurrently, ignoring init_jsonl"
  end

let reset_for_test () =
  (* D-7: dropping [Active] also drops the flusher-started flag, since
     it now lives inside the variant. *)
  Atomic.set backend_state Uninitialized;
  Atomic.set forced_flusher_start_cas_conflicts_for_test 0;
  Atomic.set board_signal_hook None;
  Atomic.set board_sse_hook None

let jsonl_forced () =
  match Env_config.Board.backend_opt () with
  | Some Env_config.Board.Jsonl -> true
  | Some (Env_config.Board.Pg | Env_config.Board.Unknown_backend _) | None -> false

let backend () =
  match Atomic.get backend_state with
  | Active (Jsonl store as backend, _) ->
      ensure_flusher_actor store;
      backend
  | Uninitialized ->
      Log.BoardLog.warn "backend() called before server init, auto-initializing JSONL";
      let store = Board.global () in
      let b = Jsonl store in
      let backend_val = Active (b, false) in
      let _ = Atomic.compare_and_set backend_state Uninitialized backend_val in
      match Atomic.get backend_state with
      | Active (Jsonl active_store as active_b, _) ->
          ensure_flusher_actor active_store;
          active_b
      | Uninitialized ->
          ensure_flusher_actor store;
          b

let sort_posts_in_memory ~sort_by (posts : Board.post list) =
  (* Ranking formulas live in [Board_sort] (single source of truth) so the
     Hot/Trending definitions cannot drift between this in-memory sort and
     [Board_core.list_posts]'s cached default sort. See [Board_sort]. *)
  match sort_by with
  | Hot -> List.sort Board_sort.hot_compare posts
  | Recent ->
      List.sort (fun (a : Board.post) (b : Board.post) ->
        Stdlib.Float.compare b.created_at a.created_at) posts
  | Updated ->
      List.sort (fun (a : Board.post) (b : Board.post) ->
        Stdlib.Float.compare b.updated_at a.updated_at) posts
  | Trending ->
      List.sort (Board_sort.trending_compare ~now:(Time_compat.now ())) posts
  | Discussed ->
      List.sort (fun (a : Board.post) (b : Board.post) ->
        let cmp = Stdlib.Int.compare b.reply_count a.reply_count in
        if cmp <> 0 then cmp else Stdlib.Float.compare b.created_at a.created_at) posts

let normalize_author_filter = function
  | Some raw ->
      let trimmed = String.trim raw in
      if String.equal trimmed "" then None else Some (String.lowercase_ascii trimmed)
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
    ?(ttl_hours = Board.Limits.default_ttl_hours) ?hearth ?thread_id ?origin () =
  match backend () with
  | Jsonl store ->
      (match
         Board.create_post_with_outcome store ~author ~content ?title ?body
           ~post_kind ?meta_json ~visibility ~ttl_hours ?hearth ?thread_id
           ?origin ()
       with
      | Ok (Board.Fresh_post post) ->
          let pid = Board.Post_id.to_string post.id in
          let auth = Board.Agent_id.to_string post.author in
          emit_board_signal
            {
              kind = Board_post_created;
              post_id = pid;
              author = auth;
              title = post.title;
              content = post.content;
              hearth = post.hearth;
              updated_at = Some post.updated_at;
            };
          emit_board_sse_event
            (Post_created
               { post_id = pid; author = auth; title = post.title;
                 content = post.content; post_kind = post.post_kind;
                 hearth = post.hearth });
          Ok post
      | Ok (Board.Dedup_hit post) | Ok (Board.Rolled_up_post post) -> Ok post
      | Error _ as err -> err)

let update_post ~post_id ~editor ~content ?title ?body ?new_author () =
  match backend () with
  | Jsonl store ->
      Board.update_post_with_outcome store ~post_id ~editor ~content ?title
        ?body ?new_author ()

let get_post ~post_id =
  match backend () with
  | Jsonl store -> Board.get_post store ~post_id

let list_posts ?(visibility_filter = None) ?hearth ?author_filter ?exclude_author_filter
    ?post_kind_filter
    ?(sort_by = Hot) ?(exclude_system = false) ?(exclude_automation = false)
    ?(limit = 50) () =
  let author_filter = normalize_author_filter author_filter in
  let exclude_author_filter = normalize_author_filter exclude_author_filter in
  let apply_visibility_and_hearth_filters posts =
    let posts =
      match visibility_filter with
      | Some visibility ->
          List.filter (fun (post : Board.post) -> (=) post.visibility visibility) posts
      | None -> posts
    in
    match hearth with
    | Some hearth_name ->
        let hearth_name = String.lowercase_ascii (String.trim hearth_name) in
        List.filter (fun (post : Board.post) -> Option.equal String.equal post.hearth (Some hearth_name)) posts
    | None -> posts
  in
  let apply_post_kind_filter posts =
    posts
    |> List.filter (fun (p : Board.post) ->
           Board.post_matches_filters ~exclude_system ~exclude_automation p)
    |> (match post_kind_filter with
       | Some kind ->
           List.filter
             (fun (p : Board.post) -> (=) (Board.classify_post_kind p) kind)
       | None -> Stdlib.Fun.id)
  in
  match backend () with
  | Jsonl store ->
      let needs_full_scan =
        Option.is_some author_filter
        || Option.is_some exclude_author_filter
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
              Board.list_comments store ~limit:Stdlib.max_int ()
              |> matching_post_ids_for_comment_author_filter ~needle
            in
            List.filter
              (fun (post : Board.post) ->
                agent_matches_author_filter ~needle post.author
                || Hashtbl.mem matching_comment_post_ids
                     (Board.Post_id.to_string post.id))
              filtered
      in
      (* Exclude posts by author (post author only, not comment author).
         Unlike the positive author_filter which matches comment authors too,
         exclusion is post-author-only: hiding agent X should not remove
         agent Y's post just because X commented on it. *)
      let filtered =
        match exclude_author_filter with
        | None -> filtered
        | Some needle ->
            List.filter
              (fun (post : Board.post) ->
                not (agent_matches_author_filter ~needle post.author))
              filtered
      in
      Board.take limit filtered

let get_comments ~post_id =
  match backend () with
  | Jsonl store -> Board.get_comments store ~post_id

let get_post_and_comments ~post_id ?comment_offset ?comment_limit () =
  match backend () with
  | Jsonl store -> Board.get_post_and_comments store ~post_id ?comment_offset ?comment_limit ()

let add_comment ~post_id ~author ~content ?parent_id
    ?(ttl_hours = Board.Limits.default_ttl_hours) () =
  match backend () with
  | Jsonl store ->
      (match
         Board.add_comment_with_status store ~post_id ~author ~content ?parent_id
           ~ttl_hours ()
       with
      | Ok (comment, `Fresh) ->
          let cid = Board.Comment_id.to_string comment.id in
          let auth = Board.Agent_id.to_string comment.author in
          (match Board.get_post store ~post_id with
          | Ok post ->
              emit_board_signal
                {
                  kind = Board_comment_added;
                  post_id;
                  author = auth;
                  title = post.title;
                  content;
                  hearth = post.hearth;
                  updated_at = Some post.updated_at;
                }
          | Error e ->
              Log.BoardLog.warn "board signal skipped: get_post failed for %s: %s"
                post_id (Board_types.show_board_error e));
          emit_board_sse_event
            (Comment_added { post_id; comment_id = cid; author = auth });
          Ok comment
      | Ok (comment, `Dedup) -> Ok comment
      | Error _ as err -> err)

let current_vote_for_post ~voter ~post_id =
  match backend () with
  | Jsonl store -> Board.current_vote_for_post store ~voter ~post_id

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
       (match e with
        | Board_types.Already_voted _ ->
            Log.BoardLog.debug
        | Board_types.Post_not_found _ | Board_types.Comment_not_found _ ->
            Log.BoardLog.info
        | _ -> Log.BoardLog.warn)
         "board vote failed: post_id=%s voter=%s: %s"
         post_id voter (Board_types.show_board_error e));
  result

let current_vote_for_comment ~voter ~comment_id =
  match backend () with
  | Jsonl store -> Board.current_vote_for_comment store ~voter ~comment_id

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
       (match e with
        | Board_types.Already_voted _ ->
            Log.BoardLog.debug
        | Board_types.Post_not_found _ | Board_types.Comment_not_found _ ->
            Log.BoardLog.info
        | _ -> Log.BoardLog.warn)
         "board vote_comment failed: comment_id=%s voter=%s: %s"
         comment_id voter (Board_types.show_board_error e));
  result

let toggle_reaction ~target_type ~target_id ~user_id ~emoji =
  let result =
    match backend () with
    | Jsonl store ->
        Board.toggle_reaction store ~target_type ~target_id ~user_id ~emoji
  in
  (match result with
   | Ok toggled ->
       emit_board_sse_event
         (Reaction_changed
            {
              target_type;
              target_id;
              user_id = toggled.user_id;
              emoji = toggled.emoji;
              reacted = toggled.reacted;
            })
   | Error e ->
       (match e with
        | Board_types.Post_not_found _ | Board_types.Comment_not_found _ ->
            Log.BoardLog.info
        | _ -> Log.BoardLog.warn)
         "board reaction failed: target=%s:%s user=%s emoji=%s: %s"
         (Board.reaction_target_type_to_string target_type)
         target_id user_id emoji (Board_types.show_board_error e));
  result

let list_reactions ~target_type ~target_id ?user_id () =
  match backend () with
  | Jsonl store -> Board.list_reactions store ~target_type ~target_id ?user_id ()

let list_reactions_batch ~targets ?user_id () =
  match backend () with
  | Jsonl store -> Board.list_reactions_batch store ~targets ?user_id ()

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

let set_pinned ~post_id ~pinned =
  match backend () with
  | Jsonl store -> Board.set_pinned store ~post_id ~pinned

let delete_post ~post_id =
  match backend () with
  | Jsonl store -> Board.delete_post store ~post_id

let search ~query ~limit =
  match backend () with
  | Jsonl store ->
      let query_lower = String.lowercase_ascii query in
      let matches_str s =
        String_util.contains_substring (String.lowercase_ascii s) query_lower
      in
      let predicate (p : Board.post) =
        matches_str p.title
        || matches_str p.content
        || matches_str (Board.Agent_id.to_string p.author)
        || (match p.hearth with Some h -> matches_str h | None -> false)
      in
      Board.search_posts store ~predicate ~limit

let flush () =
  match Atomic.get backend_state with
  | Active (Jsonl store, _) -> Board.flush_dirty store
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

let karma_score_for_direction = Board.karma_score_for_direction

let get_karma_ledger ?agent ?(limit = max_int) () =
  let events =
    match backend () with
    | Jsonl store -> Board.build_karma_ledger store
  in
  let filtered =
    match agent with
    | None -> events
    | Some name ->
        List.filter (fun (e : Board.karma_event) -> String.equal e.recipient name) events
  in
  Board.take limit filtered

let post_to_yojson_with_karma (p : Board.post) ~author_karma =
  Board.post_to_yojson_with_karma p ~author_karma

let reclassify_posts ?(limit = 5200) ?(dry_run = true) () =
  match backend () with
  | Jsonl store -> Board.reclassify_posts store ~limit ~dry_run ()

let backend_name () =
  match Atomic.get backend_state with
  | Active (Jsonl _, _) -> "jsonl"
  | Uninitialized -> "uninitialized"

(* AI curation delegate — thin wrappers around Board_curation *)

let submit_curation_snapshot ~submitted_by ?summary ~ordering ~highlights
    ?(tag_suggestions = []) ?(answer_matches = []) ~rationale
    ?(provenance = `Assoc []) () =
  let snap : Board_curation.curation_snapshot = {
    id = Board_curation.generate_id ();
    generated_at = Time_compat.now ();
    submitted_by;
    summary;
    ordering;
    highlights;
    tag_suggestions;
    answer_matches;
    rationale;
    provenance;
  } in
  Board_curation.submit_snapshot snap;
  snap

let latest_curation_snapshot () =
  Board_curation.latest_snapshot ()

(** {1 SubBoard operations} *)

let create_sub_board ~slug ~name ~description ~owner ?members ?access () =
  match backend () with
  | Jsonl store ->
      Board.create_sub_board store ~slug ~name ~description ~owner ?members ?access ()

let get_sub_board ~sub_board_id =
  match backend () with
  | Jsonl store -> Board.get_sub_board store ~sub_board_id

let list_sub_boards () =
  match backend () with
  | Jsonl store -> Board.list_sub_boards store

let delete_sub_board ~sub_board_id =
  match backend () with
  | Jsonl store -> Board.delete_sub_board store ~sub_board_id

let update_sub_board ~sub_board_id ?name ?description ?members ?access () =
  match backend () with
  | Jsonl store -> Board.update_sub_board store ~sub_board_id ?name ?description ?members ?access ()
