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

type board_signal_kind = Board_signal_command.signal_kind =
  | Board_post_created
  | Board_comment_added
  | Board_reaction_changed of board_reaction_change

and board_reaction_change = Board_signal_command.reaction_change = {
  target_type : Board.reaction_target_type;
  target_id : string;
  user_id : string;
  emoji : string;
  reacted : bool;
}

type board_signal = Board_signal_command.signal = {
  kind : board_signal_kind;
  post_id : string;
  author : string;
  title : string;
  content : string;
  hearth : string option;
  updated_at : float option;
}

type board_signal_event = {
  event_id : string;
  audience : Board_signal_audience.t;
  signal : board_signal;
}

type board_signal_delivery =
  | Atomic_sink_accepted
  | Recipient_settlement_complete

let routing_mutation_mu = Eio.Mutex.create ()

let routing_delivery_claim_mu = Stdlib.Mutex.create ()
let routing_delivery_claims : (string, unit) Hashtbl.t = Hashtbl.create 64

let with_routing_mutation_lock f =
  Eio.Mutex.use_rw ~protect:true routing_mutation_mu f
;;

let claim_routing_delivery event_id =
  Stdlib.Mutex.protect routing_delivery_claim_mu (fun () ->
    if Hashtbl.mem routing_delivery_claims event_id
    then false
    else (
      Hashtbl.add routing_delivery_claims event_id ();
      true))
;;

let release_routing_delivery event_id =
  Stdlib.Mutex.protect routing_delivery_claim_mu (fun () ->
    Hashtbl.remove routing_delivery_claims event_id)
;;

let ensure_no_prepared_routing_mutation () =
  Result.bind (Board_signal_outbox.entries ()) (fun entries ->
    match
      List.find_opt
        (fun (entry : Board_signal_outbox.entry) ->
           match entry.phase with
           | Board_signal_outbox.Prepared _ -> true
           | Board_signal_outbox.Committed _ | Board_signal_outbox.Delivered _ -> false)
        entries
    with
    | None -> Ok ()
    | Some entry ->
      Error
        (Printf.sprintf
           "prior Board routing mutation remains prepared: event_id=%s"
           entry.event_id))
;;

type pending_routing_references = {
  post_ids : string list;
  comment_ids : string list;
}

let pending_routing_references () =
  Result.map
    (fun entries ->
       List.fold_left
         (fun references (entry : Board_signal_outbox.entry) ->
            let command =
              match entry.phase with
              | Board_signal_outbox.Prepared command -> Some command
              | Board_signal_outbox.Committed { mutation; _ } -> Some mutation
              | Board_signal_outbox.Delivered _ -> None
            in
            match command with
            | None -> references
            | Some command ->
              let post_id = Board_signal_command.referenced_post_id command in
              let comment_ids =
                match Board_signal_command.referenced_comment_id command with
                | None -> references.comment_ids
                | Some comment_id -> comment_id :: references.comment_ids
              in
              { post_ids = post_id :: references.post_ids; comment_ids })
         { post_ids = []; comment_ids = [] }
         entries
       |> fun references ->
       { post_ids = List.sort_uniq String.compare references.post_ids
       ; comment_ids = List.sort_uniq String.compare references.comment_ids
       })
    (Board_signal_outbox.entries ())
;;

let reject_referenced_post_mutation ~operation ~post_id mutation =
  match pending_routing_references () with
  | Error detail -> Error (Board_types.Io_error detail)
  | Ok references ->
    if List.exists (String.equal post_id) references.post_ids
    then
      Error
        (Board_types.Io_error
           (Printf.sprintf
              "Board post %s is fenced by its pending routing command: %s"
              operation
              post_id))
    else mutation ()
