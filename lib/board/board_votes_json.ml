(** JSON row decoders and persisted row loaders for board voting state. *)

include Board_core

let record_post_meta_json_read_drop () =
  Board_metrics_hooks.inc_persistence_read_drop
    ~surface:Board_metrics_hooks.Board_post_meta_json
    ~reason:Read_drop_reason.Invalid_payload
;;

let visibility_of_string = Board_core_classify.visibility_of_string

let assoc_member key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let has_exact_fields allowed = function
  | `Assoc fields ->
    let keys = List.map fst fields in
    List.length keys = List.length (List.sort_uniq String.compare keys)
    && List.for_all (fun key -> List.mem key allowed) keys
  | _ -> false
;;

let optional_string_field key fields =
  match List.assoc_opt key fields with
  | None -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error ()
;;

(* RFC-0233 §7: [origin] is optional, but a present value is exact.  Do not
   erase malformed provenance from a persisted current-schema row. *)
let post_origin_of_yojson (json : Yojson.Safe.t) : (post_origin, unit) result =
  match json with
  | `Assoc fields
    when has_exact_fields [ "turn_ref"; "source"; "fusion_run_id" ] json ->
    (match
       ( optional_string_field "turn_ref" fields
       , optional_string_field "source" fields
       , optional_string_field "fusion_run_id" fields )
     with
     | Ok turn_ref_raw, Ok source, Ok fusion_run_id ->
       let turn_ref_result =
         match turn_ref_raw with
         | None -> Ok None
         | Some raw ->
           (match Ids.Turn_ref.of_string raw with
            | Some turn_ref -> Ok (Some turn_ref)
            | None -> Error ())
       in
       (match turn_ref_result with
        | Ok turn_ref -> Ok { turn_ref; source; fusion_run_id }
        | Error () -> Error ())
     | _ -> Error ())
  | _ -> Error ()
;;

let post_of_yojson (json : Yojson.Safe.t) : post option =
  let current_fields =
    [ "id"
    ; "author"
    ; "title"
    ; "body"
    ; "post_kind"
    ; "content"
    ; "visibility"
    ; "created_at"
    ; "updated_at"
    ; "expires_at"
    ; "votes_up"
    ; "votes_down"
    ; "score"
    ; "reply_count"
    ; "pinned"
    ; "hearth"
    ; "thread_id"
    ; "origin"
    ; "classification_reason"
    ; "meta"
    ]
  in
  if not (has_exact_fields current_fields json)
  then None
  else
  match
    ( Safe_ops.json_string_opt "id" json
    , Safe_ops.json_string_opt "author" json
    , Safe_ops.json_string_opt "title" json
    , Safe_ops.json_string_opt "body" json
    , Safe_ops.json_string_opt "content" json
    , Safe_ops.json_string_opt "visibility" json
    , Safe_ops.json_float_opt "created_at" json
    , Safe_ops.json_float_opt "updated_at" json
    , Safe_ops.json_float_opt "expires_at" json )
  with
  | ( Some id_str
    , Some author_str
    , Some title
    , Some body
    , Some content
    , Some vis_str
    , Some created_at
    , Some updated_at
    , Some expires_at ) ->
    let votes_up = Safe_ops.json_int_opt "votes_up" json in
    let votes_down = Safe_ops.json_int_opt "votes_down" json in
    let score = Safe_ops.json_int_opt "score" json in
    let reply_count = Safe_ops.json_int_opt "reply_count" json in
    let fields =
      match json with
      | `Assoc fields -> fields
      | _ -> assert false
    in
    let hearth_result = optional_string_field "hearth" fields in
    let thread_id_result = optional_string_field "thread_id" fields in
    let classification_reason_result =
      optional_string_field "classification_reason" fields
    in
    let pinned = Safe_ops.json_bool_opt "pinned" json in
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
    let meta_json_result =
      match assoc_member "meta" json with
      | Some (`Assoc _ as meta) -> Ok (Some meta)
      | None -> Ok None
      | _ ->
        record_post_meta_json_read_drop ();
        Error ()
    in
    let origin_result =
      match assoc_member "origin" json with
      | None -> Ok None
      | Some origin_json ->
        Result.map (fun origin -> Some origin) (post_origin_of_yojson origin_json)
    in
    (match
       ( Post_id.of_string id_str
       , Agent_id.of_string author_str
       , visibility_of_string vis_str
       , post_kind_opt
       , votes_up
       , votes_down
       , score
       , reply_count
       , pinned
       , hearth_result
       , thread_id_result
       , classification_reason_result
       , meta_json_result
       , origin_result )
     with
     | ( Ok id
       , Ok author
       , Some visibility
       , Some post_kind
       , Some votes_up
       , Some votes_down
       , Some score
       , Some reply_count
       , Some pinned
       , Ok hearth
       , Ok thread_id
       , Ok classification_reason
       , Ok meta_json
       , Ok origin )
       when score = votes_up - votes_down && String.equal content body ->
       (match
          normalize_post_payload
            ~content
            ~title
            ~body
            ~post_kind
            ?meta_json
            ()
        with
        | Error (Board_core_payload.Meta_not_assoc _) ->
          (* A malformed current meta object invalidates the persisted row.
             The all-or-nothing loader converts this [None] into a typed
             reset-required backend instead of publishing a partial store. *)
          None
        | Ok (title, body, post_kind, meta_json) ->
          let post =
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
            }
          in
          if Option.equal String.equal classification_reason
               (post_classification_reason post)
          then Some post
          else None)
     | _ -> None)
  | _ -> None
;;

