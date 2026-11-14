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

type board_backend = Board.store

type initialization_error =
  | Workspace_mismatch of
      { active_workspace_masc_dir : string
      ; requested_workspace_masc_dir : string
      }
  | Workspace_binding_refused of Board_workspace_binding.rejection

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

(** Whether the server handed the backend its recipient lookup.  A backend
    that a read started on its own has none, and its writes refuse every
    address ({!Recipient_lookup.unavailable}) until [init_jsonl] installs one.
    The lookup lives in the variant, like the flusher flag, so the backend and
    its lookup cannot drift apart. *)
type lookup_state =
  | Lookup_not_installed
  | Lookup_installed of Recipient_lookup.t

type backend_state =
  | Uninitialized
  | Active of board_backend * flusher_handle * lookup_state

type board_comment_identity =
  { comment_id : Board.Comment_id.t
  ; parent_id : Board.Comment_id.t option
  }

type board_signal_kind =
  | Board_post_created
  | Board_post_updated of { content_updated_at : float }
  | Board_comment_added of board_comment_identity
  | Board_reaction_changed of board_reaction_change
  | Board_vote_cast of board_vote_change

and board_reaction_change = {
  target_type : Board.reaction_target_type;
  target_id : string;
  user_id : string;
  emoji : string;
  reacted : bool;
}

and board_vote_target =
  | Vote_on_post of string
  | Vote_on_comment of string

and board_vote_change = {
  target : board_vote_target;
  target_author : string;
  voter : string;
  direction : Board.vote_direction;
}

type board_signal = {
  kind : board_signal_kind;
  post_id : string;
  author : string;
  title : string;
  content : string;
  hearth : string option;
  updated_at : float option;
}

type addressed_board_signal = {
  signal : board_signal;
  audience : Board.audience;
}

type post_change =
  | Post_edited
  | Post_thread_set
  | Post_pinned
  | Post_unpinned
  | Post_closed
  | Post_reopened
  | Post_deleted

let post_change_to_string = function
  | Post_edited -> "edited"
  | Post_thread_set -> "thread_set"
  | Post_pinned -> "pinned"
  | Post_unpinned -> "unpinned"
  | Post_closed -> "closed"
  | Post_reopened -> "reopened"
  | Post_deleted -> "deleted"

type board_sse_event =
  | Board_changed
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
  | Post_changed of {
      post_id : string;
      change : post_change;
    }

let backend_state : backend_state Atomic.t = Atomic.make Uninitialized
let flusher_started_for_test () =
  match Atomic.get backend_state with
  | Active (_, true, _) -> true
  | Active (_, false, _) | Uninitialized -> false

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
    spawn the flusher daemon.  A lost CAS means another fiber changed the
    state, so the state is read again: it can only move to a started flusher
    or to no backend, both of which end the loop.  On daemon-spawn failure,
    roll the flag back so a later caller can retry.

    Pre-D-7 this was a sibling [Atomic.compare_and_set flusher_started
    false true]; the flag now lives in the variant so it cannot drift
    away from the [Active] state. *)
let ensure_flusher_actor store =
  match Eio_context.get_switch_opt () with
  | None -> ()
  | Some _ when not (Eio_context.root_switch_on_current_domain ()) ->
      (* The flusher forks a daemon on the server root switch (get_switch_opt's
         atomic fallback outside a turn). Eio.Fiber.fork_daemon ~sw is only legal
         on the switch's owning (main) domain, but ensure_flusher_actor is
         reachable from Domain_pool worker domains (board/dashboard projections).
         Defer on a non-owning domain: the flusher is a single CAS-guarded daemon
         started on the main domain at boot (mcp_server init_jsonl), so skipping
         here starts nothing twice and loses nothing. *)
      ()
  | Some sw ->
      let rec loop () =
        let current = Atomic.get backend_state in
        match current with
        | Uninitialized -> ()
        | Active (_, true, _) -> ()
        | Active (b, false, lookup) ->
            (* [Atomic.compare_and_set] compares physically, so the rollback
               below must name the very value this CAS stored; a fresh
               [Active (b, true)] never matches and the flag stayed set. *)
            let started = Active (b, true, lookup) in
            if Atomic.compare_and_set backend_state current started then
              try start_flusher_actor ~sw store
              with exn ->  (* cancel-guard-ok: re-raises after rolling the flag back *)
                (* Roll the flag back so a future caller can retry.  Only
                   roll back if the state hasn't been swapped out from
                   under us. *)
                let _ : bool =
                  Atomic.compare_and_set backend_state started (Active (b, false, lookup))
                in
                match exn with
                | Invalid_argument msg when String.equal msg "Switch finished!" ->
                    Board_metrics_hooks.inc_dispatch_flusher_start_outcome ();
                    Log.BoardLog.warn
                      "Skipping board flusher actor startup on finished switch"
                | _ -> raise exn
            else loop ()
      in
      loop ()


let board_signal_hook : (addressed_board_signal -> unit) option Atomic.t =
  Atomic.make None

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

let emit_board_sse_event ~visibility event =
  let event = match visibility with
    | Some Board.Public -> event
    | Some (Board.Unlisted | Board.Internal | Board.Direct) | None -> Board_changed in
  match Atomic.get board_sse_hook with
  | Some hook -> Safe_ops.protect ~default:() (fun () -> hook event)
  | None -> ()

