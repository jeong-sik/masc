(* Board post/thread queries and public operation composition.
   Persistence and each domain service have their own owners. *)

include Board_core_persist

let read_post store ~post_id : (post, board_read_error) Result.t =
  maybe_sweep store;
  match Post_id.of_string_for_read post_id with
  | Error e -> Error e
  | Ok pid ->
    with_lock store (fun () ->
      match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
      | Some post -> Ok post
      | None -> Error (Read_post_not_found post_id))
;;

(* The source gate and the in-memory lookup share the persistence -> state
   lock order. [maybe_sweep] must run before acquiring the persistence lock. *)
let read_post_for_evidence store ~post_id : (post, board_read_error) Result.t =
  maybe_sweep store;
  match Post_id.of_string_for_read post_id with
  | Error error -> Error error
  | Ok pid ->
    with_persist_lock store (fun () ->
      match require_posts_source_readable store with
      | Error error -> Error (Read_source_unavailable error)
      | Ok () ->
        with_lock store (fun () ->
          match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
          | Some post -> Ok post
          | None -> Error (Read_post_not_found post_id)))
;;

(* RFC-0233 §7 guard #2: exact O(1) index lookups, mirroring [read_post] by
   primary key. The index is keyed on the full join string (turn_ref =
   "trace#turn", or the fusion run_id) — never a meta_json substring or a
   time-window heuristic. A miss returns [None] (no scan, no false positive). *)
let find_post_by_turn_ref store ~turn_ref : post option =
  maybe_sweep store;
  with_lock store (fun () ->
    match Hashtbl.find_opt store.posts_by_turn_ref turn_ref with
    | None -> None
    | Some pid -> Hashtbl.find_opt store.posts pid)
;;

let find_post_by_run_id store ~run_id : post option =
  maybe_sweep store;
  with_lock store (fun () ->
    match Hashtbl.find_opt store.posts_by_run_id run_id with
    | None -> None
    | Some pid -> Hashtbl.find_opt store.posts pid)
;;

let list_posts_by_run_origin store =
  maybe_sweep store;
  with_lock store (fun () ->
    Hashtbl.fold (fun _ pid posts ->
      match Hashtbl.find_opt store.posts pid with
      | Some post -> post :: posts
      | None -> posts) store.posts_by_run_id [])
  |> List.sort (fun (left : post) (right : post) ->
       match Float.compare right.created_at left.created_at with
       | 0 -> String.compare (Post_id.to_string left.id) (Post_id.to_string right.id)
       | order -> order)
;;

let observe_post_and_comments store ~post_id
  : (post * comments_observation, board_read_error) Result.t =
  maybe_sweep store;
  match Post_id.of_string_for_read post_id with
  | Error e -> Error e
  | Ok pid ->
    with_persist_lock store (fun () ->
      with_lock store (fun () ->
        let posts_source = require_posts_source_readable store in
        match Hashtbl.find_opt store.posts (Post_id.to_string pid) with
        | None ->
          (match posts_source with
           | Error error -> Error (Read_source_unavailable error)
           | Ok () -> Error (Read_post_not_found post_id))
        | Some post ->
          let observation = Board_comments.observe_comments_unlocked store pid in
          let observation = match posts_source with
            | Ok () -> observation
            | Error error -> { observation with completeness = Source_incomplete error }
          in
          Ok (post, observation)))
;;

let read_post_and_comments store ~post_id
  : (post * comment list, board_read_error) Result.t =
  match observe_post_and_comments store ~post_id with
  | Error _ as error -> error
  | Ok (post, { comments; completeness = Source_complete }) -> Ok (post, comments)
  | Ok (_, { completeness = Source_incomplete error; comments = _ }) ->
    Error (Read_source_unavailable error)
;;

let list_posts store ?(visibility_filter = None) ?hearth ?(limit = 50) () : post list =
  maybe_sweep store;
  with_lock store (fun () ->
    let limit = max 0 limit in
    if limit = 0
    then []
    else (
      let hearth_norm =
        Option.map (fun h -> String.lowercase_ascii (String.trim h)) hearth
      in
      let matches_filters (p : post) =
        (match visibility_filter with
         | None -> true
         | Some v -> p.visibility = v)
        &&
        match hearth_norm with
        | None -> true
        | Some h_norm -> Option.equal String.equal p.hearth (Some h_norm)
      in
      let rec collect seq remaining acc =
        if remaining <= 0
        then List.rev acc
        else (
          match seq () with
          | Seq.Nil -> List.rev acc
          | Seq.Cons ((key : hot_post_key), rest) ->
            (match Hashtbl.find_opt store.posts key.post_id with
             | Some post when matches_filters post ->
               collect rest (remaining - 1) (post :: acc)
             | Some _ -> collect rest remaining acc
             | None ->
               store.hot_post_index <- Hot_post_set.remove key store.hot_post_index;
               collect rest remaining acc))
      in
      collect (Hot_post_set.to_seq store.hot_post_index) limit []))
;;

let current_post_cursor store =
  maybe_sweep store;
  with_lock store (fun () ->
    match
      Hashtbl.fold
        (fun _ (candidate : post) latest ->
           match latest with
           | None -> Some candidate
           | Some (current : post) ->
             let updated_cmp =
               Stdlib.Float.compare candidate.updated_at current.updated_at
             in
             if updated_cmp > 0
                || (updated_cmp = 0
                    && String.compare
                         (Post_id.to_string candidate.id)
                         (Post_id.to_string current.id)
                       > 0)
             then Some candidate
             else latest)
        store.posts
        None
    with
    | Some post -> post.updated_at, Some (Post_id.to_string post.id)
    | None -> Time_compat.now (), None)
;;

(** Lazily traverses [store.recent_post_index] ([created_at DESC, post_id ASC])
    and collects up to [limit] posts satisfying [predicate] without sorting the
    full post table. *)
let search_posts store ~predicate ~limit : post list =
  maybe_sweep store;
  with_lock store (fun () ->
    let limit = max 0 limit in
    if limit = 0
    then []
    else (
      let rec collect seq remaining acc =
        if remaining <= 0
        then List.rev acc
        else (
          match seq () with
          | Seq.Nil -> List.rev acc
          | Seq.Cons ((key : recent_post_key), rest) ->
            (match Hashtbl.find_opt store.posts key.recent_post_id with
             | Some post when predicate post ->
               collect rest (remaining - 1) (post :: acc)
             | Some _ -> collect rest remaining acc
             | None ->
               store.recent_post_index <-
                 Recent_post_set.remove key store.recent_post_index;
               collect rest remaining acc))
      in
      collect (Recent_post_set.to_seq store.recent_post_index) limit []))
;;

(** {1 Comment Operations} *)

include Board_comments

(** {1 Reactions} *)

include Board_reactions

include Board_sub_boards
