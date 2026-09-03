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

(* The assembled prompt renders registry slots (keeper.md: identity,
   workspace, instructions.custom, and the tags slots), so resolution must be
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
    (contains ("You are " ^ golden_keeper_name ^ "."));
  check bool "workspace block carries the sandbox root" true
    (contains golden_workspace_root);
  check bool "custom instructions reach the prompt" true
    (contains "Golden custom instruction line one.");
  check bool "active goals reach the prompt" true (contains "goal-golden-1")

let () =
  run "keeper_system_prompt_bytes"
    [ ( "golden",
        [ test_case "assembled prompt matches golden bytes" `Quick
            test_assembled_prompt_matches_golden;
          test_case "assembled prompt carries required anchors" `Quick
            test_assembled_prompt_carries_system_anchor ] ) ]