(* The store keys a post by its parsed id, so the event names the post by the
   same id. The event follows applied state, including a deletion whose
   snapshot writes remain pending. A refused write leaves memory unchanged and
   raises none. *)
let visibility_of_post store ~post_id =
  match Board.read_post_for_evidence store ~post_id with
  | Ok post -> Some post.visibility
  | Error _ -> None

let write_post ~visibility ~post_id change write =
  match Board.Post_id.of_string post_id with
  | Error e -> Error e
  | Ok pid ->
    let post_id = Board.Post_id.to_string pid in
    (match write post_id with
     | Ok _ as written ->
       emit_board_sse_event ~visibility (Post_changed { post_id; change });
       written
     | Error _ as refused -> refused)

(* The non-positive MASC_BOARD_COMMENT_COUNT_CAP opt-out stays allowed, but
   it must not stay silent (wool-nova FAIL issuecomment-5860167607, P2):
   emit [Limits.cap_warning_message] once at JSONL backend load -- from
   [init_jsonl] and from [backend]'s auto-initialization branch. *)
let warn_comment_cap_once () =
  match Board.Limits.cap_warning_message
          ~cap:Board.Limits.comment_count_cap () with
  | Some msg -> Log.BoardLog.warn "%s" msg
  | None -> ()

let workspace_result = function
  | Ok value -> Ok value
  | Error rejection ->
    Option.iter (fun (exception_, backtrace) ->
      Board_posts_source.propagate_reserved exception_ backtrace)
      (Board_workspace_binding.raised rejection);
    Error (Workspace_binding_refused rejection)

let validate_workspace requested (store : Board.store) =
  let open Result.Syntax in
  let* requested_observation = workspace_result (Board_workspace_binding.observe requested) in
  let* active_observation = workspace_result
    (Board.with_persist_lock store (fun () -> Board_paths.observe_workspace store)) in
  if not (Board_workspace_binding.same_root active_observation requested_observation) then
    Error (Workspace_mismatch
      { active_workspace_masc_dir = Board.workspace_masc_dir store
      ; requested_workspace_masc_dir = Board_workspace_binding.workspace_masc_dir requested })
  else
    let* () = workspace_result
      (Board_workspace_binding.revalidate requested requested_observation) in
    workspace_result
      (Board_workspace_binding.revalidate store.workspace_binding active_observation)

let check_store_workspace ~base_path store =
  validate_workspace (Board_workspace_binding.capture ~base_path) store

(* A claim reads no Board file, so this comparison decides whether the process
   store may be opened for [requested] before any source lock or load. *)
let claim_matches requested requested_observation claim =
  let open Result.Syntax in
  let claimed = Board_store_lifecycle.claimed_binding claim in
  let* claimed_observation = workspace_result (Board_workspace_binding.observe claimed) in
  if Board_workspace_binding.same_root claimed_observation requested_observation then Ok ()
  else
    Error (Workspace_mismatch
      { active_workspace_masc_dir = Board_workspace_binding.workspace_masc_dir claimed
      ; requested_workspace_masc_dir = Board_workspace_binding.workspace_masc_dir requested })

let init_jsonl ~base_path ~recipient_lookup () =
  let open Result.Syntax in
  let requested = Board_workspace_binding.capture ~base_path in
  (* Refuse an invalid incoming root before claiming the store or starting
     actors. Loading can create metadata, so each attempt observes it anew. *)
  let* requested_observation =
    workspace_result (Board_workspace_binding.observe requested) in
  let installed = Lookup_installed recipient_lookup in
  let rec install () =
    match Atomic.get backend_state with
    | Active (store, flusher, lookup) as current ->
      (match validate_workspace requested store with
       | Error _ as error -> error
       | Ok () ->
         (match lookup with
          | Lookup_installed _ ->
            Log.BoardLog.debug "already initialized, ignoring init_jsonl";
            Ok ()
          | Lookup_not_installed ->
            (* A read started this same workspace before the server supplied
               its lookup. A different workspace cannot replace that authority. *)
            if Atomic.compare_and_set
                 backend_state current (Active (store, flusher, installed))
            then (
              Log.BoardLog.info "JSONL backend recipient lookup installed";
              Ok ())
            else install ()))
    | Uninitialized ->
      (* The store opens on the requested BasePath. A store somebody claimed
         earlier for another root is refused here, unopened. *)
      let claim = Board_store_lifecycle.claim_global requested in
      let* () = claim_matches requested requested_observation claim in
      let store = Board_store_lifecycle.open_claim claim in
      (match validate_workspace requested store with
       | Error _ as error -> error
       | Ok () ->
         let backend = Active (store, false, installed) in
         if Atomic.compare_and_set backend_state Uninitialized backend then (
           ensure_flusher_actor store;
           warn_comment_cap_once ();
           Log.BoardLog.info "JSONL backend initialized";
           Ok ())
         else install ())
  in
  install ()

let reset_for_test () =
  (* D-7: dropping [Active] also drops the flusher-started flag, since
     it now lives inside the variant. *)
  Atomic.set backend_state Uninitialized;
  Atomic.set board_signal_hook None;
  Atomic.set board_sse_hook None

let backend () =
  match Atomic.get backend_state with
  | Active (store, _, _) ->
      ensure_flusher_actor store;
      store
  | Uninitialized ->
      Log.BoardLog.warn "backend() called before server init, auto-initializing JSONL";
      let store = Board.global () in
      let backend_val = Active (store, false, Lookup_not_installed) in
      let won = Atomic.compare_and_set backend_state Uninitialized backend_val in
      (* Same emission contract as [init_jsonl]: the call that performs the
         Uninitialized -> Active transition warns once when the cap is off,
         so the auto-init path cannot stay silent (wool-nova P2). *)
      if won then warn_comment_cap_once ();
      match Atomic.get backend_state with
      | Active (active_store, _, _) ->
          ensure_flusher_actor active_store;
          active_store
      | Uninitialized ->
          ensure_flusher_actor store;
          store

(* The lookup the writes ask.  [backend ()] runs first so a write on a backend
   nobody started still starts it; the lookup it then finds is the server's, or
   [Recipient_lookup.unavailable] when none was handed over. *)
let recipient_lookup () =
  let _ : board_backend = backend () in
  match Atomic.get backend_state with
  | Active (_, _, Lookup_installed lookup) -> lookup
  | Active (_, _, Lookup_not_installed) | Uninitialized -> Recipient_lookup.unavailable

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

let normalize_author_filter raw =
  String_util.option_trim raw |> Option.map String.lowercase_ascii

let agent_matches_author_filter ~needle (agent_id : Board.Agent_id.t) =
  let author = Board.Agent_id.to_string agent_id |> String.lowercase_ascii in
  String_util.contains_substring author needle

module Post_id_set = Set.Make (String)

let matching_post_ids_for_comment_author_filter ~needle (comments : Board.comment list) =
  List.fold_left
    (fun acc (comment : Board.comment) ->
      if agent_matches_author_filter ~needle comment.author then
        Post_id_set.add (Board.Post_id.to_string comment.post_id) acc
      else acc)
    Post_id_set.empty
    comments

let emit_post_created ~(audience : Board.audience) (post : Board.post) =
  let pid = Board.Post_id.to_string post.id in
  let auth = Board.Agent_id.to_string post.author in
  emit_board_signal
    { signal =
        { kind = Board_post_created
        ; post_id = pid
        ; author = auth
        ; title = post.title
        ; content = post.body
        ; hearth = post.hearth
        ; updated_at = Some post.updated_at
        }
    ; audience
    };
  emit_board_sse_event ~visibility:(Some post.visibility)
    (Post_created
       { post_id = pid; author = auth; title = post.title;
         content = post.body; post_kind = post.post_kind;
         hearth = post.hearth })

let notify_post_creation (creation : Board.post_creation) =
  try
    emit_post_created ~audience:creation.audience creation.post;
    Ok creation
  with
  | (Eio.Cancel.Cancelled _ | Eio.Time.Timeout | Out_of_memory
    | Stack_overflow | Sys.Break) as exn ->
    Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
  | exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    Board_posts_source.propagate_reserved exn backtrace;
    Error
      (Board.Post_publication_failure.after_commit creation
         (Board.Post_publication_failure.Raised exn))

let resolve_post_dispatch_context () =
  try
    let store = backend () in
    let lookup = recipient_lookup () in
    Ok (store, lookup)
  with
  | (Eio.Cancel.Cancelled _ | Eio.Time.Timeout | Out_of_memory
    | Stack_overflow | Sys.Break) as exn ->
    Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
  | exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    Board_posts_source.propagate_reserved exn backtrace;
    Error
      (Board.Post_publication_failure.before_effect
         (Board.Post_publication_failure.Raised exn))

let create_post_with_unresolved ~author ~content ?title ?body ~post_kind ?meta_json
    ?visibility ?ttl_hours ?hearth ?thread_id ?origin () =
  match resolve_post_dispatch_context () with
  | Error _ as error -> error
  | Ok (store, lookup) ->
    (try
       match
         Board.create_post_with_audience
           store
           ~lookup
           ~author
           ~content
           ?title
           ?body
           ~post_kind
           ?meta_json
           ?visibility
           ?ttl_hours
           ?hearth
           ?thread_id
           ?origin
           ()
       with
       | Ok creation -> notify_post_creation creation
       | Error _ as error -> error
     with
     | (Eio.Cancel.Cancelled _ | Eio.Time.Timeout | Out_of_memory
       | Stack_overflow | Sys.Break) as exn ->
       Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
     | exn ->
       let backtrace = Printexc.get_raw_backtrace () in
       Board_posts_source.propagate_reserved exn backtrace;
       Error
         (Board.Post_publication_failure.unknown
            (Board.Post_publication_failure.Raised exn)))

let create_post ~author ~content ?title ?body ~post_kind ?meta_json
    ?visibility ?ttl_hours ?hearth ?thread_id ?origin () =
  create_post_with_unresolved ~author ~content ?title ?body ~post_kind ?meta_json
    ?visibility ?ttl_hours ?hearth ?thread_id ?origin ()
  |> Result.map (fun (creation : Board.post_creation) -> creation.post)

let create_post_once_by_fusion_run_id ~fusion_run_id ~author ~content ~post_kind
    ?meta_json ~visibility ~ttl_hours ~origin () =
  match resolve_post_dispatch_context () with
  | Error _ as error -> error
  | Ok (store, lookup) ->
    (try
       match
         Board.create_post_once_by_fusion_run_id store
           ~lookup ~fusion_run_id ~author
           ~content ~post_kind ?meta_json ~visibility ~ttl_hours ~origin ()
       with
       | Ok (Board.Post_created creation as outcome) ->
         notify_post_creation creation |> Result.map (fun _ -> outcome)
       | Ok (Board.Post_already_present _ as outcome) -> Ok outcome
       | Error _ as error -> error
     with
     | (Eio.Cancel.Cancelled _ | Eio.Time.Timeout | Out_of_memory
       | Stack_overflow | Sys.Break) as exn ->
       Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
     | exn ->
       let backtrace = Printexc.get_raw_backtrace () in
       Board_posts_source.propagate_reserved exn backtrace;
       Error
         (Board.Post_publication_failure.unknown
            (Board.Post_publication_failure.Raised exn)))

let emit_post_edited (post : Board.post) =
  emit_board_sse_event ~visibility:(Some post.visibility)
    (Post_changed { post_id = Board.Post_id.to_string post.id; change = Post_edited })

let update_post_with_unresolved ~post_id ~editor ~content ?title ?body ?new_author () =
  let store = backend () in
      match Board.update_post_with_outcome store ~lookup:(recipient_lookup ())
        ~post_id ~editor ~content ?title ?body ?new_author () with
      | Error _ as error -> error
      | Ok { edited = post; content_changed = false; recorded_audience = _; unresolved } ->
        emit_post_edited post;
        Ok (post, unresolved)
      | Ok { edited = post; content_changed = true; recorded_audience = audience
           ; unresolved } ->
        emit_post_edited post;
        emit_board_signal
          { signal =
              { kind = Board_post_updated { content_updated_at = post.content_updated_at }
              ; post_id = Board.Post_id.to_string post.id
              ; author = Board.Agent_id.to_string post.author
              ; title = post.title
              ; content = post.body
              ; hearth = post.hearth
              ; updated_at = Some post.updated_at
              }
          ; audience
          };
        Ok (post, unresolved)

let update_post ~post_id ~editor ~content ?title ?body ?new_author () =
  update_post_with_unresolved ~post_id ~editor ~content ?title ?body ?new_author ()
  |> Result.map fst

let read_post_unchecked ~post_id =
  let store = backend () in Board.read_post store ~post_id

let read_post_for_evidence_unchecked ~post_id =
  let store = backend () in Board.read_post_for_evidence store ~post_id

let get_comment_parent_for_evidence_unchecked ~comment_id =
  let store = backend () in
  match Board.get_comment store ~comment_id with
  | Error _ as error -> error
  | Ok comment ->
    Board.read_post_for_evidence store ~post_id:(Board.Post_id.to_string comment.post_id)
    |> Result.map_error Board.board_error_of_read_error

let visible_post ~reader ~post_id = function
  | Ok post when Board_access.can_read ~reader post -> Ok post
  | Ok _ -> Error (Board.Read_post_not_found post_id)
  | Error _ as error -> error

let read_post ~reader ~post_id =
  read_post_unchecked ~post_id |> visible_post ~reader ~post_id

let read_post_for_evidence ~reader ~post_id =
  read_post_for_evidence_unchecked ~post_id |> visible_post ~reader ~post_id

let get_post_unchecked ~post_id =
  read_post_unchecked ~post_id |> Result.map_error Board.board_error_of_read_error

let get_post ~reader ~post_id =
  read_post ~reader ~post_id |> Result.map_error Board.board_error_of_read_error

let list_posts_by_run_origin_unchecked () =
  let store = backend () in Board.list_posts_by_run_origin store

let list_posts_by_run_origin ~reader () =
  list_posts_by_run_origin_unchecked () |> List.filter (Board_access.can_read ~reader)

let find_post_by_run_id_unchecked ~run_id =
  let store = backend () in Board.find_post_by_run_id store ~run_id

let find_post_by_run_id ~reader ~run_id =
  match find_post_by_run_id_unchecked ~run_id with
  | Some post when Board_access.can_read ~reader post -> Some post
  | Some _ | None -> None

let list_posts ~reader ?(visibility_filter = None) ?hearth ?author_filter ?exclude_author_filter
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
  let store = backend () in
      let needs_full_scan =
        not (Board_access.is_operator reader)
        || Option.is_some author_filter
        || Option.is_some exclude_author_filter
        ||
        match sort_by with
        | Hot -> false
        | Trending | Recent | Updated | Discussed -> true
      in
      let fetch_limit = if needs_full_scan then Stdlib.max_int else max limit 500 in
      let posts =
        if needs_full_scan then
          Board.search_posts store ~predicate:(fun _ -> true) ~limit:fetch_limit
        else
          Board.list_posts store ~visibility_filter ?hearth ~limit:fetch_limit ()
      in
      let sorted =
        if needs_full_scan then
          posts
          |> apply_visibility_and_hearth_filters
          |> sort_posts_in_memory ~sort_by
        else
          posts
      in
      let filtered = sorted |> List.filter (Board_access.can_read ~reader) |> apply_post_kind_filter in
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
                || Post_id_set.mem
                     (Board.Post_id.to_string post.id)
                     matching_comment_post_ids)
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

