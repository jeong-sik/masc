(** test_board_ttl.ml - Board TTL, permanent post, and post_kind classification tests *)

open Masc_mcp.Board

let () = Mirage_crypto_rng_unix.use_default ()

let with_eio f () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  f ()
;;

let test_default_ttl () =
  Alcotest.(check int) "default_ttl_hours is 0" 0 Limits.default_ttl_hours
;;

(* Issue #8392: schema enums for [visibility] must stay in sync with the
   Variant SSOT. The witness function uses an exhaustive [match]: adding
   a 5th constructor to [visibility] forces [visibility_to_string] to
   fail compilation, and the count assertion below catches list/Variant
   drift in [all_visibilities]. *)
let test_visibility_witness_in_enum () =
  let module C = Masc_mcp.Board_core_classify in
  let witness s =
    let actual = C.visibility_to_string s in
    if not (List.mem actual C.valid_visibility_strings)
    then Alcotest.failf "visibility_to_string %S not in valid_visibility_strings" actual
  in
  witness Public;
  witness Unlisted;
  witness Internal;
  witness Direct;
  Alcotest.(check int) "count" 4 (List.length C.valid_visibility_strings)
;;

let test_visibility_strings_complete () =
  let strs = Masc_mcp.Board_core_classify.valid_visibility_strings in
  List.iter
    (fun expected ->
       Alcotest.(check bool)
         (Printf.sprintf "%s present" expected)
         true
         (List.mem expected strs))
    [ "public"; "unlisted"; "internal"; "direct" ]
;;

(* Issue #8449 PR A: Board_dispatch.sort_order schema enum SSOT.
   Witness covers all 5 variants; adding a 6th constructor will fail
   compilation in [sort_order_to_string]. *)
let test_sort_order_witness_in_enum () =
  let module D = Masc_mcp.Board_dispatch in
  let witness s =
    let actual = D.sort_order_to_string s in
    if not (List.mem actual D.valid_sort_order_strings)
    then Alcotest.failf "sort_order_to_string %S not in valid_sort_order_strings" actual
  in
  witness D.Hot;
  witness D.Trending;
  witness D.Recent;
  witness D.Updated;
  witness D.Discussed;
  Alcotest.(check int) "count" 5 (List.length D.valid_sort_order_strings)
;;

let test_sort_order_aliases () =
  let module D = Masc_mcp.Board_dispatch in
  Alcotest.(check (option string))
    "new -> Recent"
    (Some "recent")
    (Option.map D.sort_order_to_string (D.sort_order_of_string_opt "new"));
  Alcotest.(check (option string))
    "active -> Updated"
    (Some "updated")
    (Option.map D.sort_order_to_string (D.sort_order_of_string_opt "active"));
  Alcotest.(check (option string))
    "comments -> Discussed"
    (Some "discussed")
    (Option.map D.sort_order_to_string (D.sort_order_of_string_opt "comments"));
  Alcotest.(check (option string))
    "garbage rejected"
    None
    (D.sort_order_of_string_opt "definitely-not-an-order"
     |> Option.map D.sort_order_to_string)
;;

let test_permanent_post () =
  let store = create_store () in
  match
    create_post
      store
      ~author:"test-agent"
      ~content:"Permanent post"
      ~post_kind:Human_post
      ()
  with
  | Ok post -> Alcotest.(check (float 0.0)) "expires_at = 0.0" 0.0 post.expires_at
  | Error e -> Alcotest.fail (show_board_error e)
;;

let test_expiring_post () =
  let store = create_store () in
  match
    create_post
      store
      ~author:"test-agent"
      ~content:"Expiring post"
      ~post_kind:Human_post
      ~ttl_hours:24
      ()
  with
  | Ok post -> Alcotest.(check bool) "expires_at > 0.0" true (post.expires_at > 0.0)
  | Error e -> Alcotest.fail (show_board_error e)
;;

let test_sweeper_skips_permanent () =
  let store = create_store () in
  (match
     create_post store ~author:"test-agent" ~content:"Permanent" ~post_kind:Human_post ()
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (show_board_error e));
  let removed_posts, _ = sweep store in
  Alcotest.(check int) "sweeper removed 0 permanent posts" 0 removed_posts
;;

let test_post_kind_direct_default () =
  let store = create_store () in
  match
    create_post store ~author:"test-agent" ~content:"Human post" ~post_kind:Human_post ()
  with
  | Ok post ->
    let json = post_to_yojson post in
    let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
    let reason = Yojson.Safe.Util.(json |> member "classification_reason" |> to_string) in
    Alcotest.(check string) "kind is direct" "direct" kind;
    Alcotest.(check string)
      "reason"
      "Direct board post without automation provenance."
      reason
  | Error e -> Alcotest.fail (show_board_error e)
