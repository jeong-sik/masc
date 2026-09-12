(** Ledger tests for the world constitution (RFC-0442). *)

open Masc.World_constitution_types
module Store = Masc.World_constitution_store

let with_world f =
  let path = Filename.temp_file "world-constitution-" ".dir" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree path) (fun () -> f path)

let article ?(author = "lane-smith") ?(at = 1.0) text =
  match
    make ~id:(Article_id.generate ()) ~text ~author ~at ~evidence:[]
  with
  | Ok article -> article
  | Error invalid ->
    Alcotest.failf "article rejected: %s" (invalid_to_string invalid)

let end_offset ~base_path =
  match Store.load ~base_path with
  | Ok ledger -> ledger.Store.end_offset
  | Error error -> Alcotest.failf "%s" (Store.read_error_to_string error)

let add ~base_path article =
  match
    Store.append_at ~base_path
      ~expected_end_offset:(end_offset ~base_path)
      (Added article)
  with
  | Ok () -> ()
  | Error error -> Alcotest.failf "%s" (Store.append_error_to_string error)

let remove ~base_path (article : t) =
  match
    Store.append_at ~base_path
      ~expected_end_offset:(end_offset ~base_path)
      (Removed { id = article.id; by = "critic"; at = 9.0 })
  with
  | Ok () -> ()
  | Error error -> Alcotest.failf "%s" (Store.append_error_to_string error)

let load_or_fail ~base_path =
  match Store.load ~base_path with
  | Ok ledger -> ledger
  | Error error -> Alcotest.failf "%s" (Store.read_error_to_string error)

let texts (ledger : Store.ledger) = List.map (fun (a : t) -> a.text) ledger.articles

let test_ledger_path_is_base_path_scoped () =
  Alcotest.(check string)
    "ledger sits under the world's own .masc"
    "/tmp/a-world/.masc/constitution/articles.jsonl"
    (Store.ledger_path ~base_path:"/tmp/a-world")

let test_a_world_without_a_ledger_has_no_articles () =
  with_world (fun base_path ->
      let ledger = load_or_fail ~base_path in
      Alcotest.(check int) "no articles" 0 (List.length ledger.articles);
      Alcotest.(check int) "nothing rejected" 0 (List.length ledger.rejected))

let test_written_norms_come_back_in_order () =
  with_world (fun base_path ->
      add ~base_path (article "first norm");
      add ~base_path (article "second norm");
      Alcotest.(check (list string))
        "order of writing is kept" [ "first norm"; "second norm" ]
        (texts (load_or_fail ~base_path)))

let test_removing_takes_a_norm_out_of_force () =
  with_world (fun base_path ->
      let doomed = article "a norm someone took back" in
      add ~base_path (article "a norm that stays");
      add ~base_path doomed;
      remove ~base_path doomed;
      let ledger = load_or_fail ~base_path in
      Alcotest.(check (list string))
        "only the surviving norm is held" [ "a norm that stays" ] (texts ledger);
      Alcotest.(check int) "nothing was rejected" 0 (List.length ledger.rejected))

let test_rewriting_a_held_norm_edits_it_in_place () =
  with_world (fun base_path ->
      let original = article "a norm with a typo" in
      add ~base_path original;
      add ~base_path (article "a trailing norm");
      let edited =
        match
          make ~id:original.id ~text:"a norm without a typo" ~author:"critic"
            ~at:5.0 ~evidence:[]
        with
        | Ok edited -> edited
        | Error invalid ->
          Alcotest.failf "%s" (invalid_to_string invalid)
      in
      add ~base_path edited;
      Alcotest.(check (list string))
        "the edit lands in place, not at the end"
        [ "a norm without a typo"; "a trailing norm" ]
        (texts (load_or_fail ~base_path)))

let test_a_norm_written_again_after_removal_returns_at_the_end () =
  with_world (fun base_path ->
      let disputed = article "a disputed norm" in
      add ~base_path disputed;
      add ~base_path (article "an undisputed norm");
      remove ~base_path disputed;
      add ~base_path disputed;
      Alcotest.(check (list string))
        "the world changed its mind, and that is when"
        [ "an undisputed norm"; "a disputed norm" ]
        (texts (load_or_fail ~base_path)))

(* Two keepers reading the same world, one writing first. The second decided
   something from what it read -- the byte ceiling is decided exactly this way
   -- so its write must not land on a ledger it never saw. *)
let test_a_write_built_on_a_stale_read_is_refused () =
  with_world (fun base_path ->
      add ~base_path (article "first norm");
      let stale = end_offset ~base_path in
      add ~base_path (article "a norm written by someone else");
      match
        Store.append_at ~base_path ~expected_end_offset:stale
          (Added (article "a norm decided from the old ledger"))
      with
      | Error (Store.Ledger_moved { expected; actual }) ->
        Alcotest.(check int) "it names the read it was built on" stale expected;
        Alcotest.(check bool) "and where the ledger actually ends" true
          (actual > stale);
        Alcotest.(check (list string))
          "the stale write did not land"
          [ "first norm"; "a norm written by someone else" ]
          (texts (load_or_fail ~base_path))
      | Ok () -> Alcotest.fail "a write built on a stale read landed"
      | Error other ->
        Alcotest.failf "wrong error: %s" (Store.append_error_to_string other))

let test_a_line_that_does_not_decode_is_reported_not_dropped () =
  with_world (fun base_path ->
      add ~base_path (article "a readable norm");
      let channel =
        open_out_gen [ Open_append; Open_text ] 0o600
          (Store.ledger_path ~base_path)
      in
      output_string channel "{\"kind\":\"added\",\"article\":{}}\n";
      close_out channel;
      add ~base_path (article "another readable norm");
      let ledger = load_or_fail ~base_path in
      Alcotest.(check (list string))
        "readable norms survive the broken line"
        [ "a readable norm"; "another readable norm" ]
        (texts ledger);
      match ledger.rejected with
      | [ rejected ] ->
        Alcotest.(check int) "names the offending line" 2 rejected.line_number;
        Alcotest.(check bool)
          "carries a reason" true
          (String.length rejected.detail > 0)
      | others ->
        Alcotest.failf "expected one rejection, got %d" (List.length others))

let () =
  Alcotest.run "world_constitution_store"
    [ ( "paths",
        [ Alcotest.test_case "ledger is base-path scoped" `Quick
            test_ledger_path_is_base_path_scoped;
        ] );
      ( "folding",
        [ Alcotest.test_case "a world without a ledger has no articles" `Quick
            test_a_world_without_a_ledger_has_no_articles;
          Alcotest.test_case "written norms come back in order" `Quick
            test_written_norms_come_back_in_order;
          Alcotest.test_case "removing takes a norm out of force" `Quick
            test_removing_takes_a_norm_out_of_force;
          Alcotest.test_case "rewriting a held norm edits it in place" `Quick
            test_rewriting_a_held_norm_edits_it_in_place;
          Alcotest.test_case "a norm written again after removal returns last"
            `Quick test_a_norm_written_again_after_removal_returns_at_the_end;
          Alcotest.test_case "a write built on a stale read is refused" `Quick
            test_a_write_built_on_a_stale_read_is_refused;
        ] );
      ( "rejections",
        [ Alcotest.test_case "a broken line is reported, not dropped" `Quick
            test_a_line_that_does_not_decode_is_reported_not_dropped;
        ] );
    ]
