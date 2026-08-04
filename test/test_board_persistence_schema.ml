(** Board persisted-row schemas, typed origin codec, and secondary indexes.

    Pins the board-side half of the turn-identity contract:
    - {!Board_core_json.post_to_yojson} / {!Board_votes_json.post_of_yojson}
      round-trip the typed [origin] (turn_ref / source / fusion_run_id).
    - decoding accepts only the exact current writer shape; malformed origins,
      missing current fields, legacy keys, coercions, duplicates, and unknown
      fields reject the row.
    - {!Board_core.find_post_by_turn_ref} / {!find_post_by_run_id} are exact
      O(1) index lookups (RFC §7.6 guard #2/#3, no meta_json scan, no window),
      and the indexes are rebuilt on load.
    - reactions and sub-boards accept only their current writer shapes. *)

open Masc

let () = Mirage_crypto_rng_unix.use_default ()
let () = Random.self_init ()

let set_temp_base () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-board-persistence-schema-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir;
  dir
;;

(* Each test runs in its own Eio scope with a fresh persistence base path so
   the on-disk JSONL (written by [create_post], read by [load_persisted_posts])
   is isolated. Mirrors test_board_content_dedup's harness. *)
let with_eio f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  ignore (set_temp_base ());
  f ()
;;

let make_origin ?turn_ref ?source ?fusion_run_id () : Board.post_origin =
  { turn_ref; source; fusion_run_id }
;;

let create store ~origin ~content =
  match
    Board_core.create_post store ~author:"origin-test" ~content
      ~post_kind:Board.Human_post ~origin ()
  with
  | Ok post -> post
  | Error e -> Alcotest.failf "create_post failed: %s" (Board.show_board_error e)
;;

let create_no_origin store ~content =
  match
    Board_core.create_post store ~author:"origin-test" ~content
      ~post_kind:Board.Human_post ()
  with
  | Ok post -> post
  | Error e -> Alcotest.failf "create_post failed: %s" (Board.show_board_error e)
;;

let decode = Masc_board_handlers.Board_votes_json.post_of_yojson

let replace_key json key value =
  match json with
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (k, v) -> if String.equal k key then k, value else k, v)
         fields)
  | other -> other
;;

let remove_key json key =
  match json with
  | `Assoc fields ->
    `Assoc (List.filter (fun (name, _) -> not (String.equal name key)) fields)
  | other -> other
;;

let prepend_field json field =
  match json with
  | `Assoc fields -> `Assoc (field :: fields)
  | other -> other
;;

let test_codec_round_trip () =
  let store = Board_core.create_store () in
  let tr = Ids.Turn_ref.make ~trace_id:"trace-abc" ~absolute_turn:42 in
  let origin = make_origin ~turn_ref:tr ~source:"fusion" ~fusion_run_id:"fus-7" () in
  let post = create store ~origin ~content:"round trip" in
  let decoded =
    match decode (Board_core.post_to_yojson post) with
    | Some p -> p
    | None -> Alcotest.fail "encode/decode dropped the post"
  in
  match decoded.origin with
  | Some (o : Board.post_origin) ->
    Alcotest.(check (option string))
      "turn_ref preserved" (Some "trace-abc#42")
      (Option.map Ids.Turn_ref.to_string o.turn_ref);
    Alcotest.(check (option string)) "source preserved" (Some "fusion") o.source;
    Alcotest.(check (option string))
      "fusion_run_id preserved" (Some "fus-7") o.fusion_run_id
  | None -> Alcotest.fail "origin lost in round trip"
;;

let test_codec_absent_origin () =
  let store = Board_core.create_store () in
  let post = create_no_origin store ~content:"no origin" in
  Alcotest.(check bool) "post created without origin" true (Option.is_none post.origin);
  let decoded =
    match decode (Board_core.post_to_yojson post) with
    | Some p -> p
    | None -> Alcotest.fail "round trip dropped origin-less post"
  in
  Alcotest.(check bool) "absent origin decodes to None" true (Option.is_none decoded.origin)
;;

