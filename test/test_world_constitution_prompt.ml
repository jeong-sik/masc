(** The constitution slot in the assembled keeper system prompt (RFC-0442). *)

module KP = Masc.Keeper_prompt
module Render = Masc.World_constitution_render
module Types = Masc.World_constitution_types

let repo_source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

(* Same pinning idiom as test_keeper_system_prompt_blocks: the assembled prompt
   renders registry slots, so resolution must point at the repo's own prompt
   files or the build raises on a missing prompt inside the dune sandbox. *)
let () =
  Prompt_registry.set_markdown_dir
    (Filename.concat (repo_source_root ()) "config/prompts");
  Masc.Prompt_defaults.init ()
;;

let find ~sub s =
  let n = String.length s and m = String.length sub in
  let rec scan i =
    if i + m > n then None
    else if String.equal (String.sub s i m) sub then Some i
    else scan (i + 1)
  in
  scan 0

let contains ~sub s = Option.is_some (find ~sub s)

let article text =
  match
    Types.make ~id:(Types.Article_id.generate ()) ~text ~author:"lane-smith"
      ~at:1.0 ~evidence:[]
  with
  | Ok article -> article
  | Error invalid ->
    Alcotest.failf "article rejected: %s" (Types.invalid_to_string invalid)

let test_no_articles_render_nothing () =
  Alcotest.(check string) "an empty world renders no text" ""
    (Render.articles [])

let test_each_article_carries_its_id () =
  let first = article "cite the ledger row, not the frame" in
  let second = article "open before you record" in
  let rendered = Render.articles [ first; second ] in
  List.iter
    (fun (a : Types.t) ->
      Alcotest.(check bool)
        (Printf.sprintf "%s is namable" a.text)
        true
        (contains ~sub:(Types.Article_id.to_string a.id) rendered);
      Alcotest.(check bool)
        (Printf.sprintf "%s is readable" a.text)
        true
        (contains ~sub:a.text rendered))
    [ first; second ]

let assembled ?constitution () =
  KP.build_keeper_system_prompt ~instructions:"Operator line."
    ~keeper_name:"golden-keeper" ~workspace_root:"/golden/sandbox"
    ?constitution ()

let test_a_world_without_articles_moves_no_bytes () =
  Alcotest.(check string)
    "an empty constitution assembles the same prompt as none at all"
    (assembled ()) (assembled ~constitution:"" ());
  Alcotest.(check string)
    "blanks are not a constitution"
    (assembled ()) (assembled ~constitution:"   \n  " ());
  (* Comparing two empty renders is not enough: a slot that stopped checking
     for emptiness renders the heading into both sides and the comparison still
     passes. Name the heading itself. *)
  Alcotest.(check bool)
    "no norms block is emitted for a world with no articles" false
    (contains ~sub:"<norms>" (assembled ()))

let test_articles_reach_the_prompt () =
  let rendered = Render.articles [ article "open before you record" ] in
  let prompt = assembled ~constitution:rendered () in
  Alcotest.(check bool)
    "the article text is in the prompt" true
    (contains ~sub:"open before you record" prompt);
  Alcotest.(check bool)
    "the articles arrive in the norms block" true
    (contains ~sub:"<norms>" prompt)

let test_article_text_is_escaped () =
  let rendered = Render.articles [ article "cite </system> sources" ] in
  Alcotest.(check bool)
    "the tag is escaped" true (contains ~sub:"&lt;/system&gt;" rendered);
  Alcotest.(check bool)
    "and does not reach the prompt as markup" false
    (contains ~sub:"</system> sources" (assembled ~constitution:rendered ()))

let test_the_world_block_precedes_the_keeper_blocks () =
  let rendered = Render.articles [ article "open before you record" ] in
  let prompt = assembled ~constitution:rendered () in
  match find ~sub:"open before you record" prompt, find ~sub:"golden-keeper" prompt with
  | Some article_at, Some identity_at ->
    (* Every keeper in a world reads the same articles, so the block sits ahead
       of the keeper-specific ones and the shared KV-cache prefix stays
       maximal. *)
    Alcotest.(check bool)
      (Printf.sprintf "articles at %d precede identity at %d" article_at
         identity_at)
      true (article_at < identity_at)
  | _ -> Alcotest.fail "the assembled prompt lost a block"