;;

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
          (try
             match Board.flush_dirty store with
             | Ok () -> ()
             | Error error ->
               Log.BoardLog.error "Flush failed: %s" (Board.show_board_error error)
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn -> Log.BoardLog.error "Flush failed: %s" (Printexc.to_string exn))
      | Board_types.Sweep ->
          (try
             with_routing_mutation_lock (fun () ->
               match pending_routing_references () with
               | Ok references ->
                 (match
                    Board.sweep_and_flush
                      ~protected_post_ids:references.post_ids
                      ~protected_comment_ids:references.comment_ids
                      store
                  with
                  | Ok _ -> ()
                  | Error error ->
                    Log.BoardLog.error
                      "Post-sweep flush failed: %s"
                      (Board.show_board_error error))
               | Error detail ->
                 Log.BoardLog.warn
                   "Board sweep deferred because routing references are unavailable: %s"
                   detail)
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
  | Some _ when not (Eio_context.root_switch_on_current_domain ()) ->
      (* The flusher forks a daemon on the server root switch (get_switch_opt's
         atomic fallback outside a turn). Eio.Fiber.fork_daemon ~sw is only legal
         on the switch's owning (main) domain, but ensure_flusher_actor is
         reachable from Domain_pool worker domains (board/dashboard projections).
         Defer on a non-owning domain: the flusher is a single CAS-guarded daemon
         started on the main domain at boot (mcp_server init_jsonl), so skipping
         here starts nothing twice and loses nothing. Mirrors the
         Keeper_board_attention_candidate.start_async guard (#25015). *)
      ()
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


let board_signal_hook :
    (board_signal_event -> (board_signal_delivery, string) result) option Atomic.t
  =
  Atomic.make None
;;

let recover_and_drain_callback :
    (unit -> (unit, string) result) Atomic.t
  =
  Atomic.make (fun () -> Ok ())
;;

let recover_prepared_callback :
    (unit -> (unit, string) result) Atomic.t
  =
  Atomic.make (fun () -> Ok ())
;;

let admit_routing_mutation mutation =
  match (Atomic.get recover_prepared_callback) () with
  | Error detail ->
    Error (Board_types.Io_error ("board routing-event recovery failed: " ^ detail))
  | Ok () ->
    with_routing_mutation_lock (fun () ->
      match ensure_no_prepared_routing_mutation () with
      | Error detail -> Error (Board_types.Io_error detail)
      | Ok () -> mutation ())
;;

let set_board_signal_hook hook =
  Atomic.set board_signal_hook (Some hook);
  match (Atomic.get recover_and_drain_callback) () with
  | Ok () -> ()
  | Error detail ->
    Log.BoardLog.error "Board signal outbox recovery failed: %s" detail
;;

let deliver_committed_signal event_id =
  if not (claim_routing_delivery event_id)
  then Ok ()
  else
    Fun.protect
      ~finally:(fun () -> release_routing_delivery event_id)
      (fun () ->
        Result.bind (Board_signal_outbox.entries ()) (fun entries ->
      match
        List.find_opt
          (fun (entry : Board_signal_outbox.entry) ->
             String.equal entry.event_id event_id)
          entries
      with
      | None
      | Some { phase = Board_signal_outbox.Delivered _; _ } -> Ok ()
      | Some { phase = Board_signal_outbox.Prepared _; _ } ->
        Error ("Board routing event is not committed: " ^ event_id)
      | Some
          { phase = Board_signal_outbox.Committed { mutation = payload; _ }
          ; _
          } ->
        let signal = Board_signal_command.signal payload in
        let audience = Board_signal_command.audience payload in
          match Atomic.get board_signal_hook with
          | None ->
            Log.BoardLog.info
              "Board routing event remains committed until a hook is installed: event_id=%s"
              event_id;
            Ok ()
          | Some hook ->
            let delivery =
              try hook { event_id; audience; signal } with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn -> Error (Printexc.to_string exn)
            in
            (match delivery with
             | Error detail ->
               Log.BoardLog.error
                 "Board signal hook rejected committed event: event_id=%s error=%s"
                 event_id
                 detail;
               Error detail
             | Ok delivery ->
               let settlement =
                 match delivery with
                 | Atomic_sink_accepted ->
                   Board_signal_outbox.plan_recipients
                     ~event_id
                     ~recipients:[]
                 | Recipient_settlement_complete -> Ok ()
               in
               (match Result.bind settlement (fun () ->
                  Board_signal_outbox.mark_delivered
                    ~event_id
                    ~at:(Time_compat.now ()))
                with
                | Ok () ->
                  (match Board_signal_outbox.compact_terminal () with
                   | Ok () -> Ok ()
                   | Error detail ->
                     Log.BoardLog.error
                       "Board signal outbox terminal compaction failed: event_id=%s error=%s"
                       event_id
                       detail;
                     Error detail)
                | Error detail ->
                  Log.BoardLog.error
                    "Board signal delivery acknowledgement failed: event_id=%s error=%s"
                    event_id
                    detail;
                  Error detail))))
;;

let new_routing_event_id () = Random_id.prefixed ~prefix:"bse-" ~bytes:16

let prepare_routing_event ~event_id mutation =
  Board_signal_outbox.prepare ~event_id ~command:mutation
;;

let commit_routing_event ~event_id value =
  match Board_signal_outbox.commit ~event_id with
  | Error detail ->
    (* The Board mutation has already durably succeeded.  Its Prepared row and
       preassigned entity id are sufficient for deterministic recovery. *)
    Log.BoardLog.error
      "Board mutation committed but routing-event commit failed; recovery remains pending: event_id=%s error=%s"
      event_id
      detail;
    Ok value
  | Ok () -> Ok value
;;

let drain_after_mutation () =
  match (Atomic.get recover_and_drain_callback) () with
  | Ok () -> ()
  | Error detail ->
    Log.BoardLog.error "Board signal outbox drain remains pending: %s" detail
;;

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
  Atomic.set board_sse_hook None;
  Stdlib.Mutex.protect routing_delivery_claim_mu (fun () ->
    Hashtbl.clear routing_delivery_claims)

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

let emit_post_created_sse (post : Board.post) =
  let pid = Board.Post_id.to_string post.id in
  let auth = Board.Agent_id.to_string post.author in
  emit_board_sse_event
    (Post_created
       { post_id = pid; author = auth; title = post.title;
         content = post.content; post_kind = post.post_kind;
         hearth = post.hearth })
;;

let create_post ~author ~content ?title ?body ~post_kind ?meta_json
    ?visibility ?ttl_hours ?hearth ?thread_id ?origin () =
  match backend () with
  | Jsonl store ->
    let mutation_result =
      admit_routing_mutation (fun () ->
        let event_id = new_routing_event_id () in
        let post_id = Board.Post_id.generate () in
        match
          Board.prepare_post
            store
            ~post_id
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
        | Error _ as error -> error
        | Ok post ->
          (match Board_signal_command.post post with
           | Error _ as error -> error
           | Ok command ->
          (match
             prepare_routing_event ~event_id command
           with
           | Error detail ->
             Error
               (Board_types.Io_error ("board routing-event prepare failed: " ^ detail))
           | Ok () ->
             (match Board.apply_prepared_post store post with
              | Error board_error -> Error board_error
              | Ok
                  (Board.Applied applied
                  | Board.Already_applied applied
                  | Board.Repaired_partial_apply applied) ->
                commit_routing_event ~event_id applied))))
    in
    (match mutation_result with
     | Error _ as error -> error
     | Ok post ->
       emit_post_created_sse post;
       drain_after_mutation ();
       Ok post)

let update_post ~post_id ~editor ~content ?title ?body ?new_author () =
  match backend () with
  | Jsonl store ->
    admit_routing_mutation (fun () ->
      reject_referenced_post_mutation ~operation:"edit" ~post_id (fun () ->
        Board.update_post_with_outcome
          store
          ~post_id
          ~editor
          ~content
          ?title
          ?body
          ?new_author
          ()))

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
      let fetch_limit = if needs_full_scan then Stdlib.max_int else max limit 500 in
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

let current_post_cursor () =
  match backend () with
  | Jsonl store -> Board.current_post_cursor store

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
    let mutation_result =
      admit_routing_mutation (fun () ->
        let event_id = new_routing_event_id () in
        let comment_id = Board.Comment_id.generate () in
        match
          Board.prepare_comment
            store
            ~comment_id
            ~post_id
            ~author
            ~content
            ?parent_id
            ~ttl_hours
            ()
        with
        | Error _ as error -> error
        | Ok (comment, post) ->
          (match Board.get_comments store ~post_id with
           | Error _ as error -> error
           | Ok prior_comments ->
          (match
             Board_signal_command.comment
               ~post
               ~comments:prior_comments
               comment
           with
           | Error _ as error -> error
           | Ok prepared ->
          (match prepare_routing_event ~event_id prepared with
           | Error detail ->
             Error
               (Board_types.Io_error ("board routing-event prepare failed: " ^ detail))
           | Ok () ->
             (match
                Board.apply_prepared_comment
                  store
                  ~parent_reply_count_before:post.reply_count
                  comment
              with
              | Error board_error -> Error board_error
              | Ok
                  (Board.Applied applied
                  | Board.Already_applied applied
                  | Board.Repaired_partial_apply applied) ->
                commit_routing_event ~event_id applied)))))
    in
    (match mutation_result with
     | Error _ as error -> error
     | Ok comment ->
       emit_board_sse_event
         (Comment_added
            { post_id
            ; comment_id = Board.Comment_id.to_string comment.id
            ; author = Board.Agent_id.to_string comment.author
            });
       drain_after_mutation ();
       Ok comment)

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

let post_for_reaction_target store ~target_type ~target_id =
  match target_type with
  | Board.Reaction_post -> Board.get_post store ~post_id:target_id
  | Board.Reaction_comment ->
      (match Board.get_comment store ~comment_id:target_id with
       | Error _ as err -> err
       | Ok comment ->
           let post_id = Board.Post_id.to_string comment.post_id in
           Board.get_post store ~post_id)

let toggle_reaction ~target_type ~target_id ~user_id ~emoji =
  let mutation_result =
    match backend () with
    | Jsonl store ->
      admit_routing_mutation (fun () ->
        match
          Board.prepare_reaction_toggle store ~target_type ~target_id ~user_id ~emoji
        with
        | Error _ as error -> error
        | Ok prepared ->
          let event_id = new_routing_event_id () in
          (match post_for_reaction_target store ~target_type ~target_id with
           | Error _ as error -> error
           | Ok post ->
             (match
                Board.get_comments
                  store
                  ~post_id:(Board.Post_id.to_string post.id)
              with
              | Error _ as error -> error
              | Ok comments ->
             (match
                Board_signal_command.reaction
                  ~post
                  ~comments
                  ~target_type
                  ~target_id
                  ~user_id:prepared.user_id
                  ~emoji:prepared.emoji
                  ~reacted:prepared.reacted
                  ~created_at:prepared.created_at
              with
               | Error _ as error -> error
              | Ok mutation ->
             (match prepare_routing_event ~event_id mutation with
              | Error detail ->
                Error
                  (Board_types.Io_error
                     ("board routing-event prepare failed: " ^ detail))
              | Ok () ->
                (match
                   Board.set_reaction
                     store
                     ~target_type
                     ~target_id
                     ~user_id:prepared.user_id
                     ~emoji:prepared.emoji
                     ~reacted:prepared.reacted
                     ~created_at:prepared.created_at
                 with
                 | Error board_error -> Error board_error
                 | Ok toggled -> commit_routing_event ~event_id toggled))))))
  in
  let result = mutation_result in
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
            });
       drain_after_mutation ()
   | Error e ->
       (match e with
        | Board_types.Post_not_found _ | Board_types.Comment_not_found _ ->
            Log.BoardLog.info
        | _ -> Log.BoardLog.warn)
         "board reaction failed: target=%s:%s user=%s emoji=%s: %s"
         (Board.reaction_target_type_to_string target_type)
         target_id user_id emoji (Board_types.show_board_error e));
  result