let list_posts_unchecked ?visibility_filter ?hearth ?author_filter ?exclude_author_filter
    ?post_kind_filter ?sort_by ?exclude_system ?exclude_automation ?limit () =
  list_posts ~reader:Board_access.Operator ?visibility_filter ?hearth ?author_filter
    ?exclude_author_filter ?post_kind_filter ?sort_by ?exclude_system ?exclude_automation ?limit ()

let list_recent_posts_matching_author_unchecked ~author_matches ~limit () =
  let store = backend () in
    Board.search_posts
      store
      ~predicate:(fun (post : Board.post) -> author_matches post.author)
      ~limit:(max 0 limit)
;;

let current_post_cursor () =
  let store = backend () in Board.current_post_cursor store

let read_comments_unchecked ~post_id =
  let store = backend () in Board.read_comments store ~post_id

let read_comments ~reader ~post_id =
  match read_post ~reader ~post_id with
  | Error _ as error -> error
  | Ok _ -> read_comments_unchecked ~post_id

let get_comments_unchecked ~post_id =
  read_comments_unchecked ~post_id |> Result.map_error Board.board_error_of_read_error

let get_comments ~reader ~post_id =
  read_comments ~reader ~post_id |> Result.map_error Board.board_error_of_read_error

let require_persisted_sources_readable () =
  let store = backend () in
      Board.with_persist_lock store (fun () ->
        let open Result.Syntax in
        let* () = Board.require_posts_source_readable store in
        Board.require_comments_source_readable store)
      |> Result.map_error (fun error ->
          Board.board_error_of_read_error (Board.Read_source_unavailable error))

