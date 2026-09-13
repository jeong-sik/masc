(** JSON row decoders and persisted row loaders for board voting state. *)

include Board_core

let visibility_of_string = Board_core_classify.visibility_of_string

let has_exact_field_set ~allowed fields =
  let rec loop seen = function
    | [] -> true
    | (name, _) :: rest ->
      if List.mem name seen || not (List.mem name allowed)
      then false
      else loop (name :: seen) rest
  in
  loop [] fields
;;

let post_field_names =
  [ "id"
  ; "author"
  ; "title"
  ; "body"
  ; "post_kind"
  ; "visibility"
  ; "created_at"
  ; "updated_at"
  ; "expires_at"
  ; "votes_up"
  ; "votes_down"
  ; "reply_count"
  ; "pinned"
  ; "hearth"
  ; "thread_id"
  ; "origin"
  ; "classification_reason"
  ; "meta"
  ]
;;

let comment_field_names =
  [ "id"
  ; "post_id"
  ; "parent_id"
  ; "author"
  ; "content"
  ; "created_at"
  ; "expires_at"
  ; "votes_up"
  ; "votes_down"
  ]
;;

let required_string fields key =
  match List.assoc_opt key fields with
  | Some (`String value) -> Some value
  | None | Some _ -> None
;;

let required_float fields key =
  match List.assoc_opt key fields with
  | Some (`Float value) -> Some value
  | None | Some _ -> None
;;

let required_int fields key =
  match List.assoc_opt key fields with
  | Some (`Int value) -> Some value
  | None | Some _ -> None
;;

let required_bool fields key =
  match List.assoc_opt key fields with
  | Some (`Bool value) -> Some value
  | None | Some _ -> None
;;

let optional_string fields key =
  match List.assoc_opt key fields with
  | None -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error ()
;;

