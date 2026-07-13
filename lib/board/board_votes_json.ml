(** JSON row decoders and persisted row loaders for board voting state. *)

include Board_core

let record_post_meta_json_read_drop () =
  Board_metrics_hooks.inc_persistence_read_drop
    ~surface:Board_metrics_hooks.Board_post_meta_json
    ~reason:Read_drop_reason.Invalid_payload
;;

let visibility_of_string = Board_core_classify.visibility_of_string

(* RFC-0233 §7: decode the typed post origin. Parse, don't repair — an absent
   [origin], a non-object value, or a malformed sub-field all degrade to [None]
   (per-field for the sub-fields), NEVER dropping the row: origin is provenance
   metadata, not load-bearing identity (contrast the [meta] row-drop below).
   [Ids.Turn_ref.of_string] is total and returns [None] on a malformed join
   key. An all-[None] origin decodes to [None] (no empty record carried). *)
let post_origin_of_yojson (json : Yojson.Safe.t) : post_origin option =
  match json with
  | `Assoc _ ->
    let turn_ref =
      match Safe_ops.json_string_opt "turn_ref" json with
      | Some s -> Ids.Turn_ref.of_string s
      | None -> None
    in
    let source = Safe_ops.json_string_opt "source" json in
    let fusion_run_id = Safe_ops.json_string_opt "fusion_run_id" json in
    (match turn_ref, source, fusion_run_id with
     | None, None, None -> None
     | _ -> Some { turn_ref; source; fusion_run_id })
  | _ -> None
;;

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
    (* Missing on legacy rows persisted before the pin field existed -> default false. *)
    let pinned = Safe_ops.json_bool ~default:false "pinned" json in
    let post_kind_opt =
      match Safe_ops.json_string_opt "post_kind" json with
      | Some raw -> post_kind_of_string raw
      | None -> None
    in
    if Option.is_none post_kind_opt
    then
      Log.BoardLog.warn
        "dropping persisted board post %s: missing or invalid post_kind"
        id_str;
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
    let origin =
      match Safe_ops.json_member_opt "origin" json with
      | Some o -> post_origin_of_yojson o
      | None -> None
    in
    (match
       ( Post_id.of_string id_str
       , Agent_id.of_string author_str
       , visibility_of_string vis_str
       , post_kind_opt )
     with
     | Ok id, Ok author, Some visibility, Some post_kind ->
       (match
          normalize_post_payload
            ~content
            ?title:title_opt
            ?body:body_opt
            ~post_kind
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
            ; pinned
            ; hearth
            ; thread_id
            ; origin
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
  if not (Fs_compat.file_exists path)
  then Ok 0
  else
    try
      let t0 = Time_compat.now () in
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
             (* RFC-0233 §7: rebuild the origin indexes on load (derive-on-load,
                mirroring comments_by_post below) so find_post_by_turn_ref /
                find_post_by_run_id survive a restart without a second persisted
                SSOT that could drift from the post rows. *)
             index_post_origin store p;
             incr loaded
           | _ -> ())
        lines;
      store.post_count := Hashtbl.length store.posts;
      let elapsed = Time_compat.now () -. t0 in
      if !loaded > 0
      then Log.BoardLog.info "loaded %d posts from %s in %.3fs" !loaded path elapsed
      else Log.BoardLog.debug "loaded 0 posts from %s in %.3fs" path elapsed;
      Ok !loaded
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Error (path, e)
;;

let load_persisted_comments store =
  let path = comments_path () in
  if not (Fs_compat.file_exists path)
  then Ok 0
  else
    try
      let t0 = Time_compat.now () in
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
      let elapsed = Time_compat.now () -. t0 in
      if !loaded > 0
      then Log.BoardLog.info "loaded %d comments from %s in %.3fs" !loaded path elapsed
      else Log.BoardLog.debug "loaded 0 comments from %s in %.3fs" path elapsed;
      Ok !loaded
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Error (path, e)
;;