;;

let test_post_kind_automation_contract () =
  let store = create_store () in
  match
    create_post
      store
      ~author:"dashboard-harness-bot"
      ~content:"Harness post"
      ~visibility:Internal
      ~ttl_hours:1
      ~hearth:"dashboard-harness"
      ~post_kind:Automation_post
      ()
  with
  | Ok post ->
    let json = post_to_yojson post in
    let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
    Alcotest.(check string) "kind is automation" "automation" kind
  | Error e -> Alcotest.fail (show_board_error e)
;;

let test_post_kind_system_contract () =
  let store = create_store () in
  match
    create_post store ~author:"operator" ~content:"System post" ~post_kind:System_post ()
  with
  | Ok post ->
    let json = post_to_yojson post in
    let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
    Alcotest.(check string) "kind is system" "system" kind
  | Error e -> Alcotest.fail (show_board_error e)
;;

let test_post_kind_prefers_explicit_judgment () =
  let store = create_store () in
  let summary =
    "LLM judged this as automation because it summarizes a completed keeper background \
     run."
  in
  let meta =
    `Assoc
      [ "source", `String "keeper_board_post"
      ; "judgment", `Assoc [ "summary", `String summary; "confidence", `Float 0.82 ]
      ]
  in
  match
    create_post
      store
      ~author:"dm-keeper"
      ~content:"Keeper board post"
      ~post_kind:Automation_post
      ~meta_json:meta
      ()
  with
  | Ok post ->
    let json = post_to_yojson post in
    let reason = Yojson.Safe.Util.(json |> member "classification_reason" |> to_string) in
    Alcotest.(check string) "judgment summary overrides fallback" summary reason
  | Error e -> Alcotest.fail (show_board_error e)
;;

let test_post_kind_keeper_provenance_upgrade () =
  let store = create_store () in
  let meta = `Assoc [ "source", `String "keeper_board_post" ] in
  match
    create_post
      store
      ~author:"dm-keeper"
      ~content:"Keeper board post"
      ~post_kind:Automation_post
      ~meta_json:meta
      ()
  with
  | Ok post ->
    Alcotest.(check bool)
      "classified as automation"
      true
      (classify_post_kind post = Automation_post);
    let json = post_to_yojson post in
    let kind = Yojson.Safe.Util.(json |> member "post_kind" |> to_string) in
    let reason = Yojson.Safe.Util.(json |> member "classification_reason" |> to_string) in
    Alcotest.(check string) "kind is automation" "automation" kind;
    Alcotest.(check string)
      "provenance reason"
      "Automation classification based on source=keeper_board_post, author=dm-keeper, \
       and the automation post_kind contract."
      reason
  | Error e -> Alcotest.fail (show_board_error e)
;;

let () =
  Alcotest.run
    "Board_TTL"
    [ ( "ttl"
      , [ Alcotest.test_case "default TTL is 0" `Quick test_default_ttl
        ; Alcotest.test_case "permanent post" `Quick (with_eio test_permanent_post)
        ; Alcotest.test_case "expiring post" `Quick (with_eio test_expiring_post)
        ; Alcotest.test_case
            "sweeper skips permanent"
            `Quick
            (with_eio test_sweeper_skips_permanent)
        ] )
    ; ( "visibility_ssot"
      , [ Alcotest.test_case
            "witness covers all 4 variants"
            `Quick
            test_visibility_witness_in_enum
        ; Alcotest.test_case
            "all 4 strings present"
            `Quick
            test_visibility_strings_complete
        ] )
    ; ( "sort_order_ssot"
      , [ Alcotest.test_case
            "witness covers all 5 variants"
            `Quick
            test_sort_order_witness_in_enum
        ; Alcotest.test_case
            "aliases new/active/comments accepted"
            `Quick
            test_sort_order_aliases
        ] )
    ; ( "post_kind"
      , [ Alcotest.test_case
            "direct default"
            `Quick
            (with_eio test_post_kind_direct_default)
        ; Alcotest.test_case
            "automation contract"
            `Quick
            (with_eio test_post_kind_automation_contract)
        ; Alcotest.test_case
            "system contract"
            `Quick
            (with_eio test_post_kind_system_contract)
        ; Alcotest.test_case
            "prefers explicit judgment"
            `Quick
            (with_eio test_post_kind_prefers_explicit_judgment)
        ; Alcotest.test_case
            "keeper provenance upgrade"
            `Quick
            (with_eio test_post_kind_keeper_provenance_upgrade)
        ] )
    ]
;;