let optional_meta fields =
  match List.assoc_opt "meta" fields with
  | None -> Ok None
  | Some (`Assoc _ as meta) -> Ok (Some meta)
  | Some _ -> Error ()
;;

(* RFC-0233 §7: an emitted origin is a current typed value, not a repairable
   hint. Absent [origin] remains valid; a present malformed object rejects its
   row at the caller. *)
let post_origin_of_yojson (json : Yojson.Safe.t) : post_origin option =
  match json with
  | `Assoc fields when has_exact_field_set
      ~allowed:["turn_ref";"source";"fusion_run_id";"fusion_producer"] fields ->
    let turn_ref =
      match List.assoc_opt "turn_ref" fields with
      | None -> Ok None
      | Some (`String raw) ->
        (match Ids.Turn_ref.of_string raw with
         | Some turn_ref -> Ok (Some turn_ref)
         | None -> Error ())
      | Some _ -> Error ()
    in
    let source = optional_string fields "source" in
    let fusion_run_id = optional_string fields "fusion_run_id" in
    let fusion_producer = optional_string fields "fusion_producer" in
    (match turn_ref, source, fusion_run_id, fusion_producer with
     | Ok turn_ref, Ok source, Ok fusion_run_id, Ok fusion_producer ->
       if Option.is_none turn_ref
          && Option.is_none source
          && Option.is_none fusion_run_id
       then None
       else (match fusion_run_id, fusion_producer with
         | None, None -> Some {turn_ref; source; fusion_run_id; fusion_producer}
         | Some _, Some producer when String.trim producer <> "" ->
             Some {turn_ref; source; fusion_run_id; fusion_producer}
         | _ -> None)
     | Error (), _, _, _ | _, Error (), _, _ | _, _, Error (), _ | _, _, _, Error () -> None)
  | _ -> None
;;

let optional_origin fields =
  match List.assoc_opt "origin" fields with
  | None -> Ok None
  | Some json ->
    (match post_origin_of_yojson json with
     | Some origin -> Ok (Some origin)
     | None -> Error ())
;;

let post_of_yojson (json : Yojson.Safe.t) : post option =
  match json with
  | `Assoc fields
    when has_exact_field_set ~allowed:post_field_names fields ->
    (match
       ( required_string fields "id"
       , required_string fields "author"
       , required_string fields "title"
       , required_string fields "body"
       , required_string fields "post_kind"
       , required_string fields "visibility"
       , required_float fields "created_at"
       , required_float fields "updated_at"
       , required_float fields "expires_at"
       , required_int fields "votes_up"
       , required_int fields "votes_down"
       , required_int fields "reply_count"
       , required_bool fields "pinned"
       , optional_string fields "hearth"
       , optional_string fields "thread_id"
       , optional_string fields "classification_reason"
       , optional_meta fields
       , optional_origin fields )
     with
     | ( Some id_str
       , Some author_str
       , Some title
       , Some body
       , Some post_kind_raw
       , Some vis_str
       , Some created_at
       , Some updated_at
       , Some expires_at
       , Some votes_up
       , Some votes_down
       , Some reply_count
       , Some pinned
       , Ok hearth
       , Ok thread_id
       , Ok classification_reason
       , Ok meta_json
       , Ok origin ) ->
    let post_kind_opt =
      post_kind_of_string post_kind_raw
    in
    if Option.is_none post_kind_opt
    then
      Log.BoardLog.warn
        "dropping persisted board post %s: missing or invalid post_kind"
        id_str;
    (match
       ( Post_id.of_string id_str
       , Agent_id.of_string author_str
       , visibility_of_string vis_str
       , post_kind_opt )
     with
     | Ok id, Ok author, Some visibility, Some post_kind ->
        let post =
          { id
          ; author
          ; title
          ; body
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
          }
        in
        if Option.equal
             String.equal
             classification_reason
             (post_classification_reason post)
        then Some post
        else None
     | _ -> None)
     | _ -> None)
  | `Assoc _ | _ -> None
;;

let comment_of_yojson (json : Yojson.Safe.t) : comment option =
  match json with
  | `Assoc fields
    when has_exact_field_set ~allowed:comment_field_names fields ->
    let parent_id =
      match List.assoc_opt "parent_id" fields with
      | Some `Null -> Ok None
      | Some (`String raw) ->
        (match Comment_id.of_string raw with
         | Ok parent_id -> Ok (Some parent_id)
         | Error _ -> Error ())
      | None | Some _ -> Error ()
    in
    (match
       ( required_string fields "id"
       , required_string fields "post_id"
       , required_string fields "author"
       , required_string fields "content"
       , required_float fields "created_at"
       , required_float fields "expires_at"
       , required_int fields "votes_up"
       , required_int fields "votes_down"
       , parent_id )
     with
     | ( Some id_str
       , Some post_id_str
       , Some author_str
       , Some content
       , Some created_at
       , Some expires_at
       , Some votes_up
       , Some votes_down
       , Ok parent_id ) ->
       (match
          ( Comment_id.of_string id_str
          , Post_id.of_string post_id_str
          , Agent_id.of_string author_str )
        with
        | Ok id, Ok post_id, Ok author ->
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
     | _ -> None)
  | _ -> None
;;

(* Keep valid rows for the Board's best-effort UI, but retain failure of any
   nonempty line so evidence readers cannot infer absence from partial data. *)
let load_source_rows path ~decode ~accept =
  let first_error = ref None in
  let reject line reason =
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
  match !first_error with None -> Ok () | Some detail -> Error (path, Failure detail)

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
  store.sorted_posts_cache <- None;
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
  let path = Board_paths.store_file_path store Board_paths.Posts in
  let result = try
    if Fs_compat.exact_path_kind path = Fs_compat.Exact_missing then (
      replace_loaded_posts store []; Ok 0)
    else begin
      let t0 = Time_compat.now () in
      let now = Time_compat.now () in
      let loaded = ref 0 and retained = ref [] in
      let parsed = load_source_rows path ~decode:post_of_yojson ~accept:(fun p ->
           if Float.compare p.expires_at 0.0 = 0
                  || Float.compare p.expires_at now > 0 then begin
             retained := p :: !retained;
             Hashtbl.replace store.posts (Post_id.to_string p.id) p;
             (* RFC-0233 §7: rebuild the origin indexes on load (derive-on-load,
                mirroring comments_by_post below) so find_post_by_turn_ref /
                find_post_by_run_id survive a restart without a second persisted
                SSOT that could drift from the post rows. *)
             index_post_origin store p;
             incr loaded
           end) in
      (match parsed with Ok () -> replace_loaded_posts store (List.rev !retained) | Error _ -> ());
      store.post_count := Hashtbl.length store.posts;
      let elapsed = Time_compat.now () -. t0 in
      if !loaded > 0
      then Log.BoardLog.info "loaded %d posts from %s in %.3fs" !loaded path elapsed
      else Log.BoardLog.debug "loaded 0 posts from %s in %.3fs" path elapsed;
      Result.map (fun () -> !loaded) parsed
    end
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Error (path, e)
  in
  record_load_result (fun result -> store.posts_load_result <- result) result
;;

let load_persisted_comments store =
  let path = Board_paths.store_file_path store Board_paths.Comments in
  let result = try
    if Fs_compat.exact_path_kind path = Fs_compat.Exact_missing then (
      replace_loaded_comments store []; Ok 0)
    else begin
      let t0 = Time_compat.now () in
      let now = Time_compat.now () in
      let loaded = ref 0 and retained = ref [] in
      let parsed = load_source_rows path ~decode:comment_of_yojson ~accept:(fun c ->
           if Float.compare c.expires_at 0.0 = 0
                  || Float.compare c.expires_at now > 0 then begin
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
             incr loaded
           end) in
      (match parsed with Ok () -> replace_loaded_comments store (List.rev !retained) | Error _ -> ());
      let elapsed = Time_compat.now () -. t0 in
      if !loaded > 0
      then Log.BoardLog.info "loaded %d comments from %s in %.3fs" !loaded path elapsed
      else Log.BoardLog.debug "loaded 0 comments from %s in %.3fs" path elapsed;
      Result.map (fun () -> !loaded) parsed
    end
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Error (path, e)
  in
  record_load_result (fun result -> store.comments_load_result <- result) result
;;
