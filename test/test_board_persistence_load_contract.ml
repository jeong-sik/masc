(** Contract test for {!Masc_board_handlers.Masc_board_handlers.Board_votes_json.load_persisted_posts} and
    {!Masc_board_handlers.Masc_board_handlers.Board_votes_json.load_persisted_comments}.

    Prior to this contract change, the loaders had signature
    [store -> unit] and swallowed any [exn] from the JSONL read into an
    in-function [Log.BoardLog.error].  Callers could not distinguish a
    successful "no file" load from a partially-loaded store after an IO
    failure.

    The current contract returns [(int, string * exn) result]. A first load
    of an absent posts file starts empty; once a store has observed an actual
    posts file, its absence is refused. First observed missing comments are legitimate empty input; losing a
    comments source this store observed Present is refused. *)

open Masc

let () = Mirage_crypto_rng_unix.use_default ()

(* The store-level writers ask a recipient lookup; no name is declared here. *)
let nobody_declared = Recipient_lookup.none_declared

let fresh_test_base_path () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-board-loader-%06x" (Random.bits ()))
  in
  Fs_compat.mkdir_p dir;
  Unix.putenv "MASC_BASE_PATH" dir;
  dir
;;

let load_reactions store = match Board.reload_reactions store with
  | Ok _ -> ()
  | Error error -> Alcotest.fail (Board.show_board_error error)
;;

let load_sources store =
  List.iter (fun load ->
    match load store with
    | Ok _ -> ()
    | Error (path, cause) ->
      Alcotest.failf "board fixture load failed: %s (%s)" path (Printexc.to_string cause))
    [Masc_board_handlers.Board_votes_json.load_persisted_posts;
     Masc_board_handlers.Board_votes_json.load_persisted_comments;
     Board.reload_sub_boards];
  (match Board.reload_votes store with
   | Ok _ -> ()
   | Error error -> Alcotest.fail (Board.show_board_error error));
  load_reactions store
;;

let posts_source_health store =
  Board.with_persist_lock store (fun () -> Board.require_posts_source_readable store)
  |> Result.map_error Board.show_board_error
;;

let comments_source_health store =
  Board.with_persist_lock store (fun () -> Board.require_comments_source_readable store)
  |> Result.map_error Board.show_board_error
;;

let test_load_persisted_posts_missing_file () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let _dir = fresh_test_base_path () in
  let store = Board_core.create_store
      ~base_path:(Env_config_core.base_path ()) () in
  Alcotest.(check bool) "a first load of absent posts starts empty" true
    (Masc_board_handlers.Board_votes_json.load_persisted_posts store = Ok 0);
  Alcotest.(check bool) "the empty start grants posts authority" true
    (posts_source_health store = Ok ());
  Alcotest.(check bool) "live reads never create the posts file" false
    (Sys.file_exists (Board.persist_path store))
;;

let test_load_persisted_comments_missing_file () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let _dir = fresh_test_base_path () in
  let store = Board_core.create_store
      ~base_path:(Env_config_core.base_path ()) () in
  match Masc_board_handlers.Board_votes_json.load_persisted_comments store with
  | Ok 0 -> ()
  | Ok n -> Alcotest.failf "expected Ok 0 for missing file, got Ok %d" n
  | Error (path, e) ->
    Alcotest.failf
      "expected Ok 0 for missing file, got Error (%s, %s)"
      path
      (Printexc.to_string e)
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

let replace_key json key value =
  match json with
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (name, current) ->
            if String.equal name key then name, value else name, current)
         fields)
  | other -> other
;;