let test_malformed_origin_rejected () =
  let store = Board_core.create_store () in
  let tr = Ids.Turn_ref.make ~trace_id:"t" ~absolute_turn:1 in
  let post = create store ~origin:(make_origin ~turn_ref:tr ()) ~content:"malformed origin" in
  let json = Board_core.post_to_yojson post in
  Alcotest.(check bool)
    "non-object origin rejected"
    true
    (Option.is_none (decode (replace_key json "origin" (`Int 5))));
  let bad_origin =
    `Assoc [ "turn_ref", `String "no-separator"; "source", `String "fusion" ]
  in
  Alcotest.(check bool)
    "malformed turn_ref rejected"
    true
    (Option.is_none (decode (replace_key json "origin" bad_origin)));
  Alcotest.(check bool)
    "empty origin rejected"
    true
    (Option.is_none (decode (replace_key json "origin" (`Assoc []))))
;;

let test_current_post_schema_is_exact () =
  let store = Board_core.create_store () in
  let post = create_no_origin store ~content:"current schema" in
  let json = Board_core.post_to_yojson post in
  List.iter
    (fun field ->
       Alcotest.(check bool)
         (field ^ " is required")
         true
         (Option.is_none (decode (remove_key json field))))
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
    ];
  let rejected label candidate =
    Alcotest.(check bool) label true (Option.is_none (decode candidate))
  in
  rejected
    "legacy meta_json rejected"
    (prepend_field json ("meta_json", `String "{}"));
  rejected "unknown field rejected" (prepend_field json ("unknown", `Int 1));
  rejected "duplicate field rejected" (prepend_field json ("id", `String "duplicate"));
  rejected
    "string timestamp rejected"
    (replace_key json "updated_at" (`String "1.0"));
  rejected "float counter rejected" (replace_key json "votes_up" (`Float 0.0));
  rejected "string bool rejected" (replace_key json "pinned" (`String "false"));
  rejected "body/content mismatch rejected" (replace_key json "content" (`String "other"));
  rejected "score mismatch rejected" (replace_key json "score" (`Int 1));
  rejected
    "classification mismatch rejected"
    (prepend_field json ("classification_reason", `String "fabricated"))
;;

let test_current_comment_schema_is_exact () =
  let store = Board_core.create_store () in
  let post = create_no_origin store ~content:"comment parent" in
  let comment =
    match
      Board_core.add_comment
        store
        ~post_id:(Board.Post_id.to_string post.id)
        ~author:"commenter"
        ~content:"current comment"
        ()
    with
    | Ok comment -> comment
    | Error error -> Alcotest.failf "add_comment failed: %s" (Board.show_board_error error)
  in
  let json = Board_core.comment_to_yojson comment in
  let decode_comment = Masc_board_handlers.Board_votes_json.comment_of_yojson in
  Alcotest.(check bool)
    "canonical comment round trip"
    true
    (Option.is_some (decode_comment json));
  List.iter
    (fun field ->
       Alcotest.(check bool)
         (field ^ " is required")
         true
         (Option.is_none (decode_comment (remove_key json field))))
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
    ];
  Alcotest.(check bool)
    "malformed parent id rejected"
    true
    (Option.is_none
       (decode_comment (replace_key json "parent_id" (`String ""))));
  Alcotest.(check bool)
    "comment score mismatch rejected"
    true
    (Option.is_none (decode_comment (replace_key json "score" (`Int 1))));
  Alcotest.(check bool)
    "comment unknown field rejected"
    true
    (Option.is_none (decode_comment (prepend_field json ("unknown", `Int 1))))
;;

let test_current_reaction_schema_is_exact () =
  let store = Board_core.create_store () in
  let post = create_no_origin store ~content:"reaction parent" in
  let user_id =
    match Board.Agent_id.of_string "reaction-user" with
    | Ok user_id -> user_id
    | Error error -> Alcotest.fail (Board.show_board_error error)
  in
  let reaction : Board.reaction =
    { target_type = Board.Reaction_post
    ; target_id = Board.Post_id.to_string post.id
    ; user_id
    ; emoji = "👍"
    ; created_at = Time_compat.now ()
    }
  in
  let json = Board_core.reaction_to_yojson reaction in
  let decode_reaction = Board_core.reaction_of_yojson in
  Alcotest.(check bool)
    "canonical reaction round trip"
    true
    (Option.is_some (decode_reaction json));
  List.iter
    (fun field ->
       Alcotest.(check bool)
         (field ^ " is required")
         true
         (Option.is_none (decode_reaction (remove_key json field))))
    [ "target_type"; "target_id"; "user_id"; "emoji"; "created_at" ];
  let rejected label candidate =
    Alcotest.(check bool) label true (Option.is_none (decode_reaction candidate))
  in
  rejected "unknown field rejected" (prepend_field json ("unknown", `Int 1));
  rejected
    "duplicate field rejected"
    (prepend_field json ("emoji", `String "👍"));
  rejected
    "uppercase target type rejected"
    (replace_key json "target_type" (`String "POST"));
  rejected
    "non-canonical target id rejected"
    (replace_key json "target_id" (`String " padded "));
  rejected
    "non-canonical user id rejected"
    (replace_key json "user_id" (`String " reaction-user "));
  rejected
    "unsupported emoji rejected"
    (replace_key json "emoji" (`String "x"));
  rejected "integer timestamp rejected" (replace_key json "created_at" (`Int 1));
  rejected "zero timestamp rejected" (replace_key json "created_at" (`Float 0.0))
;;

let test_current_sub_board_schema_is_exact () =
  let store = Board_core.create_store () in
  let sub_board =
    match
      Board_core.create_sub_board
        store
        ~slug:"current-space"
        ~name:"Current"
        ~description:"Exact current sub-board"
        ~owner:"space-owner"
        ~members:[ "space-member" ]
        ()
    with
    | Ok sub_board -> sub_board
    | Error error -> Alcotest.fail (Board.show_board_error error)
  in
  let json = Board_core.sub_board_to_yojson sub_board in
  let decode_sub_board = Board_core.sub_board_of_yojson in
  Alcotest.(check bool)
    "canonical sub-board round trip"
    true
    (Option.is_some (decode_sub_board json));
  List.iter
    (fun field ->
       Alcotest.(check bool)
         (field ^ " is required")
         true
         (Option.is_none (decode_sub_board (remove_key json field))))
    [ "id"
    ; "slug"
    ; "name"
    ; "description"
    ; "owner"
    ; "members"
    ; "access"
    ; "created_at"
    ; "post_count"
    ];
  let rejected label candidate =
    Alcotest.(check bool) label true (Option.is_none (decode_sub_board candidate))
  in
  rejected "unknown field rejected" (prepend_field json ("unknown", `Int 1));
  rejected
    "duplicate field rejected"
    (prepend_field json ("slug", `String "current-space"));
  rejected "uppercase slug rejected" (replace_key json "slug" (`String "Current"));
  rejected "uppercase access rejected" (replace_key json "access" (`String "OPEN"));
  rejected "integer timestamp rejected" (replace_key json "created_at" (`Int 1));
  rejected "nonzero derived count rejected" (replace_key json "post_count" (`Int 1));
  rejected
    "owner must remain first member"
    (replace_key json "members" (`List [ `String "space-member" ]));
  rejected
    "duplicate member rejected"
    (replace_key
       json
       "members"
       (`List
          [ `String "space-owner"
          ; `String "space-member"
          ; `String "space-member"
          ]));
  rejected
    "malformed member rejected"
    (replace_key
       json
       "members"
       (`List [ `String "space-owner"; `String "not valid" ]))
;;

let test_sub_board_update_rejects_invalid_members () =
  let store = Board_core.create_store () in
  let sub_board =
    match
      Board_core.create_sub_board
        store
        ~slug:"update-space"
        ~name:"Before"
        ~description:""
        ~owner:"update-owner"
        ~members:[ "existing-member" ]
        ()
    with
    | Ok sub_board -> sub_board
    | Error error -> Alcotest.fail (Board.show_board_error error)
  in
  let sub_board_id = Board.Sub_board_id.to_string sub_board.id in
  (match
     Board_core.update_sub_board
       store
       ~sub_board_id
       ~members:[ "replacement"; "not valid" ]
       ()
   with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "invalid member update must fail");
  match Board_core.get_sub_board store ~sub_board_id with
  | Error error -> Alcotest.fail (Board.show_board_error error)
  | Ok current ->
    Alcotest.(check (list string))
      "failed update preserves members"
      [ "update-owner"; "existing-member" ]
      (List.map Board.Agent_id.to_string current.members)
;;

(* Producer side (RFC-0233 §7): the keeper-authored origin constructor used by
   keeper_speech (request-help posts) and keeper_alert. Pins that a keeper post
   carries [origin.turn_ref = Some _] and a typed [source], with
   [fusion_run_id = None] (fusion has its own constructor at the sink). *)
let test_keeper_authored_origin_with_turn_ref () =
  let tr = Ids.Turn_ref.make ~trace_id:"keeper-trace" ~absolute_turn:7 in
  let origin = Board.keeper_authored_origin ~source:"keeper_speech" ~turn_ref:tr () in
  Alcotest.(check (option string)) "source set" (Some "keeper_speech") origin.source;
  Alcotest.(check (option string))
    "turn_ref threaded" (Some "keeper-trace#7")
    (Option.map Ids.Turn_ref.to_string origin.turn_ref);
  Alcotest.(check bool) "fusion_run_id None" true (Option.is_none origin.fusion_run_id);
  (* End-to-end: the post created with this origin carries turn_ref through the
     board codec (create -> encode -> decode). *)
  let store = Board_core.create_store () in
  let post = create store ~origin ~content:"keeper speech request-help" in
  let decoded =
    match decode (Board_core.post_to_yojson post) with
    | Some p -> p
    | None -> Alcotest.fail "encode/decode dropped the keeper post"
  in
  match decoded.origin with
  | Some (o : Board.post_origin) ->
    Alcotest.(check (option string))
      "post carries turn_ref" (Some "keeper-trace#7")
      (Option.map Ids.Turn_ref.to_string o.turn_ref);
    Alcotest.(check (option string)) "post carries source" (Some "keeper_speech") o.source
  | None -> Alcotest.fail "keeper post origin lost in round trip"
;;

let test_keeper_authored_origin_without_turn_ref () =
  (* Scoped-down path (e.g. keeper_alert): origin is present with a typed source
     but no fabricated turn_ref. *)
  let origin = Board.keeper_authored_origin ~source:"keeper_alert" () in
  Alcotest.(check (option string)) "source set" (Some "keeper_alert") origin.source;
  Alcotest.(check bool) "turn_ref None (not fabricated)" true (Option.is_none origin.turn_ref);
  Alcotest.(check bool) "fusion_run_id None" true (Option.is_none origin.fusion_run_id)
;;

let test_index_lookup_hit_and_miss () =
  let store = Board_core.create_store () in
  let tr = Ids.Turn_ref.make ~trace_id:"idx-trace" ~absolute_turn:9 in
  let origin = make_origin ~turn_ref:tr ~fusion_run_id:"run-xyz" () in
  let post = create store ~origin ~content:"indexed" in
  let pid = Board.Post_id.to_string post.id in
  (match Board_core.find_post_by_turn_ref store ~turn_ref:(Ids.Turn_ref.to_string tr) with
   | Some p -> Alcotest.(check string) "turn_ref index hit" pid (Board.Post_id.to_string p.id)
   | None -> Alcotest.fail "turn_ref index miss");
  (match Board_core.find_post_by_run_id store ~run_id:"run-xyz" with
   | Some p -> Alcotest.(check string) "run_id index hit" pid (Board.Post_id.to_string p.id)
   | None -> Alcotest.fail "run_id index miss");
  Alcotest.(check bool) "absent turn_ref -> None (no scan)" true
    (Option.is_none (Board_core.find_post_by_turn_ref store ~turn_ref:"absent#0"));
  Alcotest.(check bool) "absent run_id -> None (no scan)" true
    (Option.is_none (Board_core.find_post_by_run_id store ~run_id:"nope"))
;;

let test_index_rebuilt_on_load () =
  let store1 = Board_core.create_store () in
  let tr = Ids.Turn_ref.make ~trace_id:"load-trace" ~absolute_turn:3 in
  let origin = make_origin ~turn_ref:tr ~fusion_run_id:"load-run" () in
  let _ = create store1 ~origin ~content:"persisted with origin" in
  (* Fresh store loads from the same MASC_BASE_PATH persist file. *)
  let store2 = Board_core.create_store () in
  (match Masc_board_handlers.Board_votes_json.load_persisted_posts store2 with
   | Ok n when n >= 1 -> ()
   | Ok n -> Alcotest.failf "expected >= 1 loaded post, got %d" n
   | Error (p, e) -> Alcotest.failf "load failed: %s (%s)" p (Printexc.to_string e));
  Alcotest.(check bool) "turn_ref index rebuilt on load" true
    (Option.is_some
       (Board_core.find_post_by_turn_ref store2 ~turn_ref:(Ids.Turn_ref.to_string tr)));
  Alcotest.(check bool) "run_id index rebuilt on load" true
    (Option.is_some (Board_core.find_post_by_run_id store2 ~run_id:"load-run"))
;;

let test_index_pruned_on_sweep () =
  let store = Board_core.create_store () in
  let tr = Ids.Turn_ref.make ~trace_id:"sweep-trace" ~absolute_turn:5 in
  let origin = make_origin ~turn_ref:tr ~fusion_run_id:"sweep-run" () in
  let post = create store ~origin ~content:"to be swept" in
  let key = Ids.Turn_ref.to_string tr in
  Alcotest.(check bool) "indexed before sweep" true
    (Stdlib.Hashtbl.mem store.posts_by_turn_ref key);
  (* Force-expire the post in place (epoch + 1s is < now), then sweep. *)
  let expired = { post with expires_at = 1.0 } in
  Stdlib.Hashtbl.replace store.posts (Board.Post_id.to_string post.id) expired;
  let _ : int * int = Board_core.sweep store in
  Alcotest.(check bool) "post removed by sweep" true
    (Option.is_none (Board_core.find_post_by_turn_ref store ~turn_ref:key));
  (* Direct index check: [find_post_by_*] would return None even with a stale
     key (double-lookup), so prove the prune against the index table itself. *)
  Alcotest.(check bool) "turn_ref index pruned" false
    (Stdlib.Hashtbl.mem store.posts_by_turn_ref key);
  Alcotest.(check bool) "run_id index pruned" false
    (Stdlib.Hashtbl.mem store.posts_by_run_id "sweep-run")
;;

let () =
  Alcotest.run
    "board_persistence_schema"
    [ ( "current rows"
      , [ Alcotest.test_case "origin round trip" `Quick (with_eio test_codec_round_trip)
        ; Alcotest.test_case "absent origin -> None" `Quick (with_eio test_codec_absent_origin)
        ; Alcotest.test_case
            "malformed origin rejects row"
            `Quick
            (with_eio test_malformed_origin_rejected)
        ; Alcotest.test_case
            "current post schema is exact"
            `Quick
            (with_eio test_current_post_schema_is_exact)
        ; Alcotest.test_case
            "current comment schema is exact"
            `Quick
            (with_eio test_current_comment_schema_is_exact)
        ; Alcotest.test_case
            "current reaction schema is exact"
            `Quick
            (with_eio test_current_reaction_schema_is_exact)
        ; Alcotest.test_case
            "current sub-board schema is exact"
            `Quick
            (with_eio test_current_sub_board_schema_is_exact)
        ; Alcotest.test_case
            "sub-board update rejects invalid members"
            `Quick
            (with_eio test_sub_board_update_rejects_invalid_members)
        ; Alcotest.test_case
            "keeper-authored origin carries turn_ref"
            `Quick
            (with_eio test_keeper_authored_origin_with_turn_ref)
        ; Alcotest.test_case
            "keeper-authored origin without turn_ref (scoped)"
            `Quick
            (with_eio test_keeper_authored_origin_without_turn_ref)
        ] )
    ; ( "index"
      , [ Alcotest.test_case
            "find_post_by_turn_ref / run_id hit + miss"
            `Quick
            (with_eio test_index_lookup_hit_and_miss)
        ; Alcotest.test_case
            "indexes rebuilt on load"
            `Quick
            (with_eio test_index_rebuilt_on_load)
        ; Alcotest.test_case
            "indexes pruned on sweep"
            `Quick
            (with_eio test_index_pruned_on_sweep)
        ] )
    ]
;;
