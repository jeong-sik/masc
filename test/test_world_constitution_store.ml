(** Ledger tests for the world constitution (RFC-0442). *)

open Masc.World_constitution_types
module Store = Masc.World_constitution_store

let with_world f =
  let path = Filename.temp_file "world-constitution-" ".dir" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree path) (fun () -> f path)

let ne where items =
  match Non_empty.of_list items with
  | Ok value -> value
  | Error `Empty -> Alcotest.failf "%s: unexpected empty list" where

let article ?(text = "cite the ledger row, not the frame") ?state () =
  let state =
    match state with
    | Some state -> state
    | None -> Proposed { post_id = "p-0123456789abcdef" }
  in
  match
    make ~id:(Article_id.generate ()) ~text
      ~evidence:(ne "evidence" [ { uri = "p-0123456789abcdef"; sha256 = None } ])
      ~proposer:"lane-smith" ~state ~last_cited_at:None
  with
  | Ok article -> article
  | Error invalid ->
    Alcotest.failf "article rejected: %s" (invalid_to_string invalid)

let ratify article =
  match
    transition article
      ~to_:(Ratified { at = 10.0; ratifiers = ne "ratifiers" [ "alpha" ] })
  with
  | Ok moved -> moved
  | Error error -> Alcotest.failf "%s" (transition_error_to_string error)

let append_or_fail ~base_path article =
  match Store.append ~base_path article with
  | Ok () -> ()
  | Error error -> Alcotest.failf "%s" (Store.append_error_to_string error)

let load_or_fail ~base_path =
  match Store.load ~base_path with
  | Ok ledger -> ledger
  | Error error -> Alcotest.failf "%s" (Store.read_error_to_string error)

let id_of article = Article_id.to_string article.id

let test_ledger_path_is_base_path_scoped () =
  let path = Store.ledger_path ~base_path:"/tmp/a-world" in
  Alcotest.(check string)
    "ledger sits under the world's own .masc"
    "/tmp/a-world/.masc/constitution/articles.jsonl" path

let test_a_world_without_a_ledger_has_no_articles () =
  with_world (fun base_path ->
      let ledger = load_or_fail ~base_path in
      Alcotest.(check int) "no articles" 0 (List.length ledger.articles);
      Alcotest.(check int) "nothing rejected" 0 (List.length ledger.rejected))

let test_append_then_load_roundtrip () =
  with_world (fun base_path ->
      let subject = article () in
      append_or_fail ~base_path subject;
      let ledger = load_or_fail ~base_path in
      match ledger.articles with
      | [ loaded ] ->
        Alcotest.(check string) "id survives" (id_of subject) (id_of loaded);
        Alcotest.(check string) "text survives" subject.text loaded.text
      | others ->
        Alcotest.failf "expected one article, got %d" (List.length others))

let test_the_last_line_for_an_id_is_its_state () =
  with_world (fun base_path ->
      let first = article ~text:"first norm" () in
      let second = article ~text:"second norm" () in
      append_or_fail ~base_path first;
      append_or_fail ~base_path second;
      append_or_fail ~base_path (ratify first);
      let ledger = load_or_fail ~base_path in
      Alcotest.(check int) "one entry per id" 2 (List.length ledger.articles);
      let ids = List.map id_of ledger.articles in
      Alcotest.(check (list string))
        "order of first appearance is kept"
        [ id_of first; id_of second ]
        ids;
      match ledger.articles with
      | [ first_loaded; second_loaded ] ->
        (match first_loaded.state with
         | Ratified _ -> ()
         | Proposed _ | Superseded _ | Repealed _ ->
           Alcotest.fail "the later line did not win");
        (match second_loaded.state with
         | Proposed _ -> ()
         | Ratified _ | Superseded _ | Repealed _ ->
           Alcotest.fail "an untouched article changed state")
      | _ -> Alcotest.fail "expected two articles")

let test_a_line_that_does_not_decode_is_reported_not_dropped () =
  with_world (fun base_path ->
      let subject = article () in
      append_or_fail ~base_path subject;
      let path = Store.ledger_path ~base_path in
      let channel = open_out_gen [ Open_append; Open_text ] 0o600 path in
      output_string channel "{\"id\":\"a-placeholder\"}\n";
      close_out channel;
      let survivor = article ~text:"still readable" () in
      append_or_fail ~base_path survivor;
      let ledger = load_or_fail ~base_path in
      Alcotest.(check int)
        "readable articles survive the broken line" 2
        (List.length ledger.articles);
      match ledger.rejected with
      | [ rejected ] ->
        Alcotest.(check int) "names the offending line" 2 rejected.line_number;
        Alcotest.(check bool)
          "carries a reason" true
          (String.length rejected.detail > 0)
      | others ->
        Alcotest.failf "expected one rejection, got %d" (List.length others))

let test_in_force_selects_only_ratified () =
  with_world (fun base_path ->
      let proposed = article ~text:"a proposal" () in
      let live = article ~text:"a norm in force" () in
      let withdrawn = article ~text:"a withdrawn norm" () in
      append_or_fail ~base_path proposed;
      append_or_fail ~base_path (ratify live);
      let repealed =
        match
          transition (ratify withdrawn)
            ~to_:(Repealed { at = 20.0; post_id = "p-2" })
        with
        | Ok moved -> moved
        | Error error -> Alcotest.failf "%s" (transition_error_to_string error)
      in
      append_or_fail ~base_path repealed;
      let ledger = load_or_fail ~base_path in
      Alcotest.(check int) "three articles recorded" 3
        (List.length ledger.articles);
      match Store.in_force ledger with
      | [ only ] ->
        Alcotest.(check string) "only the ratified one renders"
          "a norm in force" only.text
      | others ->
        Alcotest.failf "expected one article in force, got %d"
          (List.length others))

let () =
  Alcotest.run "world_constitution_store"
    [ ( "paths",
        [ Alcotest.test_case "ledger is base-path scoped" `Quick
            test_ledger_path_is_base_path_scoped;
        ] );
      ( "reading",
        [ Alcotest.test_case "a world without a ledger has no articles" `Quick
            test_a_world_without_a_ledger_has_no_articles;
          Alcotest.test_case "append then load" `Quick
            test_append_then_load_roundtrip;
          Alcotest.test_case "the last line for an id is its state" `Quick
            test_the_last_line_for_an_id_is_its_state;
          Alcotest.test_case "a broken line is reported, not dropped" `Quick
            test_a_line_that_does_not_decode_is_reported_not_dropped;
        ] );
      ( "projection",
        [ Alcotest.test_case "in_force selects only ratified" `Quick
            test_in_force_selects_only_ratified;
        ] );
    ]