let test_loader_keeps_only_current_rows () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let _dir = fresh_test_base_path () in
  let source_store = Board_core.create_store
      ~base_path:(Env_config_core.base_path ()) () in
  load_sources source_store;
  let post =
    match
      Board_core.create_post
        source_store
        ~lookup:nobody_declared
        ~author:"current-writer"
        ~content:"current persisted row"
        ~post_kind:Board.Human_post
        ()
    with
    | Ok post -> post
    | Error error ->
      Alcotest.failf "create_post failed: %s" (Board.Post_publication_failure.to_string error)
  in
  (* The comment is written while [source_store]'s cursor still matches the
     posts file. The rows appended and the truncation below change that file
     behind the store, after which its next write is refused. *)
  let comment = match Board_core.add_comment ~reader:Masc_board_handlers.Board_access.Operator source_store ~lookup:nobody_declared
      ~post_id:(Board.Post_id.to_string post.id) ~author:"fixture-author"
      ~content:"retained partial comment" ~ttl_hours:0 () with
    | Ok comment -> Board_core.comment_to_yojson comment
    | Error error -> Alcotest.failf "create_comment failed: %s" (Board.show_board_error error) in
  let canonical = Board_core.post_to_yojson post in
  let path = Board.persist_path source_store in
  let append json =
    Fs_compat.append_file path (Yojson.Safe.to_string json ^ "\n")
  in
  append (remove_key canonical "pinned");
  append (prepend_field canonical ("meta_json", `String "{}"));
  append (replace_key canonical "votes_up" (`String "0"));
  let loaded_store = Board_core.create_store
      ~base_path:(Env_config_core.base_path ()) () in
  (match Masc_board_handlers.Board_votes_json.load_persisted_posts loaded_store with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "invalid persisted schemas must report partial-source failure");
  Alcotest.(check bool) "schema failure remains available to evidence readers" true
    (Result.is_error (posts_source_health loaded_store));
  Alcotest.(check bool)
    "canonical post is present"
    true
    (Result.is_ok
       (Board_core.read_post
          loaded_store
          ~post_id:(Board.Post_id.to_string post.id)));
  Out_channel.with_open_bin path (fun _ -> ());
  Alcotest.(check bool) "empty successful reload discards prior partial rows" true
    (Masc_board_handlers.Board_votes_json.load_persisted_posts loaded_store = Ok 0);
  Alcotest.(check int) "old post is not trusted after empty reload" 0 (Hashtbl.length loaded_store.posts);
  Alcotest.(check int) "old post count is cleared" 0 !(loaded_store.post_count);
  let comments_path = Board.comments_path source_store in
  Out_channel.with_open_bin comments_path (fun out ->
    output_string out (Yojson.Safe.to_string comment ^ "\n{bad-json\n"));
  Alcotest.(check bool) "mixed valid/corrupt comments fail completeness" true
    (Result.is_error (Masc_board_handlers.Board_votes_json.load_persisted_comments loaded_store));
  Alcotest.(check int) "best-effort valid comment remains" 1 (Hashtbl.length loaded_store.comments);
  Out_channel.with_open_bin comments_path (fun _ -> ());
  Alcotest.(check bool) "empty comments reload succeeds" true
    (Masc_board_handlers.Board_votes_json.load_persisted_comments loaded_store = Ok 0);
  Alcotest.(check int) "old comments removed on healthy reload" 0 (Hashtbl.length loaded_store.comments);
  Alcotest.(check int) "comment index cleared on healthy reload" 0 (Hashtbl.length loaded_store.comments_by_post);
  List.iter (fun expiry ->
    Alcotest.(check bool) "malformed post expiry is rejected by the decoder" true
      (Option.is_none (Masc_board_handlers.Board_votes_json.post_of_yojson
        (replace_key canonical "expires_at" (`Float expiry))));
    Alcotest.(check bool) "malformed comment expiry is rejected by the decoder" true
      (Option.is_none (Masc_board_handlers.Board_votes_json.comment_of_yojson
        (replace_key comment "expires_at" (`Float expiry)))))
    [-1.; Float.nan; Float.infinity; Float.neg_infinity];
  Out_channel.with_open_bin path (fun out ->
    output_string out (Yojson.Safe.to_string (replace_key canonical "expires_at" (`Float 1.)) ^ "\n"));
  let expired_store = Board_core.create_store
      ~base_path:(Env_config_core.base_path ()) () in
  Alcotest.(check bool) "valid expired posts remain available for cascade cleanup" true
    (Masc_board_handlers.Board_votes_json.load_persisted_posts expired_store = Ok 1);
  Alcotest.(check bool) "expired-only source remains complete" true
    (posts_source_health expired_store = Ok ());
  Out_channel.with_open_bin comments_path (fun out ->
    output_string out (Yojson.Safe.to_string (replace_key comment "expires_at" (`Float 1.)) ^ "\n"));
  Alcotest.(check bool) "valid expired comments remain available for dependent cleanup" true
    (Masc_board_handlers.Board_votes_json.load_persisted_comments expired_store = Ok 1);
  Alcotest.(check bool) "expired comments remain a complete source" true
    (comments_source_health expired_store = Ok ());
  ignore (Result.get_ok (Board.reload_votes expired_store));
  load_reactions expired_store;
  Alcotest.(check (pair int int)) "sweeper owns expiry after reload" (1, 1)
    (Board_core.sweep expired_store)
