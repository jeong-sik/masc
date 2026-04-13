(** test_board_ttl.ml - Board TTL, permanent post, and post_kind classification tests *)

open Masc_mcp.Board

let () = Mirage_crypto_rng_unix.use_default ()

let with_eio f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  f ()

let test_default_ttl () =
  Alcotest.(check int) "default_ttl_hours is 0" 0 Limits.default_ttl_hours

let test_permanent_post () =
  let store = create_store () in
  match
    create_post store ~author:"test-agent" ~content:"Permanent post"
      ~post_kind:Human_post ()
  with
  | Ok post ->
      Alcotest.(check (float 0.0)) "expires_at = 0.0" 0.0 post.expires_at
  | Error e -> Alcotest.fail (show_board_error e)

let test_expiring_post () =
  let store = create_store () in
  match
    create_post store ~author:"test-agent" ~content:"Expiring post"
      ~post_kind:Human_post ~ttl_hours:24 ()
  with
  | Ok post ->
      Alcotest.(check bool) "expires_at > 0.0" true (post.expires_at > 0.0)
  | Error e -> Alcotest.fail (show_board_error e)

let test_sweeper_skips_permanent () =
  let store = create_store () in
  (match
     create_post store ~author:"test-agent" ~content:"Permanent"
       ~post_kind:Human_post ()
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (show_board_error e));
  let (removed_posts, _) = sweep store in
  Alcotest.(check int) "sweeper removed 0 permanent posts" 0 removed_posts

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
      Alcotest.(check string) "kind is direct" "direct" kind;
      Alcotest.(check string) "reason"
        "Direct board post without automation provenance." reason
  | Error e -> Alcotest.fail (show_board_error e)

let test_post_kind_automation_contract () =
  let store = create_store () in
  match
    create_post store ~author:"dashboard-harness-bot" ~content:"Harness post"
      ~visibility:Internal ~ttl_hours:1 ~hearth:"dashboard-harness"
      ~post_kind:Automation_post ()
  with
  | Ok post ->
      let json = post_to_yojson post in
      let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
      Alcotest.(check string) "kind is automation" "automation" kind
  | Error e -> Alcotest.fail (show_board_error e)

let test_post_kind_system_contract () =
  let store = create_store () in
  match
    create_post store ~author:"operator" ~content:"System post"
      ~post_kind:System_post ()
  with
  | Ok post ->
      let json = post_to_yojson post in
      let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
      Alcotest.(check string) "kind is system" "system" kind
  | Error e -> Alcotest.fail (show_board_error e)

let test_post_kind_prefers_explicit_judgment () =
  let store = create_store () in
  let summary =
    "LLM judged this as automation because it summarizes a completed keeper \
     background run."
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
      Alcotest.(check string) "judgment summary overrides fallback" summary
        reason
  | Error e -> Alcotest.fail (show_board_error e)

let test_post_kind_keeper_provenance_upgrade () =
  let store = create_store () in
  let meta = `Assoc [ ("source", `String "keeper_board_post") ] in
  match
    create_post store ~author:"dm-keeper" ~content:"Keeper board post"
      ~post_kind:Automation_post ~meta_json:meta ()
  with
  | Ok post ->
      Alcotest.(check bool) "classified as automation" true
        (classify_post_kind post = Automation_post);
      let json = post_to_yojson post in
      let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
      let reason =
        Yojson.Safe.Util.(json |> member "classification_reason" |> to_string)
      in
      Alcotest.(check string) "kind is automation" "automation" kind;
      Alcotest.(check string) "provenance reason"
        "Automation classification based on source=keeper_board_post, \
         author=dm-keeper, and the automation post_kind contract."
        reason
  | Error e -> Alcotest.fail (show_board_error e)

let () =
  Alcotest.run "Board_TTL"
    [
      ( "ttl",
        [
          Alcotest.test_case "default TTL is 0" `Quick test_default_ttl;
          Alcotest.test_case "permanent post" `Quick
            (with_eio test_permanent_post);
          Alcotest.test_case "expiring post" `Quick
            (with_eio test_expiring_post);
          Alcotest.test_case "sweeper skips permanent" `Quick
            (with_eio test_sweeper_skips_permanent);
        ] );
      ( "post_kind",
        [
          Alcotest.test_case "direct default" `Quick
            (with_eio test_post_kind_direct_default);
          Alcotest.test_case "automation contract" `Quick
            (with_eio test_post_kind_automation_contract);
          Alcotest.test_case "system contract" `Quick
            (with_eio test_post_kind_system_contract);
          Alcotest.test_case "prefers explicit judgment" `Quick
            (with_eio test_post_kind_prefers_explicit_judgment);
          Alcotest.test_case "keeper provenance upgrade" `Quick
            (with_eio test_post_kind_keeper_provenance_upgrade);
        ] );
    ]