let get_post_and_comments_unchecked ~post_id =
  let store = backend () in
      Board.read_post_and_comments store ~post_id
      |> Result.map_error Board.board_error_of_read_error

let get_post_and_comments ~reader ~post_id =
  let store = backend () in
  match Board.observe_post_and_comments store ~post_id
        |> Result.map_error Board.board_error_of_read_error with
  | Ok (post, observation) ->
    if not (Board_access.can_read ~reader post) then Error (Board.Post_not_found post_id)
    else (match observation.completeness with
      | Board.Source_complete -> Ok (post, observation.comments)
      | Board.Source_incomplete error ->
        Error (Board.board_error_of_read_error (Board.Read_source_unavailable error)))
  | Error _ as error -> error

(* One owner for board-operation failure lines. A re-vote is a routine
   re-click at debug, a missing target is an ordinary race at info, and
   only malformed input, IO, auth, duplicate-create and recipient-lookup problems warn. *)
let log_board_error ~op ~ids (e : Board_types.board_error) =
  (match e with
   | Board_types.Already_voted _ ->
       Log.BoardLog.debug
   | Board_types.Post_not_found _ | Board_types.Comment_not_found _ ->
       Log.BoardLog.info
   | Board_types.Invalid_id _ | Board_types.Io_error _ | Board_types.Validation_error _
   | Board_types.Already_exists _ | Board_types.Unauthorized _
   | Board_types.Recipient_lookup_failed _ -> Log.BoardLog.warn)
    "board %s failed: %s: %s" op ids (Board_types.show_board_error e)

