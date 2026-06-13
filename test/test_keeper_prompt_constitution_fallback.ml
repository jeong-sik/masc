(** D9 — keeper_constitution Error-fallback substitution guard.

    Root cause covered: [Keeper_prompt.keeper_constitution] previously, on
    [Prompt_registry.render_prompt_template … = Error _], returned the raw
    [Prompt_registry.get_prompt Keeper_prompt_names.constitution] template
    unchanged — that template contains a literal [{{state_block_instruction}}]
    placeholder, so the rendered prompt lost the "State block template"
    anchor.  Downstream, [missing_critical_prompt_anchors] flagged
    [state_block_template] missing, emitted
    [masc_keeper_prompt_failures_total{prompt="critical_prompt_anchors"}],
    and appended the in-code recovery block — observed as ~51 emissions per
    restart with [keeper_name=null].  Test 1 pins the fallback substitution
    in isolation; Test 2 is a regression guard on the happy path. *)

open Alcotest

module KP = Masc.Keeper_prompt
module KSBP = Keeper_state_block_prompt

let has_prompt_root path =
  Sys.file_exists (Filename.concat path "config/prompts/keeper.constitution.md")

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_prompt_root root -> root
  | _ ->
    let rec ascend path =
      if has_prompt_root path then path
      else
        let parent = Filename.dirname path in
        if String.equal parent path then Sys.getcwd () else ascend parent
    in
    ascend (Sys.getcwd ())

let with_prompt_registry f =
  Fun.protect
    ~finally:Prompt_registry.clear
    (fun () ->
      Prompt_registry.clear ();
      Prompt_registry.set_markdown_dir
        (Filename.concat (repo_root ()) "config/prompts");
      Masc.Prompt_defaults.init ();
      f ())

(* Local substring check to avoid a dep on a specific [String_util] surface
   from this leaf test.  Linear scan is fine for the small fixtures here. *)
let has_substring haystack needle =
  let h = String.length haystack and n = String.length needle in
  if n = 0 then true
  else
    let rec loop i =
      if i + n > h then false
      else if String.sub haystack i n = needle then true
      else loop (i + 1)
    in
    loop 0

let test_fallback_substitutes_state_block_instruction () =
  (* Simulate the raw template that [Prompt_registry.get_prompt] would return
     when [render_prompt_template] fails — placeholder intact.  We do not
     touch the live registry; we exercise the pure helper so the test does
     not depend on prompt-file layout or test-runner cwd. *)
  let raw_template =
    "<constitution>\nIntro line.\n{{state_block_instruction}}\nOutro line.\n</constitution>"
  in
  let result = KP.substitute_state_block_instruction_fallback raw_template in
  check bool
    "fallback substitution still produces the \"State block template\" \
     literal that [missing_critical_prompt_anchors] looks for"
    true
    (has_substring result "State block template");
  check bool
    "fallback substitution removes the raw [{{state_block_instruction}}] \
     placeholder"
    false
    (has_substring result "{{state_block_instruction}}");
  check bool
    "fallback substitution preserves surrounding template text"
    true
    (has_substring result "Intro line." && has_substring result "Outro line.")

let test_happy_path_includes_state_block_template () =
  (* Regression guard: with a properly-loaded prompt registry,
     [keeper_constitution] still includes the "State block template" literal.
     The test initializes the registry explicitly; otherwise direct execution
     would take the missing-prompt fallback and test runner cwd instead of the
     happy path. *)
  with_prompt_registry @@ fun () ->
  let prompt = KP.keeper_constitution () in
  check bool
    "keeper_constitution output contains \"State block template\" literal \
     (regression guard for D9 fallback bug)"
    true
    (has_substring prompt "State block template");
  check bool
    "keeper_constitution output does NOT leak a raw \
     [{{state_block_instruction}}] placeholder"
    false
    (has_substring prompt "{{state_block_instruction}}")

let test_fallback_idempotent_when_no_placeholder () =
  (* Pure helper must be a no-op on already-rendered text (no
     [{{state_block_instruction}}] placeholders left).  This pins that the
     helper does not accidentally re-inject [instruction_text] on every call,
     which would matter if a future caller piped already-rendered text
     through the fallback path. *)
  let already_rendered =
    "<constitution>\nIntro\n" ^ KSBP.instruction_text ^ "\nOutro\n</constitution>"
  in
  let result = KP.substitute_state_block_instruction_fallback already_rendered in
  check string
    "fallback is idempotent on text that already has no placeholder"
    already_rendered result

let () =
  run "keeper_prompt_constitution_fallback"
    [
      ( "D9 constitution Error-fallback",
        [
          test_case
            "fallback path substitutes state_block_instruction so the \
             \"State block template\" anchor is preserved"
            `Quick
            test_fallback_substitutes_state_block_instruction;
          test_case
            "happy path: keeper_constitution() still includes the literal \
             (regression guard)"
            `Quick test_happy_path_includes_state_block_template;
          test_case "fallback is idempotent when no placeholder remains" `Quick
            test_fallback_idempotent_when_no_placeholder;
        ] );
    ]