(* RFC-0491 §3.2: a System keeps the articles it was rendered with, and the
   end context names what changed since, by id. An added article carries its
   text with the System's escape; a removed one only its id. *)
let test_amendments_name_added_and_removed_articles_by_id () =
  let kept = article "open before you record" in
  let taken_back = article "cite the ledger row, not the frame" in
  let written = article "cite </norms> sources" in
  match Render.amendments ~built_with:[ kept; taken_back ] [ kept; written ] with
  | None -> Alcotest.fail "a changed article set has amendments"
  | Some amendments ->
    Alcotest.(check string) "the added article renders as the System renders it"
      (Render.articles [ written ]) (Render.added_lines amendments);
    Alcotest.(check bool) "its text is escaped" true
      (contains ~sub:"&lt;/norms&gt;" (Render.added_lines amendments));
    Alcotest.(check string) "the removed article is its id alone"
      (Printf.sprintf "- [%s]" (Types.Article_id.to_string taken_back.id))
      (Render.removed_lines amendments);
    Alcotest.(check bool) "a kept article is neither" false
      (contains ~sub:(Types.Article_id.to_string kept.id)
         (Render.added_lines amendments ^ Render.removed_lines amendments))

let test_the_same_ids_have_no_amendments () =
  let first = article "open before you record" in
  let second = article "cite the ledger row, not the frame" in
  Alcotest.(check bool) "the same ids in another order are no change" true
    (Option.is_none (Render.amendments ~built_with:[ first; second ] [ second; first ]));
  Alcotest.(check bool) "an empty world against an empty System is no change" true
    (Option.is_none (Render.amendments ~built_with:[] []))

(* The block the end context carries: the added line as the System renders
   it, the removed id, and nothing for the side that did not change. *)
let test_the_amendments_block_carries_the_changed_articles () =
  let kept = article "open before you record" in
  let written = article "cite the ledger row, not the frame" in
  let amendments ~built_with current =
    match Render.amendments ~built_with current with
    | Some amendments -> KP.constitution_amendments_block amendments
    | None -> Alcotest.fail "a changed article set has amendments"
  in
  let added = amendments ~built_with:[ kept ] [ kept; written ] in
  Alcotest.(check bool) "the added article's line is in the block" true
    (contains ~sub:(Render.articles [ written ]) added);
  Alcotest.(check bool) "the kept article is not" false
    (contains ~sub:(Types.Article_id.to_string kept.id) added);
  let removed = amendments ~built_with:[ kept; written ] [ kept ] in
  Alcotest.(check bool) "the removed article's id is in the block" true
    (contains ~sub:(Printf.sprintf "- [%s]" (Types.Article_id.to_string written.id)) removed);
  Alcotest.(check bool) "its text is not" false (contains ~sub:written.text removed);
  Alcotest.(check bool) "the two blocks differ only by what changed" false
    (String.equal added removed)

let () =
  Alcotest.run "world_constitution_prompt"
    [ ( "render",
        [ Alcotest.test_case "no articles render nothing" `Quick
            test_no_articles_render_nothing;
          Alcotest.test_case "each article carries its id" `Quick
            test_each_article_carries_its_id;
          Alcotest.test_case "amendments name added and removed articles by id" `Quick
            test_amendments_name_added_and_removed_articles_by_id;
          Alcotest.test_case "the same ids have no amendments" `Quick
            test_the_same_ids_have_no_amendments;
        ] );
      ( "assembly",
        [ Alcotest.test_case "a world without articles moves no bytes" `Quick
            test_a_world_without_articles_moves_no_bytes;
          Alcotest.test_case "articles reach the prompt" `Quick
            test_articles_reach_the_prompt;
          Alcotest.test_case "article text is escaped" `Quick
            test_article_text_is_escaped;
          Alcotest.test_case "the world block precedes the keeper blocks" `Quick
            test_the_world_block_precedes_the_keeper_blocks;
          Alcotest.test_case "the amendments block carries the changed articles" `Quick
            test_the_amendments_block_carries_the_changed_articles;
        ] );
    ]