let collect_result errors = function
  | Ok () -> errors
  | Error detail -> detail :: errors
;;

let recover_prepared_entries store entries =
  let rec from_oldest_pending = function
    | [] -> []
    | ({ Board_signal_outbox.phase = Board_signal_outbox.Prepared _; _ } :: _ as pending)
    | ({ Board_signal_outbox.phase = Board_signal_outbox.Committed _; _ } :: _ as pending)
      -> pending
    | _ :: rest -> from_oldest_pending rest
  in
  let rec replay = function
    | [] -> Ok ()
    | (entry : Board_signal_outbox.entry) :: successors ->
      let command, commit_after_apply =
        match entry.phase with
        | Board_signal_outbox.Prepared command -> command, true
        | Board_signal_outbox.Committed { mutation = command; _ } -> command, false
        | Board_signal_outbox.Delivered { mutation; _ } -> mutation, false
      in
      let recovery =
        Result.bind (Board_signal_command.apply store command) (fun () ->
          if commit_after_apply
          then Board_signal_outbox.commit ~event_id:entry.event_id
          else Ok ())
      in
      (match recovery with
       | Ok () -> replay successors
       | Error detail ->
         Error
           (Printf.sprintf
              "Board routing recovery stopped at event_id=%s; \
               successors_not_attempted=%d; error=%s"
              entry.event_id
              (List.length successors)
              detail))
  in
  replay (from_oldest_pending entries)