;;

let test_source_failure_clears_only_after_successful_reload () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let previous = Sys.getenv_opt "MASC_BASE_PATH" in
  let dir = fresh_test_base_path () in
  Fun.protect ~finally:(fun () ->
    Unix.putenv "MASC_BASE_PATH" (Option.value ~default:"" previous);
    if Sys.file_exists dir then Fs_compat.remove_tree dir) (fun () ->
    let store = Board_core.create_store
      ~base_path:(Env_config_core.base_path ()) () in
    let loaders = [
      (Board.persist_path store, Masc_board_handlers.Board_votes_json.load_persisted_posts,
       (fun () -> posts_source_health store));
      (Board.comments_path store, Masc_board_handlers.Board_votes_json.load_persisted_comments,
       (fun () -> comments_source_health store))] in
    List.iter (fun (path, load, health) ->
      Fs_compat.mkdir_p (Filename.dirname path);
      let write text = Out_channel.with_open_bin path (fun out -> output_string out text) in
      List.iter (fun malformed ->
        write malformed;
        Alcotest.(check bool) "invalid source fails load" true (Result.is_error (load store));
        Alcotest.(check bool) "failure retained" true (Result.is_error (health ())))
        ["{secret-not-json\n"; "{}\n"];
      (* Editing the file cannot erase the last load outcome by itself. *)
      write "";
      Alcotest.(check bool) "failure stays until reloaded" true (Result.is_error (health ()));
      Alcotest.(check bool) "empty file is legitimate" true (load store = Ok 0);
      Alcotest.(check bool) "successful reload clears failure" true (health () = Ok ());
      Sys.remove path;
      Unix.mkdir path 0o700;
      Alcotest.(check bool) "unreadable source is not a missing file" true
        (Result.is_error (load store));
      Unix.rmdir path;
      Alcotest.(check bool) "missing previously observed source cannot become new authority" true
        (Result.is_error (load store));
      Alcotest.(check bool) "missing source retains the refusal" true
        (Result.is_error (health ()))) loaders)
;;

(* #38595: a load that meets a damaged line keeps every row it can decode,
   before and after that line, but not the line itself. A snapshot from that
   memory used to replace the file and delete the damaged line. Every snapshot
   write -- the flush, the direct save, and a delete -- now leaves both files
   as they are. *)
