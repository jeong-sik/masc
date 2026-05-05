(** RFC-0027 PR-9b: provider:auto expansion preserves [secondary]
    overrides on every expanded weighted entry.

    The dual-track resolver in
    {!Masc_mcp.Cascade_catalog_runtime.resolve_secondary_provider_for_primary}
    matches a parsed primary [Provider_config] back to its weighted entry
    by walking the *expanded* entries (one per concrete model after
    [provider:auto] expansion). For the lookup to find the secondary
    declaration, expansion must carry the [secondary] and
    [secondary_supports_tool_choice] fields onto every expanded entry —
    not just the first one. *)

open Alcotest

module Loader = Masc_mcp.Cascade_config_loader
module Cfg = Masc_mcp.Cascade_config

let entry ?(weight = 1) ?supports_tool_choice ?secondary
    ?secondary_supports_tool_choice model : Loader.weighted_entry =
  {
    model;
    weight;
    supports_tool_choice;
    secondary;
    secondary_supports_tool_choice;
  }

let test_non_auto_passes_through () =
  let inputs =
    [ entry ~secondary:"openai:gpt-4-turbo" "anthropic:claude-3-5" ]
  in
  let outs = Cfg.expand_weighted_auto_entries inputs in
  check int "single entry preserved" 1 (List.length outs);
  let e = List.hd outs in
  check string "model unchanged" "anthropic:claude-3-5" e.model;
  check (option string) "secondary preserved"
    (Some "openai:gpt-4-turbo") e.secondary

let test_auto_expansion_carries_secondary () =
  (* claude_code:auto expands to multiple concrete models; every
     expanded entry must keep the same secondary so the dual-track
     resolver can match any of them back to a fallback. *)
  let inputs =
    [ entry
        ~secondary:"anthropic:claude-3-5-sonnet-20251022"
        ~secondary_supports_tool_choice:true
        "claude_code:auto" ]
  in
  let outs = Cfg.expand_weighted_auto_entries inputs in
  (* claude_code:auto must expand to >=2 models, otherwise the auto
     model list collapsed and this test would not exercise the
     preservation path. *)
  if List.length outs < 2 then
    failf
      "claude_code:auto expanded to only %d entries; expected >=2"
      (List.length outs);
  List.iter
    (fun (e : Loader.weighted_entry) ->
      check (option string)
        (Printf.sprintf "secondary preserved on expanded model %s" e.model)
        (Some "anthropic:claude-3-5-sonnet-20251022") e.secondary;
      check (option bool)
        (Printf.sprintf
           "secondary_supports_tool_choice preserved on %s" e.model)
        (Some true) e.secondary_supports_tool_choice)
    outs

let test_no_secondary_stays_none_after_expansion () =
  let inputs = [ entry "claude_code:auto" ] in
  let outs = Cfg.expand_weighted_auto_entries inputs in
  List.iter
    (fun (e : Loader.weighted_entry) ->
      check (option string)
        (Printf.sprintf "no secondary on %s" e.model) None e.secondary;
      check (option bool)
        (Printf.sprintf "no secondary_supports_tool_choice on %s" e.model)
        None e.secondary_supports_tool_choice)
    outs

let test_mixed_entries_preserve_per_entry () =
  let inputs =
    [
      entry ~secondary:"openai:gpt-4-turbo" "anthropic:claude-3-5";
      entry "openai:gpt-4-turbo";
    ]
  in
  let outs = Cfg.expand_weighted_auto_entries inputs in
  (* Both entries are concrete (no :auto), so expansion is a passthrough
     of length 2; secondary must be preserved on the first only. *)
  check int "two entries" 2 (List.length outs);
  let e1 = List.nth outs 0 in
  let e2 = List.nth outs 1 in
  check (option string) "first entry secondary preserved"
    (Some "openai:gpt-4-turbo") e1.secondary;
  check (option string) "second entry has no secondary"
    None e2.secondary

let () =
  run "Cascade_secondary_expand"
    [
      ( "expand_weighted_auto_entries preserves secondary",
        [
          test_case "non-auto entry passes through with secondary" `Quick
            test_non_auto_passes_through;
          test_case "provider:auto expansion carries secondary on all"
            `Quick test_auto_expansion_carries_secondary;
          test_case "absent secondary stays None after expansion" `Quick
            test_no_secondary_stays_none_after_expansion;
          test_case "secondary preserved per-entry independently" `Quick
            test_mixed_entries_preserve_per_entry;
        ] );
    ]
