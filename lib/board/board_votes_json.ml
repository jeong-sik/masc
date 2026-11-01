(** JSON row decoders and persisted row loaders for board voting state. *)

include Board_core

let visibility_of_string = Board_core_classify.visibility_of_string

let post_of_yojson = Board_core_json.post_of_yojson
let comment_of_yojson = Board_core_json.comment_of_yojson

(* Keep valid rows for the Board's best-effort UI, but retain failure of any
   nonempty line so evidence readers cannot infer absence from partial data. *)
let load_source_rows path ~decode ~accept =
  let first_error = ref None in
  let rejected = ref 0 in
  let reject line reason =
    incr rejected;
    if Option.is_none !first_error then
      first_error := Some (Printf.sprintf "%s: line %d: %s" path line reason) in
  Fs_compat.load_file path |> String.split_on_char '\n'
  |> List.iteri (fun index text ->
    if String.trim text <> "" then
      match Yojson.Safe.from_string text with
      | json -> (match decode json with
        | Some row -> accept row
        | None -> reject (index + 1) "invalid persisted row schema")
      | exception Yojson.Json_error _ -> reject (index + 1) "invalid JSON");
  match !first_error with
  | None -> Ok ()
  | Some detail ->
    let detail =
      if !rejected > 1
      then Printf.sprintf "%s (%d rows rejected)" detail !rejected
      else detail in
    Error (path, Failure detail)

(* One owner for every "loaded N <noun>" line. A parse failure keeps the
   rows accepted so far, so the Error arm says partial load at warn: the
   old info line read as a clean load. *)
let log_loaded ~noun ~loaded ~path ~elapsed = function
  | Ok () ->
    if loaded > 0
    then Log.BoardLog.info "loaded %d %s from %s in %.3fs" loaded noun path elapsed
    else Log.BoardLog.debug "loaded 0 %s from %s in %.3fs" noun path elapsed
  | Error (_, cause) ->
    let reason =
      match cause with Failure detail -> detail | _ -> Printexc.to_string cause in
    Log.BoardLog.warn "partial load: kept %d %s from %s in %.3fs: %s"
      loaded noun path elapsed reason

let record_load_result set result =
  set (match result with Ok _ -> Ok ()
    | Error (path, cause) -> Error (path ^ ": " ^ Printexc.to_string cause));
  result

let replace_loaded_posts store posts =
  Hashtbl.clear store.posts;
  Hashtbl.clear store.posts_by_turn_ref;
  Hashtbl.clear store.posts_by_run_id;
  List.iter (fun (post : post) ->
    Hashtbl.replace store.posts (Post_id.to_string post.id) post;
    index_post_origin store post) posts;
  store.post_count := Hashtbl.length store.posts;
  rebuild_hot_post_index store;
  store.karma_cache <- None

let replace_loaded_comments store comments =
  Hashtbl.clear store.comments;
  Hashtbl.clear store.comments_by_post;
  List.iter (fun (comment : comment) ->
    let id = Comment_id.to_string comment.id in
    Hashtbl.replace store.comments id comment;
    let post_id = Post_id.to_string comment.post_id in
    let ids = match Hashtbl.find_opt store.comments_by_post post_id with
      | Some ids -> ids | None -> [] in
    if not (List.mem id ids) then Hashtbl.replace store.comments_by_post post_id (id :: ids)) comments;
  store.karma_cache <- None

let load_persisted_posts store =
  with_persist_lock store (fun () ->
    let path = Board_paths.persist_path store in
    let t0 = Time_compat.now () in
    let outcome = read_posts_source store in
    let result = with_lock store (fun () ->
      let result = match outcome with
        | Posts_complete { posts; _ } -> replace_loaded_posts store posts; Ok (List.length posts)
        | Posts_partial { posts; errors; _ } ->
          List.iter (fun (post : post) ->
            Hashtbl.replace store.posts (Post_id.to_string post.id) post;
            index_post_origin store post) posts;
          store.post_count := Hashtbl.length store.posts;
          rebuild_hot_post_index store;
          invalidate_post_caches store;
          Error (path, Failure (show_board_error (posts_source_failure_to_board_error (Posts_rows_rejected errors))))
        | Posts_unavailable failure ->
          Error (path, Failure (show_board_error (posts_source_failure_to_board_error failure))) in
      publish_posts_read store outcome;
      result) in
    let loaded = match outcome with Posts_complete { posts; _ } | Posts_partial { posts; _ } -> List.length posts
      | Posts_unavailable _ -> 0 in
    log_loaded ~noun:"posts" ~loaded ~path ~elapsed:(Time_compat.now () -. t0)
      (Result.map (fun _ -> ()) result);
    finish_posts_read outcome;
    result)
;;

let propagate_workspace_check = function
  | Ok () -> ()
  | Error rejection ->
    Option.iter (fun (exception_, backtrace) ->
      Board_posts_source.propagate_reserved exception_ backtrace)
      (Board_workspace_binding.raised rejection)

let load_persisted_comments store =
  let path = Board_paths.store_file_path store Board_paths.Comments in
  let workspace_check = Board_paths.check_workspace store in
  let result = match workspace_check with
    | Error rejection -> Error (path, Failure (Board_workspace_binding.rejection_to_string rejection))
    | Ok () -> try
    if Fs_compat.exact_path_kind path = Fs_compat.Exact_missing then (
      replace_loaded_comments store []; Ok 0)
    else begin
      let t0 = Time_compat.now () in
      let loaded = ref 0 and retained = ref [] in
      let parsed = load_source_rows path ~decode:comment_of_yojson ~accept:(fun c ->
             (* Retain expired targets until the sweeper can also remove
                their votes and reactions. Absence alone is not deletion. *)
             retained := c :: !retained;
             let cid = Comment_id.to_string c.id in
             Hashtbl.replace store.comments cid c;
             let post_key = Post_id.to_string c.post_id in
             let existing =
               Hashtbl.find_opt store.comments_by_post post_key
               |> Option.value ~default:[]
             in
             let indexed =
               if List.exists (String.equal cid) existing then existing else cid :: existing
             in
             Hashtbl.replace store.comments_by_post post_key indexed;
             incr loaded) in
      (match parsed with Ok () -> replace_loaded_comments store (List.rev !retained) | Error _ -> ());
      let elapsed = Time_compat.now () -. t0 in
      log_loaded ~noun:"comments" ~loaded:!loaded ~path ~elapsed parsed;
      Result.map (fun () -> !loaded) parsed
    end
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Error (path, e)
  in
  let result = record_load_result (fun result -> store.comments_load_result <- result) result in
  propagate_workspace_check workspace_check;
  result
;;