(* One owner for skipped board-signal lines: the write landed, only the
   keeper-facing signal was dropped because its follow-up read failed. *)
let log_signal_skip ~op ~read ~id detail =
  Log.BoardLog.warn "board %s skipped: %s failed for %s: %s" op read id detail

let add_comment_with_unresolved ~reader ~post_id ~author ~content ?parent_id
    ?(ttl_hours = Board.Limits.default_ttl_hours) () =
  let store = backend () in
      (match
         Board.add_comment_with_audience store ~reader ~lookup:(recipient_lookup ())
           ~post_id ~author ~content ?parent_id ~ttl_hours ()
       with
      | Ok creation ->
          let comment = creation.comment in
          let cid = Board.Comment_id.to_string comment.id in
          let auth = Board.Agent_id.to_string comment.author in
          (match Board.read_post store ~post_id with
          | Ok post ->
              emit_board_signal
                { signal =
                    { kind =
                        Board_comment_added
                          { comment_id = comment.id; parent_id = comment.parent_id }
                    ; post_id
                    ; author = auth
                    ; title = post.title
                    ; content
                    ; hearth = post.hearth
                    ; updated_at = Some post.updated_at
                    }
                ; audience = creation.audience
                }
          | Error e ->
              log_signal_skip ~op:"signal" ~read:"read_post" ~id:post_id
                (Board_types.show_board_read_error e));
          emit_board_sse_event ~visibility:(visibility_of_post store ~post_id)
            (Comment_added { post_id; comment_id = cid; author = auth });
          Ok (comment, creation.unresolved)
      | Error _ as err -> err)

let add_comment ~reader ~post_id ~author ~content ?parent_id ?ttl_hours () =
  add_comment_with_unresolved ~reader ~post_id ~author ~content ?parent_id ?ttl_hours ()
  |> Result.map fst

let current_vote_for_post ~reader ~voter ~post_id =
  match get_post ~reader ~post_id with
  | Error _ as error -> error
  | Ok _ -> let store = backend () in Board.current_vote_for_post store ~voter ~post_id

(* A vote is thread activity the voted-on author can act on, so it travels
   the same hook as comments and reactions. The signal's [author] is the
   voter, the actor; [target_author] names whose writing was voted on, so the
   keeper router can wake exactly that lane without a second store read. *)
let emit_vote_board_signal ~target ~target_author ~voter ~direction
    (post : Board.post) =
  emit_board_signal
    { signal =
        { kind = Board_vote_cast { target; target_author; voter; direction }
        ; post_id = Board.Post_id.to_string post.id
        ; author = voter
        ; title = post.title
        ; content = post.body
        ; hearth = post.hearth
        ; updated_at = Some post.updated_at
        }
    ; audience = Board.audience_for_vote
    }

