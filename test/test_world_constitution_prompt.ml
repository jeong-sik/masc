(** The constitution slot in the assembled keeper system prompt (RFC-0442). *)

module KP = Masc.Keeper_prompt
module Render = Masc.World_constitution_render
module Types = Masc.World_constitution_types

let repo_source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

(* Same pinning idiom as test_keeper_system_prompt_bytes: the assembled prompt
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
    "no heading is emitted for a world with no articles" false
    (contains ~sub:"wrote these norms down for themselves" (assembled ()))

let test_articles_reach_the_prompt () =
  let rendered = Render.articles [ article "open before you record" ] in
  let prompt = assembled ~constitution:rendered () in
  Alcotest.(check bool)
    "the article text is in the prompt" true
    (contains ~sub:"open before you record" prompt);
  Alcotest.(check bool)
    "the prompt says whose norms these are" true
    (contains ~sub:"wrote these norms down for themselves" prompt)

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

let () =
  Alcotest.run "world_constitution_prompt"
    [ ( "render",
        [ Alcotest.test_case "no articles render nothing" `Quick
            test_no_articles_render_nothing;
          Alcotest.test_case "each article carries its id" `Quick
            test_each_article_carries_its_id;
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
        ] );
    ]
