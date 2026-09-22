(** Golden bytes for the assembled keeper system prompt.

    [Keeper_prompt.build_keeper_system_prompt] concatenates registry text,
    in-code XML structure, and runtime values. Substring assertions elsewhere
    prove that individual sentences survive; none of them notice block order,
    separator whitespace, duplicated text, or a block that silently resolves to
    the empty string. Those are exactly the failures a prompt-assembly refactor
    produces, and the prompt is what every keeper turn is built from.

    This pins the whole assembled string for fixed inputs. A change here is
    either intended — update the golden in the same commit that changes the
    prompt — or it is the refactor telling you it was not byte-preserving. *)

open Alcotest

module KP = Masc.Keeper_prompt

(* Fixed, obviously synthetic inputs: the golden must not move because a real
   keeper was renamed or a sandbox path changed. *)
let golden_keeper_name = "golden-keeper"
let golden_workspace_root = "/golden/sandbox"

let golden_instructions =
  "Golden custom instruction line one.\nGolden custom instruction line two."

let repo_source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

(* The assembled prompt renders registry slots (keeper.md: worldview,
   identity, workspace, and the tags slots), so resolution must be
   pinned to the repo's own prompt files; otherwise the build raises on a
   missing prompt inside the dune sandbox. Same pinning idiom as
   test_fusion_wake. *)
let () =
  Prompt_registry.set_markdown_dir
    (Filename.concat (repo_source_root ()) "config/prompts");
  Masc.Prompt_defaults.init ()
;;

let golden_path () =
  Filename.concat
    (repo_source_root ())
    "test/fixtures/keeper_system_prompt/assembled_prompt.golden"

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let write_file path contents =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
      output_string oc contents)

let build_golden_prompt () =
  KP.build_keeper_system_prompt
    ~instructions:golden_instructions
    ~keeper_name:golden_keeper_name
    ~workspace_root:golden_workspace_root
    ()

(* Byte offset of the first difference, so a failure names a location instead
   of dumping two multi-kilobyte strings at the operator. *)
let first_divergence a b =
  let limit = min (String.length a) (String.length b) in
  let rec scan i =
    if i >= limit then if String.length a = String.length b then None else Some i
    else if Char.equal a.[i] b.[i] then scan (i + 1)
    else Some i
  in
  scan 0

let excerpt s offset =
  let start = max 0 (offset - 60) in
  let len = min 160 (String.length s - start) in
  if len <= 0 then "<end of string>" else String.sub s start len

let test_assembled_prompt_matches_golden () =
  let actual = build_golden_prompt () in
  let path = golden_path () in
  if not (Sys.file_exists path) then
    fail
      (Printf.sprintf
         "golden file missing: %s (create it from the assembled prompt in the \
          same commit that adds this test)"
         path);
  let expected = read_file path in
  if String.equal actual expected then check bool "assembled prompt bytes" true true
  else begin
    (* Written next to the golden in the source tree, not the dune sandbox,
       which is deleted after the run. Only written on failure; the test still
       fails. The operator diffs it and, when the change was intended, moves it
       over the golden in the same commit. *)
    let actual_path = path ^ ".actual" in
    write_file actual_path actual;
    let offset = Option.value (first_divergence expected actual) ~default:0 in
    fail
      (Printf.sprintf
         "assembled prompt bytes changed: expected %d bytes, got %d, first \
          difference at byte %d.\n\
          expected around it: %s\n\
          actual around it:   %s\n\
          full actual written to %s (cwd is the dune sandbox)"
         (String.length expected) (String.length actual) offset
         (String.escaped (excerpt expected offset))
         (String.escaped (excerpt actual offset))
         actual_path)
  end

(* A golden that silently degrades to a recovery block would still be stable
   bytes. Pin the property the anchor guard exists to protect. *)
let test_assembled_prompt_carries_system_anchor () =
  let actual = build_golden_prompt () in
  let contains needle =
    let n = String.length needle in
    let rec scan i =
      if i + n > String.length actual then false
      else if String.equal (String.sub actual i n) needle then true
      else scan (i + 1)
    in
    scan 0
  in
  check bool "<system> anchor present" true (contains "<system>");
  check bool "</system> anchor present" true (contains "</system>");
  check bool "identity anchor names the keeper" true
    (contains ("당신은 " ^ golden_keeper_name ^ "이다."));
  check bool "the world block reaches the prompt" true (contains "<world>");
  check bool "the role sits in the role tags" true
    (contains "<role>\nGolden custom instruction line one.");
  check bool "workspace block carries the sandbox root" true
    (contains golden_workspace_root);
  check bool "custom instructions reach the prompt" true
    (contains "Golden custom instruction line one.");
  check bool "GH_CONFIG_DIR preauth guidance reaches the prompt" true
    (contains "GH_CONFIG_DIR")

(* The operator gives a world its values by overriding [keeper.worldview].
   That text has to replace the distribution default, and it has to sit where
   every keeper in the world shares it: after the shared body, before the
   keeper's own identity. *)
let test_operator_worldview_replaces_the_default () =
  let find needle haystack =
    let n = String.length needle in
    let rec scan i =
      if i + n > String.length haystack then None
      else if String.equal (String.sub haystack i n) needle then Some i
      else scan (i + 1)
    in
    scan 0
  in
  let default_line = "이 세계는 따로 정한 가치관이 없다." in
  let operator_line = "Golden world values finished work that others can reuse." in
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
      build_golden_prompt
  in
  check bool "the default sentence is gone" true
    (Option.is_none (find default_line prompt));
  match
    ( find "</system>" prompt
    , find operator_line prompt
    , find ("당신은 " ^ golden_keeper_name) prompt )
  with
  | Some system_end, Some world_at, Some identity_at ->
    check bool "the world follows the shared body" true (system_end < world_at);
    check bool "the world precedes the keeper's identity" true
      (world_at < identity_at)
  | _ -> fail "the assembled prompt lost a block"

let () =
  run "keeper_system_prompt_bytes"
    [ ( "golden",
        [ test_case "assembled prompt matches golden bytes" `Quick
            test_assembled_prompt_matches_golden;
          test_case "assembled prompt carries required anchors" `Quick
            test_assembled_prompt_carries_system_anchor;
          test_case "an operator worldview replaces the default" `Quick
            test_operator_worldview_replaces_the_default ] ) ]