let vote ~reader ~voter ~post_id ~direction =
  let result =
    let store = backend () in
        (match Board.vote store ~reader ~voter ~post_id ~direction with
         | Ok _score as ok ->
             (match Board.read_post store ~post_id with
              | Ok post ->
                  emit_vote_board_signal
                    ~target:(Vote_on_post (Board.Post_id.to_string post.id))
                    ~target_author:(Board.Agent_id.to_string post.author)
                    ~voter ~direction post
              | Error e ->
                  log_signal_skip ~op:"vote signal" ~read:"read_post" ~id:post_id
                    (Board_types.show_board_read_error e));
             ok
         | Error _ as err -> err)
  in
  (match result with
   | Ok _score ->
       let store = backend () in
       emit_board_sse_event ~visibility:(visibility_of_post store ~post_id)
         (Post_voted { post_id; voter; direction })
   | Error e ->
       log_board_error ~op:"vote"
         ~ids:(Printf.sprintf "post_id=%s voter=%s" post_id voter) e);
  result

let current_vote_for_comment ~reader ~voter ~comment_id =
  let store = backend () in
  match Board.get_comment store ~comment_id with
  | Error _ as error -> error
  | Ok comment ->
    match get_post ~reader ~post_id:(Board.Post_id.to_string comment.post_id) with
    | Error _ -> Error (Board.Comment_not_found comment_id)
    | Ok _ -> Board.current_vote_for_comment store ~voter ~comment_id

let vote_comment ~reader ~voter ~comment_id ~direction =
  let result =
    let store = backend () in
        (match Board.vote_comment store ~reader ~voter ~comment_id ~direction with
         | Ok _score as ok ->
             (match Board.get_comment store ~comment_id with
              | Error e ->
                  log_signal_skip ~op:"comment vote signal" ~read:"get_comment"
                    ~id:comment_id (Board_types.show_board_error e)
              | Ok comment ->
                  let post_id = Board.Post_id.to_string comment.post_id in
                  (match Board.read_post store ~post_id with
                   | Ok post ->
                       emit_vote_board_signal
                         ~target:
                           (Vote_on_comment (Board.Comment_id.to_string comment.id))
                         ~target_author:(Board.Agent_id.to_string comment.author)
                         ~voter ~direction post
                   | Error e ->
                       log_signal_skip ~op:"comment vote signal" ~read:"read_post"
                         ~id:post_id (Board_types.show_board_read_error e)));
             ok
         | Error _ as err -> err)
  in
  (match result with
   | Ok _score ->
       let store = backend () in
       let visibility = match Board.get_comment store ~comment_id with
         | Ok comment -> visibility_of_post store ~post_id:(Board.Post_id.to_string comment.post_id)
         | Error _ -> None in
       emit_board_sse_event ~visibility
         (Comment_voted { comment_id; voter; direction })
   | Error e ->
       log_board_error ~op:"vote_comment"
         ~ids:(Printf.sprintf "comment_id=%s voter=%s" comment_id voter) e);
  result

let post_for_reaction_target store ~target_type ~target_id =
  match target_type with
  | Board.Reaction_post ->
      Board.read_post store ~post_id:target_id
      |> Result.map_error Board.board_error_of_read_error
  | Board.Reaction_comment ->
      (match Board.get_comment store ~comment_id:target_id with
       | Error _ as err -> err
       | Ok comment ->
           let post_id = Board.Post_id.to_string comment.post_id in
           Board.read_post store ~post_id
           |> Result.map_error Board.board_error_of_read_error)

let readable_reaction_target ~reader ~target_type ~target_id =
  let store = backend () in
  match post_for_reaction_target store ~target_type ~target_id with
  | Ok post when Board_access.can_read ~reader post -> Ok post
  | Ok _ ->
    Error (match target_type with
      | Board.Reaction_post -> Board.Post_not_found target_id
      | Board.Reaction_comment -> Board.Comment_not_found target_id)
  | Error _ as error -> error

let require_readable_target ~reader ~target_type ~target_id =
  readable_reaction_target ~reader ~target_type ~target_id
  |> Result.map (fun _post -> ())

let emit_reaction_board_signal store (toggled : Board.reaction_toggle_result) =
  match
    Board.read_post store ~post_id:(Board.Post_id.to_string toggled.post_id)
    |> Result.map_error Board.board_error_of_read_error
  with
  | Ok post ->
      emit_board_signal
        { signal =
            { kind =
                Board_reaction_changed
                  { target_type = toggled.target_type
                  ; target_id = toggled.target_id
                  ; user_id = toggled.user_id
                  ; emoji = toggled.emoji
                  ; reacted = toggled.reacted
                  }
            ; post_id = Board.Post_id.to_string post.id
            ; author = toggled.user_id
            ; title = post.title
            ; content = post.body
            ; hearth = post.hearth
            ; updated_at = Some post.updated_at
            }
        ; audience = Board.audience_for_reaction
        }
  | Error e ->
      Log.BoardLog.warn
        "board reaction signal skipped: target=%s:%s user=%s emoji=%s: %s"
        (Board.reaction_target_type_to_string toggled.target_type)
        toggled.target_id toggled.user_id toggled.emoji
        (Board_types.show_board_error e)

type reaction_write =
  { post_id : Board.Post_id.t
  ; reaction : Board.reaction_toggle_result
  }