let comment_of_yojson (json : Yojson.Safe.t) : comment option =
  let current_fields =
    [ "id"
    ; "post_id"
    ; "parent_id"
    ; "author"
    ; "content"
    ; "created_at"
    ; "expires_at"
    ; "votes_up"
    ; "votes_down"
    ; "score"
    ]
  in
  if not (has_exact_fields current_fields json)
  then None
  else
  match
    ( Safe_ops.json_string_opt "id" json
    , Safe_ops.json_string_opt "post_id" json
    , Safe_ops.json_string_opt "author" json
    , Safe_ops.json_string_opt "content" json
    , Safe_ops.json_float_opt "created_at" json
    , Safe_ops.json_float_opt "expires_at" json
    , Safe_ops.json_int_opt "votes_up" json
    , Safe_ops.json_int_opt "votes_down" json
    , Safe_ops.json_int_opt "score" json )
  with
  | ( Some id_str
    , Some post_id_str
    , Some author_str
    , Some content
    , Some created_at
    , Some expires_at
    , Some votes_up
    , Some votes_down
    , Some score )
    when score = votes_up - votes_down ->
    let parent_id_result =
      match assoc_member "parent_id" json with
      | Some `Null -> Ok None
      | Some (`String value) -> Ok (Some value)
      | Some _ | None -> Error ()
    in
    (match
       ( Comment_id.of_string id_str
       , Post_id.of_string post_id_str
       , Agent_id.of_string author_str )
     with
     | Ok id, Ok post_id, Ok author ->
       (match parent_id_result with
        | Error () -> None
        | Ok parent_id_opt ->
          let parent_id_result =
            match parent_id_opt with
            | Some s -> Result.map Option.some (Comment_id.of_string s)
            | None -> Ok None
          in
          (match parent_id_result with
           | Error _ -> None
           | Ok parent_id ->
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
               }))
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
      let lines, malformed_lines = Fs_compat.load_jsonl_diagnostics path in
      let rec parse_current line_number acc = function
        | [] -> Ok (List.rev acc)
        | json :: rest ->
          (match post_of_yojson json with
           | None ->
             Error
               (Persistence_reset_required
                  (Printf.sprintf
                     "board posts snapshot is not current schema: path=%s row=%d"
                     path
                     line_number))
           | Some p
             when Float.compare p.expires_at 0.0 = 0
                  || Float.compare p.expires_at now > 0 ->
             parse_current (line_number + 1) (p :: acc) rest
           | Some _ -> parse_current (line_number + 1) acc rest)
      in
      (match malformed_lines with
       | count when count > 0 ->
         Error
           (Persistence_reset_required
              (Printf.sprintf
                 "board posts snapshot contains malformed JSON: path=%s malformed_rows=%d"
                 path
                 count))
       | _ ->
      match parse_current 1 [] lines with
       | Error _ as error -> error
       | Ok posts ->
         List.iter
           (fun (p : post) ->
              Hashtbl.replace store.posts (Post_id.to_string p.id) p;
              (* Derived indexes are rebuilt only after the complete canonical
                 snapshot validates, so they cannot expose partial state. *)
              index_post_origin store p)
           posts;
         store.post_count := Hashtbl.length store.posts;
         let loaded = List.length posts in
         let elapsed = Time_compat.now () -. t0 in
         if loaded > 0
         then Log.BoardLog.info "loaded %d posts from %s in %.3fs" loaded path elapsed
         else Log.BoardLog.debug "loaded 0 posts from %s in %.3fs" path elapsed;
         Ok loaded)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Error (Io_error (Printf.sprintf "load posts failed: path=%s reason=%s" path (Printexc.to_string e)))
;;

let load_persisted_comments store =
  let path = comments_path () in
  if not (Fs_compat.file_exists path)
  then Ok 0
  else
    try
      let t0 = Time_compat.now () in
      let now = Time_compat.now () in
      let lines, malformed_lines = Fs_compat.load_jsonl_diagnostics path in
      let rec parse_current line_number acc = function
        | [] -> Ok (List.rev acc)
        | json :: rest ->
          (match comment_of_yojson json with
           | None ->
             Error
               (Persistence_reset_required
                  (Printf.sprintf
                     "board comments snapshot is not current schema: path=%s row=%d"
                     path
                     line_number))
           | Some c
             when Float.compare c.expires_at 0.0 = 0
                  || Float.compare c.expires_at now > 0 ->
             parse_current (line_number + 1) (c :: acc) rest
           | Some _ -> parse_current (line_number + 1) acc rest)
      in
      (match malformed_lines with
       | count when count > 0 ->
         Error
           (Persistence_reset_required
              (Printf.sprintf
                 "board comments snapshot contains malformed JSON: path=%s malformed_rows=%d"
                 path
                 count))
       | _ ->
      match parse_current 1 [] lines with
       | Error _ as error -> error
       | Ok comments ->
         List.iter
           (fun (c : comment) ->
              let cid = Comment_id.to_string c.id in
              Hashtbl.replace store.comments cid c;
              let post_key = Post_id.to_string c.post_id in
              let existing =
                match Hashtbl.find_opt store.comments_by_post post_key with
                | Some existing -> existing
                | None -> []
              in
              let indexed =
                if List.exists (String.equal cid) existing then existing else cid :: existing
              in
              Hashtbl.replace store.comments_by_post post_key indexed)
           comments;
         let loaded = List.length comments in
         let elapsed = Time_compat.now () -. t0 in
         if loaded > 0
         then Log.BoardLog.info "loaded %d comments from %s in %.3fs" loaded path elapsed
         else Log.BoardLog.debug "loaded 0 comments from %s in %.3fs" path elapsed;
         Ok loaded)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Error (Io_error (Printf.sprintf "load comments failed: path=%s reason=%s" path (Printexc.to_string e)))
;;
