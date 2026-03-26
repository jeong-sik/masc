(** test_board_ttl.ml - Board TTL and permanent post tests *)

open Masc_mcp.Board

let () =
  Mirage_crypto_rng_unix.use_default ();

  Printf.printf "\n=== Board TTL Tests ===\n";

  (* Test 1: Default TTL is 0 (permanent) - no Eio needed *)
  let test_default_ttl () =
    assert (Limits.default_ttl_hours = 0);
    Printf.printf "✓ default_ttl_hours is 0 (permanent)\n"
  in

  (* Run pure test first *)
  test_default_ttl ();

  (* Eio-dependent tests *)
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);

  (* Test 2: Create permanent post (default) *)
  let test_permanent_post () =
    let store = create_store () in
    match create_post store ~author:"test-agent" ~content:"Permanent post" () with
    | Ok post ->
        assert (post.expires_at = 0.0);
        Printf.printf "✓ Permanent post has expires_at = 0.0\n"
    | Error e ->
        Printf.printf "✗ Failed to create post: %s\n" (show_board_error e);
        assert false
  in

  (* Test 3: Create post with explicit TTL *)
  let test_expiring_post () =
    let store = create_store () in
    match create_post store ~author:"test-agent" ~content:"Expiring post" ~ttl_hours:24 () with
    | Ok post ->
        assert (post.expires_at > 0.0);
        Printf.printf "✓ Expiring post has expires_at > 0.0 (%.0f)\n" post.expires_at
    | Error e ->
        Printf.printf "✗ Failed to create post: %s\n" (show_board_error e);
        assert false
  in

  (* Test 4: Sweeper skips permanent posts *)
  let test_sweeper_skips_permanent () =
    let store = create_store () in
    (* Create permanent post *)
    let _ = create_post store ~author:"test-agent" ~content:"Permanent" () in
    (* Run sweep *)
    let (removed_posts, _) = sweep store in
    assert (removed_posts = 0);
    Printf.printf "✓ Sweeper removed 0 permanent posts\n"
  in

  let test_post_kind_human_default () =
    let store = create_store () in
    match create_post store ~author:"test-agent" ~content:"Human post" () with
    | Ok post ->
        let json = post_to_yojson post in
        let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
        assert (String.equal kind "human");
        Printf.printf "✓ Default board post kind is human\n"
    | Error e ->
        Printf.printf "✗ Failed to create human post: %s\n" (show_board_error e);
        assert false
  in

  let test_post_kind_automation_contract () =
    let store = create_store () in
    match create_post store ~author:"dashboard-harness-bot" ~content:"Harness post"
            ~visibility:Internal ~ttl_hours:1 ~hearth:"dashboard-harness" () with
    | Ok post ->
        let json = post_to_yojson post in
        let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
        assert (String.equal kind "automation");
        Printf.printf "✓ Harness metadata classifies post as automation\n"
    | Error e ->
        Printf.printf "✗ Failed to create automation post: %s\n" (show_board_error e);
        assert false
  in

  let test_post_kind_system_author () =
    let store = create_store () in
    match create_post store ~author:"lodge-system" ~content:"System post" () with
    | Ok post ->
        let json = post_to_yojson post in
        let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
        assert (String.equal kind "system");
        Printf.printf "✓ System author classifies post as system\n"
    | Error e ->
        Printf.printf "✗ Failed to create system post: %s\n" (show_board_error e);
        assert false
  in

  (* Run Eio tests *)
  test_permanent_post ();
  test_expiring_post ();
  test_sweeper_skips_permanent ();
  test_post_kind_human_default ();
  test_post_kind_automation_contract ();
  test_post_kind_system_author ();

  Printf.printf "\n✅ All Board TTL tests passed!\n\n"
