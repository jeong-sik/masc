(** test_board_ttl.ml - Board TTL and permanent post tests *)

open Masc_mcp.Board

let () =
  Mirage_crypto_rng_unix.use_default ();

  Printf.printf "\n=== Board TTL Tests ===\n";
  let fail_board_test label error =
    failwith (Printf.sprintf "%s: %s" label (show_board_error error))
  in

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
    match
      create_post store ~author:"test-agent" ~content:"Permanent post"
        ~post_kind:Human_post ()
    with
    | Ok post ->
        assert (post.expires_at = 0.0);
        Printf.printf "✓ Permanent post has expires_at = 0.0\n"
    | Error e -> fail_board_test "Failed to create post" e
  in

  (* Test 3: Create post with explicit TTL *)
  let test_expiring_post () =
    let store = create_store () in
    match
      create_post store ~author:"test-agent" ~content:"Expiring post"
        ~post_kind:Human_post ~ttl_hours:24 ()
    with
    | Ok post ->
        assert (post.expires_at > 0.0);
        Printf.printf "✓ Expiring post has expires_at > 0.0 (%.0f)\n" post.expires_at
    | Error e -> fail_board_test "Failed to create expiring post" e
  in

  (* Test 4: Sweeper skips permanent posts *)
  let test_sweeper_skips_permanent () =
    let store = create_store () in
    (* Create permanent post *)
    (match create_post store ~author:"test-agent" ~content:"Permanent"
             ~post_kind:Human_post () with
     | Ok _ -> ()
     | Error e ->
         fail_board_test "Failed to create permanent post for sweep test" e);
    (* Run sweep *)
    let (removed_posts, _) = sweep store in
    assert (removed_posts = 0);
    Printf.printf "✓ Sweeper removed 0 permanent posts\n"
  in

  let test_post_kind_direct_default () =
    let store = create_store () in
    match
      create_post store ~author:"test-agent" ~content:"Human post"
        ~post_kind:Human_post ()
    with
    | Ok post ->
        let json = post_to_yojson post in
        let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
        let reason =
          Yojson.Safe.Util.(json |> member "classification_reason" |> to_string)
        in
        assert (String.equal kind "direct");
        assert
          (String.equal reason "Direct board post without automation provenance.");
        Printf.printf "✓ Default board post kind is direct\n"
    | Error e -> fail_board_test "Failed to create direct post" e
  in

  let test_post_kind_automation_contract () =
    let store = create_store () in
    match create_post store ~author:"dashboard-harness-bot" ~content:"Harness post"
            ~visibility:Internal ~ttl_hours:1 ~hearth:"dashboard-harness"
            ~post_kind:Automation_post () with
    | Ok post ->
        let json = post_to_yojson post in
        let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
        assert (String.equal kind "automation");
        Printf.printf "✓ Explicit automation contract is preserved\n"
    | Error e -> fail_board_test "Failed to create automation post" e
  in

  let test_post_kind_system_contract () =
    let store = create_store () in
    match create_post store ~author:"operator" ~content:"System post"
            ~post_kind:System_post () with
    | Ok post ->
        let json = post_to_yojson post in
        let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
        assert (String.equal kind "system");
        Printf.printf "✓ Explicit system contract is preserved\n"
    | Error e -> fail_board_test "Failed to create system post" e
  in

  let test_post_kind_prefers_explicit_judgment () =
    let store = create_store () in
    let summary =
      "LLM judged this as automation because it summarizes a completed keeper background run."
    in
    let meta =
      `Assoc
        [
          ("source", `String "keeper_board_post");
          ( "judgment",
            `Assoc
              [
                ("summary", `String summary);
                ("confidence", `Float 0.82);
              ] );
        ]
    in
    match
      create_post store ~author:"dm-keeper" ~content:"Keeper board post"
        ~post_kind:Automation_post ~meta_json:meta ()
    with
    | Ok post ->
        let json = post_to_yojson post in
        let reason =
          Yojson.Safe.Util.(json |> member "classification_reason" |> to_string)
        in
        assert (String.equal reason summary);
        Printf.printf "✓ Explicit judgment summary overrides fallback reason\n"
    | Error e -> fail_board_test "Failed to create judged keeper post" e
  in

  let test_post_kind_keeper_provenance_upgrade () =
    let store = create_store () in
    let meta = `Assoc [ ("source", `String "keeper_board_post") ] in
    match
      create_post store ~author:"dm-keeper" ~content:"Keeper board post"
        ~post_kind:Automation_post ~meta_json:meta ()
    with
    | Ok post ->
        assert (classify_post_kind post = Automation_post);
        let json = post_to_yojson post in
        let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
        let reason =
          Yojson.Safe.Util.(json |> member "classification_reason" |> to_string)
        in
        assert (String.equal kind "automation");
        assert
          (String.equal reason
             "Automation classification based on source=keeper_board_post, author=dm-keeper, and the automation post_kind contract.");
        Printf.printf "✓ Keeper provenance preserves automation post kind\n"
    | Error e -> fail_board_test "Failed to create keeper provenance post" e
  in

  (* Run Eio tests *)
  test_permanent_post ();
  test_expiring_post ();
  test_sweeper_skips_permanent ();
  test_post_kind_direct_default ();
  test_post_kind_prefers_explicit_judgment ();
  test_post_kind_automation_contract ();
  test_post_kind_system_contract ();
  test_post_kind_keeper_provenance_upgrade ();

  Printf.printf "\n✅ All Board TTL tests passed!\n\n"
