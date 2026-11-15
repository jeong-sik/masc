(* Loaders return [(int, string * exn) result] so the caller is forced to
   acknowledge persistence-load failures.  Best-effort semantics live here
   at the call site, not hidden inside the loader bodies. *)
let log_persistence_result ~kind = function
  | Ok _ -> ()
  | Error (path, e) ->
    Log.BoardLog.error
      "load %s failed: path=%s reason=%s (continuing with best-effort partial state)"
      kind path (Printexc.to_string e)

open Board_types

let fresh store =
  let posts = match store.posts_source with
    | Posts_unobserved -> true
    | Posts_readable _ | Posts_refused _ | Posts_unsettled _ -> false in
  let comments = match store.comments_source with
    | Comments_unobserved -> true
    | Comments_readable _ | Comments_publishing _ | Comments_recovered _
    | Comments_refused _ | Comments_unsettled _ -> false in
  let votes = match store.votes_source with
    | Votes_unobserved -> true
    | Votes_readable _ | Votes_publishing _ | Votes_refused _ | Votes_unsettled _ -> false in
  let reactions = match store.reactions_source with
    | Reactions_unobserved -> true
    | Reactions_readable _ | Reactions_publishing _ | Reactions_refused _ | Reactions_unsettled _ -> false in
  let policy = match store.sub_boards_source with
    | Policy_unobserved -> true
    | Policy_readable _ | Policy_publishing _ | Policy_refused _ | Policy_unsettled _ -> false in
  let deletion = match store.deletion_state with
    | Deletion_unobserved -> true
    | Deletion_readable _ | Deletion_pending _ | Deletion_unsettled _
    | Deletion_refused _ | Deletion_projection_failed _ -> false in
  posts && comments && votes && reactions && policy && deletion

let initialize_store store =
  if not (fresh store) then Error (Io_error "Board initialization requires a fresh store.")
  else
  let failed = ref false in
  let load kind result =
    (match result with Ok _ -> () | Error _ -> failed := true);
    log_persistence_result ~kind result in
  let open Board_store_load in
  load "posts" (load_persisted_posts store);
  load "comments" (load_persisted_comments store);
  recalculate_reply_counts store;
  load "votes" (load_persisted_votes store);
  load "reactions" (load_persisted_reactions store);
  load "sub-boards" (Board_core.reload_sub_boards store);
  match Board_deletion.recover_on_initialize store with
  | Error _ as error -> error
  | Ok () ->
    if !failed then Error (Io_error "Board initialization retained unavailable sources.")
    else Ok ()

type claim =
  { binding : Board_workspace_binding.t
  ; store : store Eio.Lazy.t
  }

let new_claim binding =
  { binding
  ; store =
      Eio.Lazy.from_fun ~cancel:`Protect (fun () ->
        let store = Board_core.create_store_bound binding in
        (match initialize_store store with
         | Ok () -> ()
         | Error error ->
           Log.BoardLog.error "initialization incomplete: %s" (show_board_error error));
        store)
  }

(* The process has one store. The first caller names its BasePath; every later
   caller receives that claim and compares roots before opening anything. *)
let claimed : claim option Atomic.t = Atomic.make None

let rec claim_global binding =
  match Atomic.get claimed with
  | Some claim -> claim
  | None ->
    let candidate = new_claim binding in
    if Atomic.compare_and_set claimed None (Some candidate) then candidate
    else claim_global binding

let claimed_binding claim = claim.binding
let open_claim claim = Eio.Lazy.force claim.store

let global () =
  let claim = match Atomic.get claimed with
    | Some claim -> claim
    | None ->
      claim_global
        (Board_workspace_binding.capture ~base_path:(Board_paths.board_base_path ()))
  in
  open_claim claim

let reset_global_for_test () = Atomic.set claimed None