let test_partial_load_never_rewrites_the_file () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let _dir = fresh_test_base_path () in
  let source_store = Board_core.create_store
      ~base_path:(Env_config_core.base_path ()) () in
  load_sources source_store;
  let make_post content =
    match
      Board_core.create_post source_store ~lookup:nobody_declared ~author:"partial-writer" ~content
        ~post_kind:Board.Human_post ()
    with
    | Ok post -> post
    | Error error -> Alcotest.failf "create_post failed: %s" (Board.Post_publication_failure.to_string error)
  in
  let make_comment ~post_id content =
    match
      Board_core.add_comment ~reader:Masc_board_handlers.Board_access.Operator source_store ~lookup:nobody_declared ~post_id ~author:"partial-writer" ~content
        ~ttl_hours:0 ()
    with
    | Ok comment -> comment
    | Error error -> Alcotest.failf "add_comment failed: %s" (Board.show_board_error error)
  in
  let before = make_post "row before the damage" in
  let after = make_post "row after the damage" in
  let before_id = Board.Post_id.to_string before.id in
  let c_before = make_comment ~post_id:before_id "comment before the damage" in
  let c_after = make_comment ~post_id:before_id "comment after the damage" in
  let before = { before with expires_at = 1.0 } in
  let c_before = { c_before with expires_at = 1.0 } in
  let read path = In_channel.with_open_bin path In_channel.input_all in
  let damage path first second =
    Out_channel.with_open_bin path (fun out ->
      output_string out (first ^ "\n{damaged\n" ^ second ^ "\n"));
    read path
  in
  let json to_yojson value = Yojson.Safe.to_string (to_yojson value) in
  let posts_path = Board.persist_path source_store in
  let comments_path = Board.comments_path source_store in
  let posts_on_disk =
    damage posts_path (json Board_core.post_to_yojson before)
      (json Board_core.post_to_yojson after)
  in
  let comments_on_disk =
    damage comments_path (json Board_core.comment_to_yojson c_before)
      (json Board_core.comment_to_yojson c_after)
  in
  let store = Board_core.create_store
      ~base_path:(Env_config_core.base_path ()) () in
  Alcotest.(check bool) "posts load reports the damage" true
    (Result.is_error (Masc_board_handlers.Board_votes_json.load_persisted_posts store));
  Alcotest.(check bool) "comments load reports the damage" true
    (Result.is_error (Masc_board_handlers.Board_votes_json.load_persisted_comments store));
  ignore (Result.get_ok (Board.reload_votes store));
  load_reactions store;
  Alcotest.(check bool) "posts after the damaged line are still served" true
    (Result.is_ok (Board_core.read_post store ~post_id:(Board.Post_id.to_string after.id)));
  let observed = match Board_core.observe_comments store
      ~post_id:(Board.Post_id.to_string c_after.post_id) with
    | Ok observed -> observed
    | Error error -> Alcotest.fail (Board.show_board_read_error error) in
  Alcotest.(check bool) "comments after the damaged line remain display rows" true
    (List.exists (fun (comment : Board.comment) -> comment.id = c_after.id) observed.comments);
  Alcotest.(check bool) "display rows retain their incomplete source status" true
    (match observed.completeness with
     | Board.Source_incomplete (Board.Io_error _) -> true
     | Board.Source_incomplete _ | Board.Source_complete -> false);
  let unchanged label =
    Alcotest.(check string) (label ^ ": posts file untouched") posts_on_disk (read posts_path);
    Alcotest.(check string) (label ^ ": comments file untouched") comments_on_disk
      (read comments_path)
  in
  store.Board.dirty_posts <- true;
  store.Board.dirty_comments <- true;
  Alcotest.(check (pair int int)) "partial sources cannot authorize expiry"
    (0, 0) (Board_core.sweep store);
  Alcotest.(check int) "sweep retains both best-effort posts" 2
    (Hashtbl.length store.posts);
  Alcotest.(check int) "sweep retains both best-effort comments" 2
    (Hashtbl.length store.comments);
  Board.flush_dirty store;
  unchanged "sweep and flush";
  Alcotest.(check bool) "refused posts write stays scheduled" true store.Board.dirty_posts;
  Alcotest.(check bool) "refused comments write stays scheduled" true
    store.Board.dirty_comments;
  let posts_outcome = Board.with_persist_lock store (fun () ->
    let snapshot = Board.with_lock store (fun () -> Board.capture_posts_snapshot store) in
    Board.save_posts_snapshot store snapshot) in
  (match posts_outcome with
   | Board.Posts_not_written _ -> ()
   | Board.Posts_written _ | Board.Posts_write_unknown _ ->
     Alcotest.fail "partial posts source must refuse the exact captured snapshot before writing");
  Alcotest.(check bool) "direct comments snapshot is refused" true
    (Result.is_error (Board.with_persist_lock store (fun () ->
      let snapshot = Board.with_lock store (fun () -> Board.capture_comments_snapshot store) in
      Board.save_comments_snapshot store snapshot)));
  unchanged "direct save";
  Alcotest.(check bool) "delete is refused before it touches memory" true
    (Result.is_error (Board.delete_post store ~authorization:Board.Operator_deletion ~post_id:before_id));
  Alcotest.(check bool) "the post is still in memory" true
    (Result.is_ok (Board_core.read_post store ~post_id:before_id));
  unchanged "delete";
  (* Only repairing and successfully re-reading both sources restores expiry
     authority; a file edit alone does not erase the recorded load failure. *)
  let repair path rows =
    Out_channel.with_open_bin path (fun out ->
      List.iter (fun row -> output_string out (row ^ "\n")) rows)
  in
  repair posts_path
    [json Board_core.post_to_yojson before; json Board_core.post_to_yojson after];
  repair comments_path
    [json Board_core.comment_to_yojson c_before; json Board_core.comment_to_yojson c_after];
  Alcotest.(check (pair int int)) "repair without reload is not authority"
    (0, 0) (Board_core.sweep store);
  Alcotest.(check bool) "healthy posts reload succeeds" true
    (Masc_board_handlers.Board_votes_json.load_persisted_posts store = Ok 2);
  Alcotest.(check (pair int int)) "partial comments still block a cascade"
    (0, 0) (Board_core.sweep store);
  Alcotest.(check bool) "healthy comments reload succeeds" true
    (Masc_board_handlers.Board_votes_json.load_persisted_comments store = Ok 2);
  Alcotest.(check (pair int int)) "complete reload allows expiry and cascade"
    (1, 2) (Board_core.sweep store);
  Board.flush_dirty store;
  let reloaded = Board_core.create_store
      ~base_path:(Env_config_core.base_path ()) () in
  Alcotest.(check bool) "unexpired post remains after cleanup flush" true
    (Masc_board_handlers.Board_votes_json.load_persisted_posts reloaded = Ok 1);
  Alcotest.(check bool) "both cascaded comments stay removed" true
    (Masc_board_handlers.Board_votes_json.load_persisted_comments reloaded = Ok 0)
