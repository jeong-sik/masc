module Board = Masc.Board
module Rows = Masc_board_handlers.Board_votes_json
module Paths = Masc_board_handlers.Board_paths
module Preparation = Masc_test_deps.Board_test_preparation

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name))
      (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_fixture test () =
  let base = Unix.realpath (Filename.temp_dir "board-preparation-" "") in
  Fs_compat.clear_fs ();
  Fun.protect
    ~finally:(fun () -> Fs_compat.clear_fs (); remove_tree base)
    (fun () -> Eio_main.run (fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       test base))

let posts_path base_path =
  let workspace_masc_dir = Common.masc_dir_from_base_path ~base_path in
  Paths.posts_file ~workspace_masc_dir

let read_bytes path = In_channel.with_open_bin path In_channel.input_all

let load expected store =
  match Rows.load_persisted_posts store with
  | Ok actual -> Alcotest.(check int) "explicit posts load" expected actual
  | Error (path, cause) ->
    Alcotest.failf "load %s: %s" path (Printexc.to_string cause)

let create store body =
  match Board.create_post store
      ~lookup:Masc_board_handlers.Recipient_lookup.none_declared
      ~author:"prepared-author" ~content:body ~title:"prepared title" ~body
      ~post_kind:Board.Human_post ~ttl_hours:0 () with
  | Ok post -> post
  | Error failure ->
    Alcotest.fail (Board.Post_publication_failure.to_string failure)

let check_post store (expected : Board.post) =
  let post_id = Board.Post_id.to_string expected.id in
  match Board.read_post store ~post_id with
  | Ok actual ->
    Alcotest.(check string) "actual producer ID survived reload" post_id
      (Board.Post_id.to_string actual.id);
    Alcotest.(check string) "actual producer body survived reload"
      expected.body actual.body
  | Error _ -> Alcotest.fail "prepared post is absent after explicit reload"

let test_bootstrap base_path =
  Preparation.prepare ~base_path ~action:Preparation.Bootstrap;
  let store = Board.create_store ~base_path () in
  load 0 store;
  let post = create store "published after explicit bootstrap" in
  let restarted = Board.create_store ~base_path () in
  load 1 restarted;
  check_post restarted post

let test_adopt root =
  let producer = Filename.concat root "producer" in
  let destination = Filename.concat root "destination" in
  Unix.mkdir producer 0o700;
  Unix.mkdir destination 0o700;
  Preparation.prepare ~base_path:producer ~action:Preparation.Bootstrap;
  let store = Board.create_store ~base_path:producer () in
  load 0 store;
  let post = create store "raw producer bytes survive explicit adoption" in
  let bytes = " \t\n" ^ read_bytes (posts_path producer) ^ "\n" in
  Unix.mkdir (Common.masc_dir_from_base_path ~base_path:destination) 0o700;
  Out_channel.with_open_bin (posts_path destination)
    (fun channel -> output_string channel bytes);
  Preparation.prepare ~base_path:destination ~action:Preparation.Adopt;
  Alcotest.(check string) "adoption preserves the exact raw posts bytes"
    bytes (read_bytes (posts_path destination));
  let adopted = Board.create_store ~base_path:destination () in
  load 1 adopted;
  check_post adopted post

let () =
  let case label test = Alcotest.test_case label `Quick (with_fixture test) in
  Alcotest.run "board_preparation" [
    "explicit initialization", [
      case "bootstrapped posts survive a fresh store" test_bootstrap;
      case "adopted producer bytes and post survive reload" test_adopt;
    ];
  ]