let toggle_reaction ~reader ~target_type ~target_id ~user_id ~emoji =
  match readable_reaction_target ~reader ~target_type ~target_id with
  | Error _ as error -> error
  | Ok _ ->
  let result =
    let store = backend () in
        (match Board.toggle_reaction store ~reader ~target_type ~target_id ~user_id ~emoji with
         | Ok toggled as ok ->
             emit_reaction_board_signal store toggled;
             ok
         | Error _ as err -> err)
  in
  (match result with
   | Ok toggled ->
       let store = backend () in
       let visibility = match Board.read_post store ~post_id:(Board.Post_id.to_string toggled.post_id) with
         | Ok post -> Some post.visibility
         | Error _ -> None in
       emit_board_sse_event ~visibility
         (Reaction_changed
            {
              target_type = toggled.target_type;
              target_id = toggled.target_id;
              user_id = toggled.user_id;
              emoji = toggled.emoji;
              reacted = toggled.reacted;
            })
   | Error e ->
       log_board_error ~op:"reaction"
         ~ids:(Printf.sprintf "target=%s:%s user=%s emoji=%s"
           (Board.reaction_target_type_to_string target_type)
           target_id user_id emoji) e);
  Result.map (fun (reaction : Board.reaction_toggle_result) -> { post_id = reaction.post_id; reaction }) result

let list_reactions ~reader ~target_type ~target_id ?user_id () =
  match require_readable_target ~reader ~target_type ~target_id with
  | Error _ as error -> error
  | Ok () -> let store = backend () in Board.list_reactions store ~target_type ~target_id ?user_id ()

let list_reactions_batch ~reader ~targets ?user_id () =
  let rec visible acc = function
    | [] -> Ok (List.rev acc)
    | ((target_type, target_id) as target) :: rest ->
      (match require_readable_target ~reader ~target_type ~target_id with
       | Ok () -> visible (target :: acc) rest
       | Error (Board.Invalid_id _ | Board.Post_not_found _ | Board.Comment_not_found _
                | Board.Unauthorized _) -> visible acc rest
       | Error ((Board.Io_error _ | Board.Recipient_lookup_failed _ | Board.Validation_error _
                 | Board.Already_voted _ | Board.Already_exists _) as error) -> Error error)
  in
  let open Result.Syntax in
  let* targets = visible [] targets in
  let store = backend () in
  Board.list_reactions_batch store ~targets ?user_id ()

let post_visible_in_store ~reader store post_id =
  match Hashtbl.find_opt store.Board.posts post_id with
  | Some post -> Board_access.can_read ~reader post
  | None -> false

let stats ~reader () =
  let store = backend () in
  Board.with_lock store (fun () ->
    let now = Time_compat.now () in
    let post_count, expired_posts = Hashtbl.fold (fun _ (post : Board.post) (count, expired) ->
      if Board_access.can_read ~reader post then
        count + 1, expired + (if post.expires_at > 0. && post.expires_at < now then 1 else 0)
      else count, expired) store.Board.posts (0, 0) in
    let comment_count = Hashtbl.fold (fun _ (comment : Board.comment) count ->
      if post_visible_in_store ~reader store (Board.Post_id.to_string comment.post_id)
      then count + 1 else count) store.Board.comments 0 in
    `Assoc ["post_count", `Int post_count; "comment_count", `Int comment_count;
      "expired_pending", `Int expired_posts; "last_sweep", `Float store.last_sweep;
      "backend", `String "jsonl"])

let list_comments_unchecked ?(limit = 1000) () =
  let store = backend () in Board.list_comments store ~limit ()

let list_comments ~reader ?(limit = 1000) () =
  let store = backend () in
  let comments = Board.list_comments store ~limit:max_int () in
  Board.with_lock store (fun () ->
    comments |> List.filter (fun (comment : Board.comment) ->
      post_visible_in_store ~reader store (Board.Post_id.to_string comment.post_id))
    |> Board.take limit)

module Reader_counts = Map.Make (String)

let list_hearths ~reader ?(exclude_system = false) ?(exclude_automation = false) () =
  let store = backend () in
  Board.with_lock store (fun () ->
    let counts = Hashtbl.fold (fun _ (post : Board.post) counts ->
      if Board_access.can_read ~reader post
         && Board.post_matches_filters ~exclude_system ~exclude_automation post then
        match post.hearth with
        | None -> counts
        | Some hearth ->
          let count = match Reader_counts.find_opt hearth counts with None -> 0 | Some count -> count in
          Reader_counts.add hearth (count + 1) counts
      else counts) store.Board.posts Reader_counts.empty in
    Reader_counts.bindings counts |> List.sort (fun (a, x) (b, y) ->
      let c = Int.compare y x in if c = 0 then String.compare a b else c))

let set_thread_id ~post_id ~thread_id =
  let store = backend () in
    write_post ~visibility:(visibility_of_post store ~post_id) ~post_id Post_thread_set (fun post_id ->
      Board.set_thread_id store ~post_id ~thread_id)

let set_pinned ~post_id ~pinned =
  let store = backend () in
    write_post ~visibility:(visibility_of_post store ~post_id) ~post_id (if pinned then Post_pinned else Post_unpinned) (fun post_id ->
      Board.set_pinned store ~post_id ~pinned)

let set_closed ~post_id ~closed_by ~successor ~summary () =
  let store = backend () in
    write_post ~visibility:(visibility_of_post store ~post_id) ~post_id Post_closed (fun post_id ->
      Board.set_closed store ~post_id ~closed_by ~successor ~summary ())

let reopen ~post_id =
  let store = backend () in
    write_post ~visibility:(visibility_of_post store ~post_id) ~post_id Post_reopened (fun post_id -> Board.reopen store ~post_id)