;;

let test_explicit_workspace_is_captured_once () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let original_cwd = Sys.getcwd () in
  let original_base = Sys.getenv_opt "MASC_BASE_PATH" in
  let directory = Filename.temp_dir "board-captured-root" "" in
  let first = Filename.concat directory "first" in
  let second = Filename.concat directory "second" in
  Fs_compat.mkdir_p first;
  Fs_compat.mkdir_p second;
  Fun.protect
    ~finally:(fun () ->
      Unix.chdir original_cwd;
      Unix.putenv "MASC_BASE_PATH" (Option.value original_base ~default:""))
    (fun () ->
      (match Board.create_store ~base_path:"" () with
       | _ -> Alcotest.fail "empty workspace must raise Invalid_argument"
       | exception Invalid_argument _ -> ());
      Unix.chdir first;
      let captured_base = Filename.concat (Unix.realpath first) " state with spaces " in
      Fs_compat.mkdir_p captured_base;
      let store = Board.create_store ~base_path:" state with spaces " () in
      let captured = Common.masc_dir_from_base_path ~base_path:captured_base in
      Unix.chdir second;
      Unix.putenv "MASC_BASE_PATH" second;
      Alcotest.(check string) "relative directory is anchored without trimming"
        captured (Board.workspace_masc_dir store);
      load_sources store;
      let post =
        match Board.create_post store ~lookup:nobody_declared ~author:"writer"
          ~content:"written after cwd and Env change" ~post_kind:Board.Human_post () with
        | Ok post -> post
        | Error failure -> Alcotest.fail (Board.Post_publication_failure.to_string failure)
      in
      Alcotest.(check bool) "post is written under the captured directory" true
        (Sys.file_exists (Board.persist_path store));
      Alcotest.(check bool) "new cwd has no substituted directory" false
        (Sys.file_exists (Filename.concat second " state with spaces "));
      let reloaded = Board.create_store ~base_path:captured_base () in
      Alcotest.(check bool) "explicit reload under EnvB reads A" true
        (Masc_board_handlers.Board_votes_json.load_persisted_posts reloaded = Ok 1);
      Alcotest.(check bool) "accepted identity survives reload" true
        (Result.is_ok (Board.read_post reloaded ~post_id:(Board.Post_id.to_string post.id))))
