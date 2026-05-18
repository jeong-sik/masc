(** JSON row decoders and persisted row loaders for board voting state. *)

include Board_core

let post_meta_json_persistence_surface = "board_post_meta_json"

let record_post_meta_json_read_drop () =
  Prometheus.inc_counter
    Prometheus.metric_persistence_read_drops
    ~labels:
      [
        ("surface", post_meta_json_persistence_surface);
        ("reason", Safe_ops.persistence_read_drop_reason_invalid_payload);
      ]
    ()
;;

let visibility_of_string = Board_core_classify.visibility_of_string

let post_of_yojson (json : Yojson.Safe.t) : post option =
  match
    ( Safe_ops.json_string_opt "id" json
    , Safe_ops.json_string_opt "author" json
    , Safe_ops.json_string_opt "content" json
    , Safe_ops.json_string_opt "visibility" json
    , Safe_ops.json_float_opt "created_at" json
    , Safe_ops.json_float_opt "expires_at" json )
  with
  | ( Some id_str
    , Some author_str
    , Some content
    , Some vis_str
    , Some created_at
    , Some expires_at ) ->
    let title_opt = Safe_ops.json_string_opt "title" json in
    let body_opt = Safe_ops.json_string_opt "body" json in
    (* Backward compat: default updated_at to created_at if missing *)
    let updated_at =
      Safe_ops.json_float_opt "updated_at" json |> Option.value ~default:created_at
    in
    let votes_up = Safe_ops.json_int ~default:0 "votes_up" json in
    let votes_down = Safe_ops.json_int ~default:0 "votes_down" json in
    let reply_count = Safe_ops.json_int ~default:0 "reply_count" json in
    let hearth = Safe_ops.json_string_opt "hearth" json in
    let thread_id = Safe_ops.json_string_opt "thread_id" json in
    let post_kind_opt =
      match Safe_ops.json_string_opt "post_kind" json with
      | Some raw -> post_kind_of_string raw
      | None -> None
    in
    let meta_json =
      match Safe_ops.json_member_opt "meta" json with
      | Some (`Assoc _ as meta) -> Some meta
      | Some _ | None ->
        (match Safe_ops.json_string_opt "meta_json" json with
         | Some raw ->
           (try Some (Yojson.Safe.from_string raw) with
            | Yojson.Json_error _ ->
              record_post_meta_json_read_drop ();
              None)
         | None -> None)
    in
    (match
       ( Post_id.of_string id_str
       , Agent_id.of_string author_str
       , visibility_of_string vis_str )
     with
     | Ok id, Ok author, Some visibility ->
       let resolved_kind =
         match post_kind_opt with
         | Some kind -> kind
         | None ->
           legacy_migrate_post_kind
             ~author:author_str
             ~meta_json
             ~visibility
             ~expires_at
             ~hearth
       in
       (match
          normalize_post_payload
            ~content
            ?title:title_opt
            ?body:body_opt
            ~post_kind:resolved_kind
            ?meta_json
            ()
        with
        | Error (Board_core_payload.Meta_not_assoc _) ->
          (* Row-level malformed meta_json: drop the row. The legacy
             code path silently coerced the same payload to an empty
             meta object at board_core_payload.ml:73, persisting a
             "successful" row with the original meta vaporised. We
             now reject the row outright so callers see the load
             count drop instead of an invisible data shape change. *)
          None
        | Ok (title, body, post_kind, meta_json) ->
          Some
            { id
            ; author
            ; title
            ; body
            ; content = body
            ; post_kind
            ; meta_json
            ; visibility
            ; created_at
            ; updated_at
            ; expires_at
            ; votes_up
            ; votes_down
            ; reply_count
            ; hearth
            ; thread_id
            })
     | _ -> None)
  | _ -> None
;;

let comment_of_yojson (json : Yojson.Safe.t) : comment option =
  match
    ( Safe_ops.json_string_opt "id" json
    , Safe_ops.json_string_opt "post_id" json
    , Safe_ops.json_string_opt "author" json
    , Safe_ops.json_string_opt "content" json
    , Safe_ops.json_float_opt "created_at" json
    , Safe_ops.json_float_opt "expires_at" json )
  with
  | ( Some id_str
    , Some post_id_str
    , Some author_str
    , Some content
    , Some created_at
    , Some expires_at ) ->
    let parent_id_opt = Safe_ops.json_string_opt "parent_id" json in
    let votes_up = Safe_ops.json_int ~default:0 "votes_up" json in
    let votes_down = Safe_ops.json_int ~default:0 "votes_down" json in
    (match
       ( Comment_id.of_string id_str
       , Post_id.of_string post_id_str
       , Agent_id.of_string author_str )
     with
     | Ok id, Ok post_id, Ok author ->
       let parent_id =
         match parent_id_opt with
         | Some s ->
           (match Comment_id.of_string s with
            | Ok cid -> Some cid
            | _ -> None)
         | None -> None
       in
       Some
         { id
         ; post_id
         ; parent_id
         ; author
         ; content
         ; created_at
         ; expires_at
         ; votes_up
         ; votes_down
         }
     | _ -> None)
  | _ -> None
;;

let load_persisted_posts store =
  let path = persist_path () in
  if Fs_compat.file_exists path
  then
    try
      let now = Time_compat.now () in
      let loaded = ref 0 in
      let lines = Fs_compat.load_jsonl path in
      List.iter
        (fun json ->
           match post_of_yojson json with
           | Some p
             when Float.compare p.expires_at 0.0 = 0
                  || Float.compare p.expires_at now > 0 ->
             Hashtbl.replace store.posts (Post_id.to_string p.id) p;
             incr loaded
           | _ -> ())
        lines;
      store.post_count := Hashtbl.length store.posts;
      if !loaded > 0
      then Log.BoardLog.info "loaded %d posts from %s" !loaded path
      else Log.BoardLog.debug "loaded 0 posts from %s" path
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Log.BoardLog.error "load posts failed: %s" (Printexc.to_string e)
;;

let load_persisted_comments store =
  let path = comments_path () in
  if Fs_compat.file_exists path
  then
    try
      let now = Time_compat.now () in
      let loaded = ref 0 in
      let lines = Fs_compat.load_jsonl path in
      List.iter
        (fun json ->
           match comment_of_yojson json with
           | Some c
             when Float.compare c.expires_at 0.0 = 0
                  || Float.compare c.expires_at now > 0 ->
             let cid = Comment_id.to_string c.id in
             Hashtbl.replace store.comments cid c;
             (* Build comments_by_post index *)
             let post_key = Post_id.to_string c.post_id in
             let existing =
               Hashtbl.find_opt store.comments_by_post post_key
               |> Option.value ~default:[]
             in
             let indexed =
               if List.exists (String.equal cid) existing then existing else cid :: existing
             in
             Hashtbl.replace store.comments_by_post post_key indexed;
             incr loaded
           | _ -> ())
        lines;
      if !loaded > 0
      then Log.BoardLog.info "loaded %d comments from %s" !loaded path
      else Log.BoardLog.debug "loaded 0 comments from %s" path
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Log.BoardLog.error "load comments failed: %s" (Printexc.to_string e)
;;