;;

let deliver_committed_entries entries =
  List.fold_left
    (fun errors (entry : Board_signal_outbox.entry) ->
       match entry.phase with
       | Board_signal_outbox.Committed _ ->
         collect_result errors (deliver_committed_signal entry.event_id)
       | Board_signal_outbox.Prepared _
       | Board_signal_outbox.Delivered _ -> errors)
    []
    entries
;;

let recover_prepared_board_signal_outbox () =
  with_routing_mutation_lock (fun () ->
    let store = match backend () with Jsonl store -> store in
    match Board_signal_outbox.entries () with
    | Error detail -> Error detail
    | Ok initial_entries ->
      recover_prepared_entries store initial_entries)
;;

let recover_and_drain_board_signal_outbox () =
  let recovery_errors = (Atomic.get recover_prepared_callback) () in
  match recovery_errors with
  | Error _ as error -> error
  | Ok () ->
    (match Board_signal_outbox.entries () with
     | Error detail -> Error detail
     | Ok recovered_entries ->
       let delivery_errors = deliver_committed_entries recovered_entries in
       (match delivery_errors with
        | [] -> Board_signal_outbox.compact_terminal ()
        | errors -> Error (String.concat "; " (List.rev errors))))
;;

let () =
  Atomic.set recover_prepared_callback recover_prepared_board_signal_outbox;
  Atomic.set recover_and_drain_callback recover_and_drain_board_signal_outbox
;;

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
  | Jsonl store ->
    with_routing_mutation_lock (fun () ->
      reject_referenced_post_mutation ~operation:"thread update" ~post_id (fun () ->
        Board.set_thread_id store ~post_id ~thread_id))

let set_pinned ~post_id ~pinned =
  match backend () with
  | Jsonl store -> Board.set_pinned store ~post_id ~pinned

let delete_post ~post_id =
  match backend () with
  | Jsonl store ->
    with_routing_mutation_lock (fun () ->
      reject_referenced_post_mutation ~operation:"deletion" ~post_id (fun () ->
        Board.delete_post store ~post_id))

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
  | Uninitialized -> Ok ()

let sweep () =
  match backend () with
  | Jsonl store ->
    with_routing_mutation_lock (fun () ->
      match pending_routing_references () with
      | Error detail -> Error detail
      | Ok references ->
        Result.map_error
          Board.show_board_error
          (Board.sweep_and_flush
            ~protected_post_ids:references.post_ids
            ~protected_comment_ids:references.comment_ids
            store))

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