;;

let test_all_persistence_stays_in_captured_workspace () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let original_base = Sys.getenv_opt "MASC_BASE_PATH" in
  let base_a = Filename.temp_dir "board-workspace-a" "" in
  let base_b = Filename.temp_dir "board-workspace-b" "" in
  let root_a = Common.masc_dir_from_base_path ~base_path:base_a in
  let root_b = Common.masc_dir_from_base_path ~base_path:base_b in
  let paths store =
    [ Board.persist_path store; Board.comments_path store; Board.vote_log_path store
    ; Board.reactions_path store; Board.sub_boards_path store ]
  in
  let board_ok = function
    | Ok value -> value
    | Error error -> Alcotest.fail (Board.show_board_error error)
  in
  let post_ok = function
    | Ok value -> value
    | Error failure -> Alcotest.fail (Board.Post_publication_failure.to_string failure)
  in
  let init_a () =
    Board.reset_global_for_test ();
    Board_dispatch.reset_for_test ();
    Result.get_ok (Board_dispatch.init_jsonl ~base_path:base_a
      ~recipient_lookup:nobody_declared ());
    Board.global ()
  in
  Fun.protect
    ~finally:(fun () ->
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ();
      Unix.putenv "MASC_BASE_PATH" (Option.value original_base ~default:""))
    (fun () ->
      (* Reset is quiescent; the selected root belongs to the first force. *)
      Unix.putenv "MASC_BASE_PATH" base_a;
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ();
      Alcotest.(check bool) "reset creates no selected workspace metadata" false
        (Sys.file_exists root_a);
      Unix.putenv "MASC_BASE_PATH" base_b;
      let forced_b = Board.global () in
      Alcotest.(check string) "first force captures the newly selected root"
        (Unix.realpath root_b) (Board.workspace_masc_dir forced_b);
      Unix.putenv "MASC_BASE_PATH" base_a;
      Alcotest.(check bool) "later root drift retains the same forced singleton" true
        (Board.global () == forced_b);
      (* Seed B through real store producers, so redirecting any of the five
         files would overwrite independent accepted data rather than an empty fixture. *)
      let store_b = Board.create_store ~base_path:base_b () in
      load_sources store_b;
      let b = post_ok (Board.create_post store_b ~lookup:nobody_declared ~author:"b-owner"
        ~content:"B must survive untouched" ~post_kind:Board.Human_post ()) in
      let bid = Board.Post_id.to_string b.id in
      ignore (board_ok (Board.add_comment ~reader:Masc_board_handlers.Board_access.Operator store_b ~lookup:nobody_declared ~post_id:bid
        ~author:"b-reader" ~content:"B comment" ~ttl_hours:0 ()));
      ignore (board_ok (Board.vote store_b ~reader:Masc_board_handlers.Board_access.Operator ~voter:"b-voter" ~post_id:bid ~direction:Board.Up));
      ignore (board_ok (Board.toggle_reaction store_b ~reader:Masc_board_handlers.Board_access.Operator ~target_type:Board.Reaction_post
        ~target_id:bid ~user_id:"b-reader" ~emoji:"🚀"));
      ignore (board_ok (Board.create_sub_board store_b ~slug:"b-room" ~name:"B room"
        ~description:"independent policy" ~owner:"b-owner" ()));
      Board.flush_dirty store_b;
      let baseline_b = List.map (fun path -> path, Fs_compat.load_file path) (paths store_b) in
      let b_unchanged label = List.iter (fun (path, expected) ->
        Alcotest.(check string) (label ^ ": " ^ Filename.basename path)
          expected (Fs_compat.load_file path)) baseline_b in
      Unix.putenv "MASC_BASE_PATH" base_a;
      let store_a = init_a () in
      Unix.putenv "MASC_BASE_PATH" base_b;
      let room = board_ok (Board_dispatch.create_sub_board ~reader:Masc_board_handlers.Board_access.Operator ~slug:"a-room" ~name:"A room"
        ~description:"A policy" ~owner:"a-owner" ()) in
      let room_id = Board.Sub_board_id.to_string room.id in
      let post = post_ok (Board_dispatch.create_post ~author:"a-owner" ~content:"A post"
        ~hearth:"a-room" ~post_kind:Board.Human_post ()) in
      let pid = Board.Post_id.to_string post.id in
      let comment = board_ok (Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id:pid ~author:"a-reader"
        ~content:"A comment" ~ttl_hours:0 ()) in
      let cid = Board.Comment_id.to_string comment.id in
      ignore (board_ok (Board_dispatch.vote ~reader:Masc_board_handlers.Board_access.Operator ~voter:"a-voter" ~post_id:pid ~direction:Board.Up));
      ignore (board_ok (Board_dispatch.vote_comment ~reader:Masc_board_handlers.Board_access.Operator ~voter:"a-voter" ~comment_id:cid
        ~direction:Board.Down));
      ignore (board_ok (Board_dispatch.toggle_reaction ~reader:Masc_board_handlers.Board_access.Operator ~target_type:Board.Reaction_post
        ~target_id:pid ~user_id:"a-reader" ~emoji:"🚀"));
      ignore (board_ok (Board_dispatch.toggle_reaction ~reader:Masc_board_handlers.Board_access.Operator ~target_type:Board.Reaction_comment
        ~target_id:cid ~user_id:"a-owner" ~emoji:"🚀"));
      ignore (board_ok (Board_dispatch.update_post ~post_id:pid ~editor:"a-owner"
        ~content:"A edited under EnvB" ()));
      ignore (board_ok (Board_dispatch.set_pinned ~post_id:pid ~pinned:true));
      ignore (board_ok (Board_dispatch.update_sub_board ~reader:Masc_board_handlers.Board_access.Operator ~sub_board_id:room_id
        ~access:Board.Members_only ~members:["a-reader"] ()));
      Board.flush_dirty store_a;
      b_unchanged "after producers and flush under EnvB";
      (* The production singleton owns the complete five-source loader. Select
         A for its fresh construction, then drift Env back to B before using it. *)
      let restart_a () =
        Unix.putenv "MASC_BASE_PATH" base_a;
        let store = init_a () in
        Unix.putenv "MASC_BASE_PATH" base_b;
        store
      in
      let reloaded = restart_a () in
      let retained = board_ok (Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id:pid) in
      Alcotest.(check string) "edited post reloaded" "A edited under EnvB" retained.body;
      Alcotest.(check bool) "pin reloaded" true retained.pinned;
      Alcotest.(check int) "post vote reloaded" 1 retained.votes_up;
      Alcotest.(check int) "reply count rebuilt" 1 retained.reply_count;
      let comments = board_ok (Board_dispatch.get_comments ~reader:Masc_board_handlers.Board_access.Operator ~post_id:pid) in
      Alcotest.(check (list string)) "comment identity reloaded" [cid]
        (List.map (fun (c : Board.comment) -> Board.Comment_id.to_string c.id) comments);
      Alcotest.(check bool) "comment vote ledger reloaded" true
        (board_ok (Board_dispatch.current_vote_for_comment ~reader:Masc_board_handlers.Board_access.Operator ~voter:"a-voter" ~comment_id:cid)
          = Some Board.Down);
      List.iter (fun (target_type, target_id) ->
        let reactions = board_ok (Board_dispatch.list_reactions ~reader:Masc_board_handlers.Board_access.Operator ~target_type ~target_id ()) in
        Alcotest.(check int) "reaction reloaded" 1 (List.length reactions))
        [Board.Reaction_post, pid; Board.Reaction_comment, cid];
      let room = board_ok (Board_dispatch.get_sub_board ~reader:Masc_board_handlers.Board_access.Operator ~sub_board_id:room_id) in
      Alcotest.(check bool) "updated policy reloaded" true (room.access = Board.Members_only);
      ignore (board_ok (Board_dispatch.delete_sub_board ~authorization:Board.Operator_sub_board_deletion ~sub_board_id:room_id));
      (match board_ok (Board_dispatch.delete_post ~authorization:Board.Operator_deletion ~post_id:pid) with
       | Board.Durable_deletion -> ()
       | Board.Deletion_decision_pending detail -> Alcotest.fail detail
       | Board.Deletion_persistence_pending detail -> Alcotest.fail detail);
      Board.flush_dirty reloaded;
      b_unchanged "after deletion under EnvB";
      let deleted = restart_a () in
      Alcotest.(check bool) "deleted post cannot resurrect" true
        (Result.is_error (Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id:pid));
      Alcotest.(check bool) "comments of the deleted post are refused with the post" true
        (Board_dispatch.get_comments ~reader:Masc_board_handlers.Board_access.Operator ~post_id:pid
         = Error (Board.Post_not_found pid));
      Alcotest.(check int) "cascaded comment cannot resurrect" 0 (Hashtbl.length deleted.comments);
      Alcotest.(check bool) "deleted policy cannot resurrect" true
        (Result.is_error (Board_dispatch.get_sub_board ~reader:Masc_board_handlers.Board_access.Operator ~sub_board_id:room_id));
      Alcotest.(check int) "deleted votes cannot resurrect" 0 (Hashtbl.length deleted.vote_log);
      Alcotest.(check int) "deleted reactions cannot resurrect" 0 (Hashtbl.length deleted.reactions);
      b_unchanged "after complete reload")
