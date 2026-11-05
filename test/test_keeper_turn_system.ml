(* RFC-0491 §3.2: a keeper's System keeps the articles it was rendered with
   while the carried range keeps its front, and the articles written or taken
   back since then ride the end context. These cases pin the rule over plain
   values: where the range opens, which articles render the System, and what
   the amendments name. *)

open Masc
module Render = World_constitution_render
module Types = World_constitution_types
module System = Keeper_turn_system

let repo_source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()
;;

(* The amendments block renders a registry slot, so resolution points at the
   repository's own prompt files. *)
let () =
  Prompt_registry.set_markdown_dir (Filename.concat (repo_source_root ()) "config/prompts");
  Prompt_defaults.init ()
;;

let contains ~sub text =
  let n = String.length text
  and m = String.length sub in
  let rec scan i = i + m <= n && (String.equal (String.sub text i m) sub || scan (i + 1)) in
  scan 0
;;

let article text =
  match
    Types.make ~id:(Types.Article_id.generate ()) ~text ~author:"lane-smith" ~at:1.0
      ~evidence:[]
  with
  | Ok article -> article
  | Error invalid -> Alcotest.failf "article rejected: %s" (Types.invalid_to_string invalid)
;;

let render articles = "<identity>keeper</identity>\n" ^ Render.articles articles
let render_with_other_instructions articles = "<identity>other</identity>\n" ^ Render.articles articles

let seed ~first_atom front : Keeper_carried_front.seed =
  { first_atom; front; source = Keeper_carried_front.Ledger }
;;

let front_name = function
  | System.Same_front -> "same"
  | System.Moved_front -> "moved"
  | System.No_previous_request -> "none"
;;

let check_front label expected actual =
  Alcotest.(check string) label (front_name expected) (front_name actual)
;;

(* Atom [i] opens with digest ["d<i>"]; atoms past 5 do not exist. *)
let digest_at atom = if atom >= 0 && atom < 6 then Some (Printf.sprintf "d%d" atom) else None

let test_the_front_is_the_same_only_at_the_same_atom_and_message () =
  let previous = Some (seed ~first_atom:2 (Model_input_front.At_atom "d2")) in
  check_front "same atom, same opening message" System.Same_front
    (System.front ~digest_at ~first_atom:2 ~previous);
  check_front "another atom" System.Moved_front (System.front ~digest_at ~first_atom:3 ~previous);
  check_front "the message at the atom changed" System.Moved_front
    (System.front ~digest_at:(fun _ -> Some "rewritten") ~first_atom:2 ~previous);
  check_front "an omitted history is not an opened atom" System.Moved_front
    (System.front ~digest_at ~first_atom:2
       ~previous:(Some (seed ~first_atom:2 (Model_input_front.After_history "d2"))));
  check_front "no previous request" System.No_previous_request
    (System.front ~digest_at ~first_atom:2 ~previous:None)
;;

let basis_of ~render current =
  match System.decide ~front:System.No_previous_request ~basis:None ~render ~current with
  | System.From_current { basis; _ } -> basis
  | System.From_basis _ -> Alcotest.fail "no previous request renders the current articles"
;;

(* (a) An article written while the front holds: the System is the bytes the
   basis rendered, and the amendments carry the new article. *)
let test_an_added_article_keeps_the_system_and_names_the_article () =
  let kept = article "open before you record" in
  let written = article "cite the ledger row, not the frame" in
  let basis = basis_of ~render [ kept ] in
  match
    System.decide ~front:System.Same_front ~basis:(Some basis) ~render
      ~current:[ kept; written ]
  with
  | System.From_current _ -> Alcotest.fail "a held front keeps the basis"
  | System.From_basis { text; amendments } ->
    Alcotest.(check string) "the System is the basis rendering" (render [ kept ]) text;
    (match amendments with
     | None -> Alcotest.fail "the written article is an amendment"
     | Some amendments ->
       Alcotest.(check string) "the amendment is the written article's line"
         (Render.articles [ written ]) (Render.added_lines amendments);
       Alcotest.(check string) "nothing was taken back" "" (Render.removed_lines amendments))
;;

let test_the_same_articles_keep_the_system_with_no_amendments () =
  let kept = article "open before you record" in
  let basis = basis_of ~render [ kept ] in
  match System.decide ~front:System.Same_front ~basis:(Some basis) ~render ~current:[ kept ] with
  | System.From_current _ -> Alcotest.fail "a held front keeps the basis"
  | System.From_basis { text; amendments } ->
    Alcotest.(check string) "the System is unchanged" (render [ kept ]) text;
    Alcotest.(check bool) "no amendments" true (Option.is_none amendments)
;;

let expect_current label ~current = function
  | System.From_current { text; _ } ->
    Alcotest.(check string) label (render current) text
  | System.From_basis _ -> Alcotest.failf "%s: the System is rendered with the current articles" label
;;

(* (b) A moved front loses the history cache anyway, so the System takes the
   current articles. *)
let test_a_moved_front_renders_the_current_articles () =
  let kept = article "open before you record" in
  let written = article "cite the ledger row, not the frame" in
  let basis = basis_of ~render [ kept ] in
  let current = [ kept; written ] in
  expect_current "moved front" ~current
    (System.decide ~front:System.Moved_front ~basis:(Some basis) ~render ~current);
  expect_current "no previous request" ~current
    (System.decide ~front:System.No_previous_request ~basis:(Some basis) ~render ~current)
;;

(* (c) Instructions edited since the basis: the basis no longer renders to
   the bytes it recorded, so the System is rebuilt with the current
   articles. *)
let test_changed_instructions_rebuild_the_system () =
  let kept = article "open before you record" in
  let written = article "cite the ledger row, not the frame" in
  let basis = basis_of ~render [ kept ] in
  let current = [ kept; written ] in
  match
    System.decide ~front:System.Same_front ~basis:(Some basis)
      ~render:render_with_other_instructions ~current
  with
  | System.From_basis _ -> Alcotest.fail "a basis that renders other bytes is not kept"
  | System.From_current { text; _ } ->
    Alcotest.(check string) "rebuilt with the new instructions and current articles"
      (render_with_other_instructions current) text
;;

(* (d) No basis yet. *)
let test_no_basis_renders_the_current_articles () =
  let current = [ article "open before you record" ] in
  expect_current "no basis" ~current
    (System.decide ~front:System.Same_front ~basis:None ~render ~current)
;;

(* (e) A taken-back article stays in the System; its id is the amendment. *)
let test_a_removed_article_is_named_by_its_id () =
  let kept = article "open before you record" in
  let taken_back = article "cite the ledger row, not the frame" in
  let basis = basis_of ~render [ kept; taken_back ] in
  match System.decide ~front:System.Same_front ~basis:(Some basis) ~render ~current:[ kept ] with
  | System.From_current _ -> Alcotest.fail "a held front keeps the basis"
  | System.From_basis { text; amendments } ->
    Alcotest.(check string) "the System still holds the taken-back article"
      (render [ kept; taken_back ]) text;
    (match amendments with
     | None -> Alcotest.fail "a taken-back article is an amendment"
     | Some amendments ->
       Alcotest.(check string) "its id"
         (Printf.sprintf "- [%s]" (Types.Article_id.to_string taken_back.id))
         (Render.removed_lines amendments);
       Alcotest.(check string) "nothing was added" "" (Render.added_lines amendments))
;;

let issue ~base_path ~lane current =
  System.issue ~base_path ~keeper_name:"turn-system" ~lane ~render ~current
;;

(* The basis lives in process memory between turns: the first turn stores it,
   the next turn with a held front sends the same bytes and the block. *)
let test_a_later_turn_sends_the_stored_basis_and_the_block () =
  let base_path = "issue-keeps-the-basis" in
  let kept = article "open before you record" in
  let written = article "cite the ledger row, not the frame" in
  let first = issue ~base_path ~lane:(System.Agent_core System.No_previous_request) [ kept ] in
  Alcotest.(check bool) "the first System has no amendments" true (Option.is_none first.amendments);
  let next = issue ~base_path ~lane:(System.Agent_core System.Same_front) [ kept; written ] in
  Alcotest.(check string) "the System bytes are the first turn's" first.text next.text;
  match next.amendments with
  | None -> Alcotest.fail "the written article rides the end context"
  | Some block ->
    Alcotest.(check bool) "the block holds the written article's line" true
      (contains ~sub:(Render.articles [ written ]) block);
    Alcotest.(check bool) "the block does not repeat the kept article" false
      (contains ~sub:(Types.Article_id.to_string kept.id) block)
;;

let test_a_moved_front_replaces_the_basis () =
  let base_path = "issue-replaces-the-basis" in
  let first_article = article "open before you record" in
  let second_article = article "cite the ledger row, not the frame" in
  let third_article = article "name the file you read" in
  let (_ : System.t) =
    issue ~base_path ~lane:(System.Agent_core System.No_previous_request) [ first_article ]
  in
  let moved =
    issue ~base_path ~lane:(System.Agent_core System.Moved_front) [ first_article; second_article ]
  in
  Alcotest.(check string) "the moved front renders the current articles"
    (render [ first_article; second_article ]) moved.text;
  let next =
    issue ~base_path ~lane:(System.Agent_core System.Same_front)
      [ first_article; second_article; third_article ]
  in
  Alcotest.(check string) "the next held front keeps the moved turn's System" moved.text next.text;
  match next.amendments with
  | None -> Alcotest.fail "the third article rides the end context"
  | Some block ->
    Alcotest.(check bool) "only the article written after the moved turn" false
      (contains ~sub:(Types.Article_id.to_string second_article.id) block);
    Alcotest.(check bool) "the third article is named" true
      (contains ~sub:(Types.Article_id.to_string third_article.id) block)
;;

let test_two_base_paths_keep_their_own_basis () =
  let kept = article "open before you record" in
  let written = article "cite the ledger row, not the frame" in
  let (_ : System.t) =
    issue ~base_path:"world-one" ~lane:(System.Agent_core System.No_previous_request) [ kept ]
  in
  let other = issue ~base_path:"world-two" ~lane:(System.Agent_core System.Same_front) [ kept; written ] in
  Alcotest.(check string) "another world has no basis to keep" (render [ kept; written ]) other.text;
  Alcotest.(check bool) "and no amendments" true (Option.is_none other.amendments)
;;

(* (g) An official client's vendor session holds its own System: the turn
   renders the current articles and leaves the keeper's basis alone. *)
let test_an_official_client_turn_neither_reads_nor_writes_the_basis () =
  let base_path = "official-client-leaves-the-basis" in
  let kept = article "open before you record" in
  let written = article "cite the ledger row, not the frame" in
  let later = article "name the file you read" in
  let first = issue ~base_path ~lane:(System.Agent_core System.No_previous_request) [ kept ] in
  let official = issue ~base_path ~lane:System.Without_basis [ kept; written ] in
  Alcotest.(check string) "the official client gets the current articles"
    (render [ kept; written ]) official.text;
  Alcotest.(check bool) "with no amendments" true (Option.is_none official.amendments);
  let next = issue ~base_path ~lane:(System.Agent_core System.Same_front) [ kept; written; later ] in
  Alcotest.(check string) "the Agent Core basis is the one before the official turn" first.text
    next.text;
  match next.amendments with
  | None -> Alcotest.fail "both articles written since the basis ride the end context"
  | Some block ->
    Alcotest.(check bool) "the article the official turn saw is still an amendment" true
      (contains ~sub:(Types.Article_id.to_string written.id) block)
;;

let test_other_bytes_carry_no_amendments () =
  let base_path = "with-bytes" in
  let kept = article "open before you record" in
  let written = article "cite the ledger row, not the frame" in
  let (_ : System.t) =
    issue ~base_path ~lane:(System.Agent_core System.No_previous_request) [ kept ]
  in
  let issued = issue ~base_path ~lane:(System.Agent_core System.Same_front) [ kept; written ] in
  let same = System.with_bytes ~issued issued.text in
  Alcotest.(check bool) "the issued bytes keep their amendments" true
    (Option.equal String.equal issued.amendments same.amendments && Option.is_some same.amendments);
  let recorded = System.with_bytes ~issued "a recorded System" in
  Alcotest.(check string) "other bytes are sent as they are" "a recorded System" recorded.text;
  Alcotest.(check bool) "with no amendments" true (Option.is_none recorded.amendments)
;;

let () =
  Alcotest.run "keeper_turn_system"
    [ ( "front"
      , [ Alcotest.test_case "the same atom and message" `Quick
            test_the_front_is_the_same_only_at_the_same_atom_and_message
        ] )
    ; ( "decide"
      , [ Alcotest.test_case "(a) an added article keeps the System" `Quick
            test_an_added_article_keeps_the_system_and_names_the_article
        ; Alcotest.test_case "the same articles have no amendments" `Quick
            test_the_same_articles_keep_the_system_with_no_amendments
        ; Alcotest.test_case "(b) a moved front renders the current articles" `Quick
            test_a_moved_front_renders_the_current_articles
        ; Alcotest.test_case "(c) changed instructions rebuild the System" `Quick
            test_changed_instructions_rebuild_the_system
        ; Alcotest.test_case "(d) no basis renders the current articles" `Quick
            test_no_basis_renders_the_current_articles
        ; Alcotest.test_case "(e) a removed article is named by its id" `Quick
            test_a_removed_article_is_named_by_its_id
        ] )
    ; ( "issue"
      , [ Alcotest.test_case "a later turn sends the stored basis and the block" `Quick
            test_a_later_turn_sends_the_stored_basis_and_the_block
        ; Alcotest.test_case "a moved front replaces the basis" `Quick
            test_a_moved_front_replaces_the_basis
        ; Alcotest.test_case "two base paths keep their own basis" `Quick
            test_two_base_paths_keep_their_own_basis
        ; Alcotest.test_case "(g) an official client turn leaves the basis" `Quick
            test_an_official_client_turn_neither_reads_nor_writes_the_basis
        ; Alcotest.test_case "other bytes carry no amendments" `Quick
            test_other_bytes_carry_no_amendments
        ] )
    ]
;;