let delete_post ~authorization ~post_id =
  let store = backend () in
  let open Result.Syntax in
  let* pid = Board.Post_id.of_string post_id in
  let post_id = Board.Post_id.to_string pid in
  let visibility = visibility_of_post store ~post_id in
  match Board.delete_post store ~authorization ~post_id with
  | Ok ((Board.Durable_deletion | Board.Deletion_persistence_pending _) as outcome) ->
    emit_board_sse_event ~visibility (Post_changed { post_id; change = Post_deleted });
    Ok outcome
  | Ok (Board.Deletion_decision_pending _) as pending -> pending
  | Error _ as refused -> refused

let search ~reader ~query ~limit =
  let store = backend () in
      let query_lower = String.lowercase_ascii query in
      let matches_str s =
        String_util.contains_substring (String.lowercase_ascii s) query_lower
      in
      let predicate (p : Board.post) =
        matches_str p.title
        || matches_str p.body
        || matches_str (Board.Agent_id.to_string p.author)
        || (match p.hearth with Some h -> matches_str h | None -> false)
      in
      Board.search_posts store ~predicate:(fun post -> Board_access.can_read ~reader post && predicate post) ~limit

let search_unchecked ~query ~limit = search ~reader:Board_access.Operator ~query ~limit

let flush () =
  match Atomic.get backend_state with
  | Active (store, _, _) -> Board.flush_dirty store
  | Uninitialized -> ()

let karma_score_for_direction = Board.karma_score_for_direction

let get_karma_ledger ~reader ?agent ?(limit = max_int) () =
  let store = backend () in
  let events = Board.build_karma_ledger store in
  Board.with_lock store (fun () ->
    events |> List.filter (fun (event : Board.karma_event) ->
      let post_id = match event.target_kind with
        | Board_vote_key.Post -> Some event.target_id
        | Board_vote_key.Comment ->
          Option.map (fun (comment : Board.comment) -> Board.Post_id.to_string comment.post_id)
            (Hashtbl.find_opt store.Board.comments event.target_id) in
      (match post_id with Some id -> post_visible_in_store ~reader store id | None -> false)
      && (match agent with None -> true | Some name -> String.equal name event.recipient))
    |> Board.take limit)

let get_all_karma ~reader () =
  let store = backend () in
  if Board_access.is_operator reader then Board.get_all_karma store
  else
    let index = Board.get_karma_by_post store in
    Board.with_lock store (fun () ->
      index |> List.filter_map (fun (author, posts) ->
        let score = List.fold_left (fun total (post_id, delta) ->
          if post_visible_in_store ~reader store post_id then total + delta else total) 0 posts in
        if score = 0 then None else Some (author, score))
      |> List.sort (fun (a, x) (b, y) -> let c = Int.compare y x in if c = 0 then String.compare a b else c))

let get_agent_karma ~reader ~agent_name =
  match List.assoc_opt agent_name (get_all_karma ~reader ()) with None -> 0 | Some karma -> karma

let post_to_yojson_with_karma (p : Board.post) ~author_karma =
  Board.post_to_yojson_with_karma p ~author_karma

let backend_name () =
  match Atomic.get backend_state with
  | Active (_, _, _) -> "jsonl"
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

let latest_curation_snapshot ~reader () =
  if Board_access.is_operator reader then Board_curation.latest_snapshot () else None

(** {1 SubBoard operations} *)

let sub_board_for_reader ~reader (board : Board.sub_board) =
  let store = backend () in
  Board.with_lock store (fun () ->
    let post_count = Hashtbl.fold (fun _ (post : Board.post) count ->
      if Board_access.can_read ~reader post && Option.equal String.equal post.hearth (Some board.slug)
      then count + 1 else count) store.Board.posts 0 in
    { board with post_count })

let create_sub_board ~reader ~slug ~name ~description ~owner ?members ?access () =
  let store = backend () in
      Board.create_sub_board store ~slug ~name ~description ~owner ?members ?access ()
      |> Result.map (sub_board_for_reader ~reader)

let get_sub_board ~reader ~sub_board_id =
  let store = backend () in
    Board.get_sub_board store ~sub_board_id |> Result.map (fun (board : Board.sub_board) ->
      let counts = list_hearths ~reader () in
      { board with post_count = (match List.assoc_opt board.slug counts with None -> 0 | Some count -> count) })

let list_sub_boards ~reader () =
  let store = backend () in
  Board.read_sub_boards store |> Result.map (fun boards ->
    let counts = list_hearths ~reader () in
    List.map (fun (board : Board.sub_board) ->
      { board with post_count = (match List.assoc_opt board.slug counts with None -> 0 | Some count -> count) }) boards)

let delete_sub_board ~authorization ~sub_board_id =
  let store = backend () in
  match Board.delete_sub_board store ~authorization ~sub_board_id with
  | Ok ((Board.Durable_deletion | Board.Deletion_persistence_pending _) as outcome) ->
    emit_board_sse_event ~visibility:None Board_changed;
    Ok outcome
  | Ok (Board.Deletion_decision_pending _) as pending -> pending
  | Error _ as refused -> refused

let update_sub_board ~reader ~sub_board_id ?name ?description ?members ?access () =
  let store = backend () in Board.update_sub_board store ~sub_board_id ?name ?description ?members ?access ()
      |> Result.map (sub_board_for_reader ~reader)