;;

(* A vote takes its time before it writes its log row, outside the lock; an
   edit can commit in between. The post below stands for that edit: its
   [updated_at] and [content_updated_at] are later than the vote's time. The
   commit keeps them in order, as the vote-log replay on load does. *)
let test_a_vote_does_not_move_updated_at_back () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let _dir = fresh_test_base_path () in
  let store = Board_core.create_store ~base_path:(Env_config_core.base_path ()) () in
  load_sources store;
  let post =
    match
      Board_core.create_post store ~lookup:nobody_declared ~author:"fixture-author"
        ~content:"edited while a vote was in flight" ~post_kind:Board.Human_post ()
    with
    | Ok post -> post
    | Error error ->
      Alcotest.failf "create_post failed: %s" (Board.Post_publication_failure.to_string error)
  in
  let post_id = Board.Post_id.to_string post.id in
  let edited_at = Time_compat.now () +. 3600. in
  Hashtbl.replace store.posts post_id
    { post with updated_at = edited_at; content_updated_at = edited_at };
  (match
     Masc_board_handlers.Board_votes.vote store ~reader:Masc_board_handlers.Board_access.Operator ~voter:"fixture-voter" ~post_id
       ~direction:Board.Up
   with
   | Ok _ -> ()
   | Error error -> Alcotest.failf "vote failed: %s" (Board.show_board_error error));
  match Hashtbl.find_opt store.posts post_id with
  | None -> Alcotest.fail "the voted post is gone"
  | Some voted ->
    Alcotest.(check int) "the vote is counted" 1 voted.votes_up;
    Alcotest.(check (float 0.)) "updated_at stays at the edit" edited_at voted.updated_at
;;

let () =
  Random.self_init ();
  Alcotest.run
    "board_persistence_load_contract"
    [ ( "loader_contract"
      , [ Alcotest.test_case "explicit workspace captures relative path once" `Quick
            test_explicit_workspace_is_captured_once
        ; Alcotest.test_case "all persistence stays in captured workspace after Env drift" `Quick
            test_all_persistence_stays_in_captured_workspace
        ; Alcotest.test_case "source failures survive until a complete successful reload" `Quick
            test_source_failure_clears_only_after_successful_reload
        ; Alcotest.test_case
            "posts loader returns Ok 0 when file absent"
            `Quick
            test_load_persisted_posts_missing_file
        ; Alcotest.test_case
            "comments loader returns Ok 0 when file absent"
            `Quick
            test_load_persisted_comments_missing_file
        ; Alcotest.test_case
            "loader keeps only exact current rows"
            `Quick
            test_loader_keeps_only_current_rows
        ; Alcotest.test_case
            "a partial load never rewrites the posts or comments file"
            `Quick
            test_partial_load_never_rewrites_the_file
        ; Alcotest.test_case
            "a vote does not move updated_at back"
            `Quick
            test_a_vote_does_not_move_updated_at_back
        ] )
    ]
;;
