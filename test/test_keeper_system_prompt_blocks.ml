(** The block structure of the assembled keeper system prompt.

    [Keeper_prompt.build_keeper_system_prompt] joins registry text, in-code
    separators and runtime values. What a keeper turn depends on is that every
    block arrives once, in order, and not empty: the shared body, the world's
    worldview, the world's articles, the keeper's identity and workspace, and
    its role. That is what this suite pins.

    It pins no sentence. The prose in config/prompts is the operator's to
    rewrite, and a test that froze it would fail on every rewrite without
    saying anything about the assembly. *)

open Alcotest

module KP = Masc.Keeper_prompt

let keeper_name = "block-keeper"
let workspace_root = "/block/sandbox"
let instructions = "Block role line one.\nBlock role line two."
let articles = "- a-block: a norm written for this test"

let repo_source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

(* The builder renders registry slots, so resolution is pinned to the repo's
   own prompt files; otherwise the build raises on a missing prompt inside the
   dune sandbox. *)
let () =
  Prompt_registry.set_markdown_dir
    (Filename.concat (repo_source_root ()) "config/prompts");
  Masc.Prompt_defaults.init ()

let build ?constitution () =
  KP.build_keeper_system_prompt ~instructions ~keeper_name ~workspace_root
    ?constitution ()

let find ?(from = 0) needle haystack =
  let n = String.length needle in
  let rec scan i =
    if i + n > String.length haystack then None
    else if String.equal (String.sub haystack i n) needle then Some i
    else scan (i + 1)
  in
  scan from

let count needle haystack =
  let rec go from acc =
    match find ~from needle haystack with
    | None -> acc
    | Some i -> go (i + String.length needle) (acc + 1)
  in
  go 0 0

(* The text between one open tag and its close tag. Fails when either tag is
   missing, repeated, or out of order. *)
let block prompt name =
  let open_tag = "<" ^ name ^ ">" and close_tag = "</" ^ name ^ ">" in
  check int (open_tag ^ " appears once") 1 (count open_tag prompt);
  check int (close_tag ^ " appears once") 1 (count close_tag prompt);
  match find open_tag prompt, find close_tag prompt with
  | Some o, Some c when o < c ->
    let start = o + String.length open_tag in
    (o, String.trim (String.sub prompt start (c - start)))
  | _ -> fail (name ^ " block is missing or its tags are out of order")

let order = [ "system"; "world"; "norms"; "identity"; "workspace"; "role" ]

let test_blocks_arrive_once_in_order_and_filled () =
  let prompt = build ~constitution:articles () in
  let positions =
    List.map
      (fun name ->
        let at, body = block prompt name in
        check bool (name ^ " block is not empty") true (body <> "");
        at)
      order
  in
  check bool "blocks follow system, world, norms, identity, workspace, role"
    true
    (List.sort compare positions = positions);
  let _, identity = block prompt "identity" in
  check bool "identity names the keeper" true
    (Option.is_some (find keeper_name identity));
  let _, workspace = block prompt "workspace" in
  check bool "workspace carries the sandbox root" true
    (Option.is_some (find workspace_root workspace));
  let _, role = block prompt "role" in
  check string "the role is the keeper's instructions as written" instructions
    role;
  let _, norms = block prompt "norms" in
  check bool "the world's articles are in the norms block" true
    (Option.is_some (find articles norms))

(* A world that has written no article gets no norms block at all, and nothing
   else moves. *)
let test_a_world_without_articles_has_no_norms_block () =
  let prompt = build () in
  check int "no norms block" 0 (count "<norms>" prompt);
  check string "an empty constitution is the same as none" prompt
    (build ~constitution:"  \n " ())

(* The operator gives a world its values by overriding [keeper.worldview].
   The override replaces the distribution default in the same place. *)
let test_operator_worldview_replaces_the_default () =
  let default_world =
    let _, body = block (build ()) "world" in
    body
  in
  let operator_line = "Block world values finished work others can reuse." in
  (match
     Prompt_registry.set_override Prompt_names.keeper_worldview
       ("<world>\n" ^ operator_line ^ "\n</world>")
   with
   | Ok () -> ()
   | Error detail -> fail ("worldview override refused: " ^ detail));
  let prompt =
    Fun.protect
      ~finally:(fun () ->
        Prompt_registry.clear_prompt_override Prompt_names.keeper_worldview)
      (fun () -> build ())
  in
  let world_at, world = block prompt "world" in
  check string "the world block is the operator's text" operator_line world;
  check bool "the default is gone" true
    (Option.is_none (find default_world prompt));
  let system_at, _ = block prompt "system" in
  let identity_at, _ = block prompt "identity" in
  check bool "the world stays between the shared body and the identity" true
    (system_at < world_at && world_at < identity_at)

let () =
  run "keeper_system_prompt_blocks"
    [ ( "blocks",
        [ test_case "blocks arrive once, in order, filled" `Quick
            test_blocks_arrive_once_in_order_and_filled;
          test_case "no articles, no norms block" `Quick
            test_a_world_without_articles_has_no_norms_block;
          test_case "an operator worldview replaces the default" `Quick
            test_operator_worldview_replaces_the_default ] ) ]
