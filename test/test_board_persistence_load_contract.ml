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
  let store = Masc_board_handlers.Board_core.create_store
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
  let store = Masc_board_handlers.Board_core.create_store
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
  let source_store = Masc_board_handlers.Board_core.create_store
      ~base_path:(Env_config_core.base_path ()) () in
  load_sources source_store;
  let post =
    match
      Masc_board_handlers.Board_core.create_post
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
  let comment = match Masc_board_handlers.Board_core.add_comment ~reader:Masc_board_handlers.Board_access.Operator source_store ~lookup:nobody_declared
      ~post_id:(Board.Post_id.to_string post.id) ~author:"fixture-author"
      ~content:"retained partial comment" ~ttl_hours:0 () with
    | Ok comment -> Masc_board_handlers.Board_core.comment_to_yojson comment
    | Error error -> Alcotest.failf "create_comment failed: %s" (Board.show_board_error error) in
  let canonical = Masc_board_handlers.Board_core.post_to_yojson post in
  let path = Board.persist_path source_store in
  let append json =
    Fs_compat.append_file path (Yojson.Safe.to_string json ^ "\n")
  in
  append (remove_key canonical "pinned");
  append (prepend_field canonical ("meta_json", `String "{}"));
  append (replace_key canonical "votes_up" (`String "0"));
  let loaded_store = Masc_board_handlers.Board_core.create_store
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
       (Masc_board_handlers.Board_core.read_post
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
  let expired_store = Masc_board_handlers.Board_core.create_store
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
    (Masc_board_handlers.Board_core.sweep expired_store)
;;

let test_source_failure_clears_only_after_successful_reload () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let previous = Sys.getenv_opt "MASC_BASE_PATH" in
  let dir = fresh_test_base_path () in
  Fun.protect ~finally:(fun () ->
    Unix.putenv "MASC_BASE_PATH" (Option.value ~default:"" previous);
    if Sys.file_exists dir then Fs_compat.remove_tree dir) (fun () ->
    let store = Masc_board_handlers.Board_core.create_store
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
  let source_store = Masc_board_handlers.Board_core.create_store
      ~base_path:(Env_config_core.base_path ()) () in
  load_sources source_store;
  let make_post content =
    match
      Masc_board_handlers.Board_core.create_post source_store ~lookup:nobody_declared ~author:"partial-writer" ~content
        ~post_kind:Board.Human_post ()
    with
    | Ok post -> post
    | Error error -> Alcotest.failf "create_post failed: %s" (Board.Post_publication_failure.to_string error)
  in
  let make_comment ~post_id content =
    match
      Masc_board_handlers.Board_core.add_comment ~reader:Masc_board_handlers.Board_access.Operator source_store ~lookup:nobody_declared ~post_id ~author:"partial-writer" ~content
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
    damage posts_path (json Masc_board_handlers.Board_core.post_to_yojson before)
      (json Masc_board_handlers.Board_core.post_to_yojson after)
  in
  let comments_on_disk =
    damage comments_path (json Masc_board_handlers.Board_core.comment_to_yojson c_before)
      (json Masc_board_handlers.Board_core.comment_to_yojson c_after)
  in
  let store = Masc_board_handlers.Board_core.create_store
      ~base_path:(Env_config_core.base_path ()) () in
  Alcotest.(check bool) "posts load reports the damage" true
    (Result.is_error (Masc_board_handlers.Board_votes_json.load_persisted_posts store));
  Alcotest.(check bool) "comments load reports the damage" true
    (Result.is_error (Masc_board_handlers.Board_votes_json.load_persisted_comments store));
  ignore (Result.get_ok (Board.reload_votes store));
  load_reactions store;
  Alcotest.(check bool) "posts after the damaged line are still served" true
    (Result.is_ok (Masc_board_handlers.Board_core.read_post store ~post_id:(Board.Post_id.to_string after.id)));
  let observed = match Masc_board_handlers.Board_core.observe_comments store
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
    (0, 0) (Masc_board_handlers.Board_core.sweep store);
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
    (Result.is_ok (Masc_board_handlers.Board_core.read_post store ~post_id:before_id));
  unchanged "delete";
  (* Only repairing and successfully re-reading both sources restores expiry
     authority; a file edit alone does not erase the recorded load failure. *)
  let repair path rows =
    Out_channel.with_open_bin path (fun out ->
      List.iter (fun row -> output_string out (row ^ "\n")) rows)
  in
  repair posts_path
    [json Masc_board_handlers.Board_core.post_to_yojson before; json Masc_board_handlers.Board_core.post_to_yojson after];
  repair comments_path
    [json Masc_board_handlers.Board_core.comment_to_yojson c_before; json Masc_board_handlers.Board_core.comment_to_yojson c_after];
  Alcotest.(check (pair int int)) "repair without reload is not authority"
    (0, 0) (Masc_board_handlers.Board_core.sweep store);
  Alcotest.(check bool) "healthy posts reload succeeds" true
    (Masc_board_handlers.Board_votes_json.load_persisted_posts store = Ok 2);
  Alcotest.(check (pair int int)) "partial comments still block a cascade"
    (0, 0) (Masc_board_handlers.Board_core.sweep store);
  Alcotest.(check bool) "healthy comments reload succeeds" true
    (Masc_board_handlers.Board_votes_json.load_persisted_comments store = Ok 2);
  Alcotest.(check (pair int int)) "complete reload allows expiry and cascade"
    (1, 2) (Masc_board_handlers.Board_core.sweep store);
  Board.flush_dirty store;
  let reloaded = Masc_board_handlers.Board_core.create_store
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
  let store = Masc_board_handlers.Board_core.create_store ~base_path:(Env_config_core.base_path ()) () in
  load_sources store;
  let post =
    match
      Masc_board_handlers.Board_core.create_post store ~lookup:nobody_declared ~author:"fixture-author"
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

let test_reload_deduplicates_comments_and_skips_blank_lines () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let _dir = fresh_test_base_path () in
  let store =
    Masc_board_handlers.Board_core.create_store ~base_path:(Env_config_core.base_path ()) ()
  in
  load_sources store;
  let post =
    match
      Masc_board_handlers.Board_core.create_post store ~lookup:nobody_declared
        ~author:"fixture-author" ~content:"post with duplicate comment rows"
        ~post_kind:Board.Human_post ()
    with
    | Ok post -> post
    | Error error ->
      Alcotest.failf "create_post failed: %s" (Board.Post_publication_failure.to_string error)
  in
  let post_id = Board.Post_id.to_string post.id in
  let add_comment content =
    match
      Masc_board_handlers.Board_core.add_comment ~reader:Masc_board_handlers.Board_access.Operator
        store ~lookup:nobody_declared ~post_id ~author:"fixture-author" ~content ()
    with
    | Ok comment -> comment
    | Error error -> Alcotest.failf "add_comment failed: %s" (Board.show_board_error error)
  in
  let c1 = add_comment "first comment" in
  let c2 = add_comment "second comment" in
  let c1_updated = { c1 with content = "first comment updated" } in
  let posts_path = Board.persist_path store in
  let comments_path = Board.comments_path store in
  Out_channel.with_open_bin posts_path (fun out ->
    output_string out "  \t\r\n";
    output_string out (Yojson.Safe.to_string (Masc_board_handlers.Board_core.post_to_yojson post) ^ "\n");
    output_string out "\n");
  Out_channel.with_open_bin comments_path (fun out ->
    output_string out "  \t\012\r\n";
    output_string out (Yojson.Safe.to_string (Masc_board_handlers.Board_core.comment_to_yojson c1) ^ "\n");
    output_string out "   \n";
    output_string out (Yojson.Safe.to_string (Masc_board_handlers.Board_core.comment_to_yojson c2) ^ "\n");
    output_string out (Yojson.Safe.to_string (Masc_board_handlers.Board_core.comment_to_yojson c1_updated) ^ "\n"));
  let reloaded =
    Masc_board_handlers.Board_core.create_store ~base_path:(Env_config_core.base_path ()) ()
  in
  (match Masc_board_handlers.Board_votes_json.load_persisted_posts reloaded with
   | Ok 1 -> ()
   | Ok n -> Alcotest.failf "expected Ok 1 post, got Ok %d" n
   | Error (path, exn) ->
     Alcotest.failf "load_persisted_posts failed: %s (%s)" path (Printexc.to_string exn));
  (match Masc_board_handlers.Board_votes_json.load_persisted_comments reloaded with
   | Ok 3 -> ()
   | Ok n -> Alcotest.failf "expected Ok 3 comment rows, got Ok %d" n
   | Error (path, exn) ->
     Alcotest.failf "load_persisted_comments failed: %s (%s)" path (Printexc.to_string exn));
  Alcotest.(check int) "deduplicated comments table holds 2 entries"
    2 (Hashtbl.length reloaded.comments);
  let indexed_ids =
    match Hashtbl.find_opt reloaded.comments_by_post post_id with
    | Some ids -> List.sort String.compare ids
    | None -> []
  in
  let c1_id = Board.Comment_id.to_string c1.id in
  let c2_id = Board.Comment_id.to_string c2.id in
  Alcotest.(check (list string)) "comments_by_post holds exact unique ids"
    (List.sort String.compare [ c1_id; c2_id ]) indexed_ids;
  (match Hashtbl.find_opt reloaded.comments c1_id with
   | Some c ->
     Alcotest.(check string) "latest duplicate comment row wins"
       "first comment updated" c.content
   | None -> Alcotest.fail "first comment missing after reload");
  (match Hashtbl.find_opt reloaded.comments c2_id with
   | Some c ->
     Alcotest.(check string) "second comment preserved" "second comment" c.content
   | None -> Alcotest.fail "second comment missing after reload")
;;

(* #55465: a refused source stayed refused until a restart, also after what
   refused it was repaired. [Board.reobserve] is what every Board operation
   runs when it takes the store. A read notes what the directory says of the
   source's file and of the lock file beside it before it does anything else,
   and its refusal carries the two entries. The source is read again once
   either is different, and not while both stay as they are. A refusal no
   read made carries nothing and is read again at the next call. *)
module Paths = Masc_board_handlers.Board_paths

type refused_source =
  { name : string
  ; file : Paths.persisted_file
  ; path : Board.store -> string
  ; create :
      base_path:string
      -> io:Fs_compat.private_jsonl_transaction_io_for_testing
      -> unit
      -> Board.store
  ; readable : Board.store -> bool
  }

let refused_sources =
  [ { name = "posts"
    ; file = Paths.Posts
    ; path = Board.persist_path
    ; create =
        (fun ~base_path ~io () ->
          Board.create_store_with_source_io_for_testing ~base_path ~io:{ posts = Some io } ())
    ; readable =
        (fun store ->
          match store.Board.posts_source with
          | Board.Posts_readable _ -> true
          | Board.Posts_unobserved | Board.Posts_refused _ | Board.Posts_unsettled _ -> false)
    }
  ; { name = "comments"
    ; file = Paths.Comments
    ; path = Board.comments_path
    ; create = Board.create_store_with_comments_io_for_testing
    ; readable =
        (fun store ->
          match store.Board.comments_source with
          | Board.Comments_readable _ -> true
          | Board.Comments_unobserved | Board.Comments_publishing _
          | Board.Comments_recovered _ | Board.Comments_refused _
          | Board.Comments_unsettled _ -> false)
    }
  ; { name = "votes"
    ; file = Paths.Votes
    ; path = Board.vote_log_path
    ; create = Board.create_store_with_votes_io_for_testing
    ; readable =
        (fun store ->
          match store.Board.votes_source with
          | Board.Votes_readable _ -> true
          | Board.Votes_unobserved | Board.Votes_publishing _ | Board.Votes_refused _
          | Board.Votes_unsettled _ -> false)
    }
  ; { name = "reactions"
    ; file = Paths.Reactions
    ; path = Board.reactions_path
    ; create = Board.create_store_with_reactions_io_for_testing
    ; readable =
        (fun store ->
          match store.Board.reactions_source with
          | Board.Reactions_readable _ -> true
          | Board.Reactions_unobserved | Board.Reactions_publishing _
          | Board.Reactions_refused _ | Board.Reactions_unsettled _ -> false)
    }
  ; { name = "sub-boards"
    ; file = Paths.Sub_boards
    ; path = Board.sub_boards_path
    ; create = Board.create_store_with_sub_boards_io_for_testing
    ; readable =
        (fun store ->
          match store.Board.sub_boards_source with
          | Board.Policy_readable _ -> true
          | Board.Policy_unobserved | Board.Policy_publishing _ | Board.Policy_refused _
          | Board.Policy_unsettled _ -> false)
    }
  ]
;;

(* [damage] leaves a file a read refuses, [damage_again] changes what the
   directory says of that file and leaves it refused, [repair] leaves a file a
   read accepts, or none. *)
type damaged_file =
  { cause : string
  ; damage : string -> unit
  ; damage_again : string -> unit
  ; repair : string -> unit
  }

let write_file path text = Out_channel.with_open_bin path (fun out -> output_string out text)

let torn_last_line (_ : string) =
  { cause = "a torn last line"
  ; damage = (fun path -> write_file path "{torn")
  ; damage_again = (fun path -> write_file path "{torn again")
  ; repair = (fun path -> write_file path "")
  }
;;

(* The file that takes the place of the first has its size and its kind: it
   is another file, and only that tells the two apart for certain. *)
let replaced_by_a_file_of_the_same_size dir =
  let staged = Filename.concat dir "staged-replacement" in
  { cause = "a torn last line and then a file of the same size in its place"
  ; damage = (fun path -> write_file path "{torn")
  ; damage_again = (fun path -> write_file staged "{t0rn"; Unix.rename staged path)
  ; repair = (fun path -> write_file path "")
  }
;;

(* Removing the links changes neither the file's bytes nor its modification
   time: only its link count tells the repaired file from the refused one. *)
let second_hard_link dir =
  let link n = Filename.concat dir (Printf.sprintf "second-link-%d" n) in
  { cause = "a second hard link"
  ; damage = (fun path -> write_file path ""; Unix.link path (link 1))
  ; damage_again = (fun path -> Unix.link path (link 2))
  ; repair = (fun (_ : string) -> Unix.unlink (link 1); Unix.unlink (link 2))
  }
;;

(* A directory is not a file a source reads. Its mode is the change here, and
   once it is removed the source has no file, which a read accepts as empty. *)
let directory_in_its_place (_ : string) =
  { cause = "a directory in its place"
  ; damage = (fun path -> Unix.mkdir path 0o700)
  ; damage_again = (fun path -> Unix.chmod path 0o750)
  ; repair = Unix.rmdir
  }
;;

let in_fresh_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let previous = Sys.getenv_opt "MASC_BASE_PATH" in
  let dir = fresh_test_base_path () in
  Fun.protect ~finally:(fun () ->
    Unix.putenv "MASC_BASE_PATH" (Option.value ~default:"" previous);
    if Sys.file_exists dir then Fs_compat.remove_tree dir) (fun () -> f dir)
;;

(* One source of a store that has not been loaded yet. Every descriptor the
   source's file transactions close passes [closes], so an unchanged count
   means the source opened no file. [read_and_still_refused ()] runs the read
   every Board operation starts from and says whether it reported this source:
   a source is reported when it was read and is still refused, so a refused
   source that is not reported was not read. *)
type watched_source =
  { board : Board.store
  ; data : string
  ; lock : string
  ; closes : int ref
  ; read_and_still_refused : unit -> bool
  }

let watched_source source dir =
  let closes = ref 0 in
  let io : Fs_compat.private_jsonl_transaction_io_for_testing =
    { before_sync_parent = (fun _ -> ())
    ; close_fd = (fun fd -> incr closes; Unix.close fd)
    }
  in
  let board = source.create ~base_path:dir ~io () in
  let data = source.path board in
  Fs_compat.mkdir_p (Filename.dirname data);
  { board
  ; data
  ; lock = Fs_compat.private_jsonl_lock_path data
  ; closes
  ; read_and_still_refused =
      (fun () ->
        List.exists
          (fun (file, (_ : Board.board_error)) -> file = source.file)
          (Board.reobserve board))
  }
;;

let test_refused_source_is_read_again_when_its_file_changes source damaged () =
  in_fresh_workspace @@ fun dir ->
  let damaged = damaged dir in
  let watched = watched_source source dir in
  damaged.damage watched.data;
  Alcotest.(check bool) "the load reports the damaged source" true
    (Result.is_error (Board.initialize_store watched.board));
  Alcotest.(check bool) "the damaged source is refused" false (source.readable watched.board);
  (* The load's read is the first in this workspace, and the first read of a
     file creates the lock file beside it. The call after the load can find
     that change and read once more; what it does is not asserted. From the
     call after that one, both entries are what the last read found. *)
  ignore (watched.read_and_still_refused () : bool);
  let settled = !(watched.closes) in
  Alcotest.(check bool) "an unchanged file is not due" false
    (watched.read_and_still_refused ());
  Alcotest.(check int) "an unchanged file is not read again" settled !(watched.closes);
  damaged.damage_again watched.data;
  Alcotest.(check bool) "a changed file that is still damaged stays refused" true
    (watched.read_and_still_refused ());
  let changed = !(watched.closes) in
  Alcotest.(check bool) "the changed file was read" true (changed > settled);
  Alcotest.(check bool) "the same damage is not due a second time" false
    (watched.read_and_still_refused ());
  Alcotest.(check int) "the same damage is read once" changed !(watched.closes);
  damaged.repair watched.data;
  Alcotest.(check bool) "the repaired file is not reported" false
    (watched.read_and_still_refused ());
  let repaired = !(watched.closes) in
  Alcotest.(check bool) "the repaired file was read" true (repaired > changed);
  Alcotest.(check bool) "the repaired source is readable without a restart" true
    (source.readable watched.board);
  Alcotest.(check bool) "a readable source is not due" false
    (watched.read_and_still_refused ());
  Alcotest.(check int) "a readable source is not read again" repaired !(watched.closes)
;;

(* [damage_lock] leaves a lock file no file transaction accepts, [repair_lock]
   one it does. Neither touches the source's file. *)
type damaged_lock =
  { lock_cause : string
  ; damage_lock : string -> unit
  ; repair_lock : string -> unit
  }

(* A lock file a transaction would have created and not yet marked ready. *)
let new_lock_file lock =
  Unix.close (Unix.openfile lock [ Unix.O_CREAT; Unix.O_EXCL; Unix.O_WRONLY ] 0o600);
  Unix.chmod lock 0o600
;;

let lock_is_a_directory (_ : string) =
  { lock_cause = "a directory"
  ; damage_lock = (fun lock -> Unix.mkdir lock 0o700)
  ; repair_lock = Unix.rmdir
  }
;;

let lock_has_a_second_hard_link dir =
  let link = Filename.concat dir "second-lock-link" in
  { lock_cause = "a file with a second hard link"
  ; damage_lock = (fun lock -> new_lock_file lock; Unix.link lock link)
  ; repair_lock = (fun (_ : string) -> Unix.unlink link)
  }
;;

(* Setting the mode back changes neither the lock file's bytes nor its
   modification time: only its mode tells the repaired lock file from the
   refused one. *)
let lock_has_the_wrong_mode (_ : string) =
  { lock_cause = "a file with the wrong mode"
  ; damage_lock = (fun lock -> new_lock_file lock; Unix.chmod lock 0o640)
  ; repair_lock = (fun lock -> Unix.chmod lock 0o600)
  }
;;

(* The lock file is in the way before the load, so the load's read creates
   nothing and both entries are what that read found: the call after the load
   does not read. The source has no file yet. One that appears is read, and
   the lock file refuses that read too. Repairing the lock file is then the
   only change, and the source's file is what the refused read found. *)
let test_refused_source_is_read_again_when_its_lock_file_is_repaired source damaged () =
  in_fresh_workspace @@ fun dir ->
  let damaged = damaged dir in
  let watched = watched_source source dir in
  damaged.damage_lock watched.lock;
  Alcotest.(check bool) "the load reports the source behind the lock file" true
    (Result.is_error (Board.initialize_store watched.board));
  Alcotest.(check bool) "the source behind the lock file is refused" false
    (source.readable watched.board);
  Alcotest.(check bool) "the load created no file for the source" false
    (Sys.file_exists watched.data);
  let loaded = !(watched.closes) in
  Alcotest.(check bool) "nothing changed since the load: not due" false
    (watched.read_and_still_refused ());
  Alcotest.(check int) "nothing changed since the load: no file opened" loaded
    !(watched.closes);
  write_file watched.data "";
  Alcotest.(check bool) "the file that appeared is read and the lock file refuses it" true
    (watched.read_and_still_refused ());
  let appeared = !(watched.closes) in
  Alcotest.(check bool) "the lasting cause is not due a second time" false
    (watched.read_and_still_refused ());
  Alcotest.(check int) "the lasting cause opens no file a second time" appeared
    !(watched.closes);
  damaged.repair_lock watched.lock;
  Alcotest.(check bool) "the source behind the repaired lock file is not reported" false
    (watched.read_and_still_refused ());
  Alcotest.(check bool) "the source is readable without a restart" true
    (source.readable watched.board)
;;

(* While a Board deletion needs a fresh store, no source is read again
   ([Board_core_persist.require_model_reload_allowed]). A source that waits
   for its file to change is then left as it is: not read and not reported,
   and asked again once the deletion is over. The deletion state is one a
   test can write by hand; that guard answers the same for a pending one. *)
let test_refused_source_is_left_as_it_is_while_a_deletion_is_pending source () =
  in_fresh_workspace @@ fun dir ->
  let damaged = torn_last_line dir in
  let watched = watched_source source dir in
  damaged.damage watched.data;
  Alcotest.(check bool) "the load reports the damaged source" true
    (Result.is_error (Board.initialize_store watched.board));
  Alcotest.(check bool) "the damaged source is refused" false (source.readable watched.board);
  let settled = watched.board.Board.deletion_state in
  watched.board.Board.deletion_state <-
    Board.Deletion_refused
      { last_observed = None; failure = Board.Deletion_marker_missing; diagnostics = [] };
  damaged.repair watched.data;
  let before = !(watched.closes) in
  Alcotest.(check bool) "the repaired source is not reported while the deletion is pending"
    false (watched.read_and_still_refused ());
  Alcotest.(check int) "no file is opened while the deletion is pending" before
    !(watched.closes);
  Alcotest.(check bool) "the source stays refused while the deletion is pending" false
    (source.readable watched.board);
  watched.board.Board.deletion_state <- settled;
  Alcotest.(check bool) "the repaired source is not reported once the deletion is over" false
    (watched.read_and_still_refused ());
  Alcotest.(check bool) "the repaired source is readable once the deletion is over" true
    (source.readable watched.board)
;;

(* A store with a loaded Board, one post in it, and a comment writer. *)
let comment_writer dir =
  let new_store () =
    let store = Masc_board_handlers.Board_core.create_store ~base_path:dir () in
    load_sources store;
    store
  in
  let first = new_store () in
  let post =
    match
      Masc_board_handlers.Board_core.create_post first ~lookup:nobody_declared
        ~author:"source-writer" ~content:"shared parent" ~post_kind:Board.Human_post ()
    with
    | Ok post -> post
    | Error error ->
      Alcotest.failf "create_post failed: %s" (Board.Post_publication_failure.to_string error)
  in
  let comment store content =
    Masc_board_handlers.Board_core.add_comment ~reader:Masc_board_handlers.Board_access.Operator
      store ~lookup:nobody_declared ~post_id:(Board.Post_id.to_string post.id)
      ~author:"source-writer" ~content ()
  in
  new_store, first, comment
;;

let accepted what = function
  | Ok (_ : Board.comment) -> ()
  | Error error -> Alcotest.failf "%s: %s" what (Board.show_board_error error)
;;

let comments_readable store =
  match store.Board.comments_source with
  | Board.Comments_readable _ -> true
  | Board.Comments_unobserved | Board.Comments_publishing _ | Board.Comments_recovered _
  | Board.Comments_refused _ | Board.Comments_unsettled _ -> false
;;

let comments_read_and_still_refused store =
  List.exists
    (fun (file, (_ : Board.board_error)) -> file = Paths.Comments)
    (Board.reobserve store)
;;

(* A refusal a write made carries nothing a read saw, so the next call reads
   whatever the directory says. The store here has only read the comments
   file, and once the second name is removed the file is what that read
   found: compared with that read the source would never be due. *)
let test_source_refused_by_a_write_is_read_at_the_next_call () =
  in_fresh_workspace @@ fun dir ->
  let new_store, first, comment = comment_writer dir in
  accepted "the first store's comment" (comment first "the first store's comment");
  let store = new_store () in
  let second_name = Filename.concat dir "comments-second-name" in
  Unix.link (Board.comments_path store) second_name;
  Alcotest.(check bool) "a comment is refused while the file has a second name" true
    (Result.is_error (comment store "refused while the file has a second name"));
  Alcotest.(check bool) "the refused write leaves the comments refused" false
    (comments_readable store);
  Unix.unlink second_name;
  Alcotest.(check bool) "the next call reads and does not report the comments" false
    (comments_read_and_still_refused store);
  Alcotest.(check bool) "the comments are readable without a restart" true
    (comments_readable store);
  accepted "a comment after the read" (comment store "accepted after the read")
;;

(* A read again that fails on the lock file replaces the refusal it was run
   for. The first refusal here is a stale cursor, which is read again at every
   call; the read meets a lock file with the wrong mode and leaves that as the
   cause, with the two entries it saw. While the mode stays wrong the source
   is not read at every call, and once it is set back the source is read
   though its own file is what the refused read found. *)
let test_read_again_refused_by_the_lock_file_waits_for_the_lock_file () =
  in_fresh_workspace @@ fun dir ->
  let new_store, stale, comment = comment_writer dir in
  accepted "this store's comment" (comment stale "this store's comment");
  let other = new_store () in
  accepted "another writer's comment" (comment other "another writer's comment");
  Alcotest.(check bool) "the stale cursor refuses the next comment" true
    (Result.is_error (comment stale "refused against the stale cursor"));
  let lock = Fs_compat.private_jsonl_lock_path (Board.comments_path stale) in
  Unix.chmod lock 0o640;
  Alcotest.(check bool) "the read again fails on the lock file's mode" true
    (comments_read_and_still_refused stale);
  Alcotest.(check bool) "while the mode stays wrong the source is not read again" false
    (comments_read_and_still_refused stale);
  Alcotest.(check bool) "and it stays refused" false (comments_readable stale);
  Unix.chmod lock 0o600;
  Alcotest.(check bool) "once the mode is set back the source is read and cleared" false
    (comments_read_and_still_refused stale);
  accepted "a comment after the second read" (comment stale "accepted after the second read")
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
        ; Alcotest.test_case
            "reload deduplicates comments and skips blank lines"
            `Quick
            test_reload_deduplicates_comments_and_skips_blank_lines
        ] )
    ; ( "refused_source_and_its_file"
      , List.concat_map
          (fun source ->
             List.map
               (fun damaged ->
                  Alcotest.test_case
                    (Printf.sprintf "%s refused for %s are read again when the file changes"
                       source.name (damaged "").cause)
                    `Quick
                    (test_refused_source_is_read_again_when_its_file_changes source damaged))
               [ torn_last_line
               ; replaced_by_a_file_of_the_same_size
               ; second_hard_link
               ; directory_in_its_place
               ]
             @ List.map
                 (fun damaged ->
                    Alcotest.test_case
                      (Printf.sprintf
                         "%s behind a lock file that is %s are read again once it is repaired"
                         source.name (damaged "").lock_cause)
                      `Quick
                      (test_refused_source_is_read_again_when_its_lock_file_is_repaired source
                         damaged))
                 [ lock_is_a_directory; lock_has_a_second_hard_link; lock_has_the_wrong_mode ]
             @ [ Alcotest.test_case
                   (Printf.sprintf "%s are left as they are while a deletion is pending"
                      source.name)
                   `Quick
                   (test_refused_source_is_left_as_it_is_while_a_deletion_is_pending source)
               ])
          refused_sources
        @ [ Alcotest.test_case
              "comments a write refused are read at the next call"
              `Quick
              test_source_refused_by_a_write_is_read_at_the_next_call
          ; Alcotest.test_case
              "a read again the lock file refused waits for the lock file"
              `Quick
              test_read_again_refused_by_the_lock_file_waits_for_the_lock_file
          ] )
    ]
;;
