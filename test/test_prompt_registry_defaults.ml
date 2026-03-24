(** Tests for prompt registry defaults and override API. *)

module Lib = Masc_mcp

let () =
  (* Clear registry state before tests *)
  Lib.Prompt_registry.clear ();
  (* Initialize defaults *)
  Lib.Prompt_defaults.init ();
  let open Alcotest in
  run "Prompt_registry_defaults" [
    ("registration", [
      test_case "all 5 Tier-1 prompts are registered" `Quick (fun () ->
        let keys = [
          "keeper.constitution";
          "keeper.world";
          "keeper.capabilities";
          "governance.deliberation";
          "governance.dry_run";
        ] in
        List.iter (fun key ->
          let v = Lib.Prompt_registry.get_prompt key in
          check bool (Printf.sprintf "%s should not be empty" key) true (v <> "")
        ) keys
      );

      test_case "keeper.constitution matches keeper_prompt default" `Quick (fun () ->
        let from_registry = Lib.Prompt_registry.get_prompt "keeper.constitution" in
        let from_module = Lib.Keeper_prompt.keeper_constitution_default in
        check string "keeper.constitution content" from_module from_registry
      );

      test_case "keeper.world contains MASC" `Quick (fun () ->
        let v = Lib.Prompt_registry.get_prompt "keeper.world" in
        check bool "contains MASC" true
          (String.length v > 0
           && (try ignore (Str.search_forward (Str.regexp_string "MASC") v 0); true
               with Not_found -> false))
      );

      test_case "governance.deliberation contains governance" `Quick (fun () ->
        let v = Lib.Prompt_registry.get_prompt "governance.deliberation" in
        check bool "contains governance" true
          (try ignore (Str.search_forward (Str.regexp_string "governance") v 0); true
           with Not_found -> false)
      );

      test_case "governance.dry_run contains DRY RUN" `Quick (fun () ->
        let v = Lib.Prompt_registry.get_prompt "governance.dry_run" in
        check bool "contains DRY RUN" true
          (try ignore (Str.search_forward (Str.regexp_string "DRY RUN") v 0); true
           with Not_found -> false)
      );
    ]);

    ("list_prompts", [
      test_case "list_prompts returns all 5 entries" `Quick (fun () ->
        let prompts = Lib.Prompt_registry.list_prompts () in
        check int "5 registered prompts" 5 (List.length prompts)
      );

      test_case "list_prompts entries have correct keys" `Quick (fun () ->
        let prompts = Lib.Prompt_registry.list_prompts () in
        let keys = List.filter_map (fun j ->
          match j with
          | `Assoc l -> (match List.assoc "key" l with `String s -> Some s | _ -> None)
          | _ -> None
        ) prompts in
        check bool "has keeper.constitution" true
          (List.mem "keeper.constitution" keys);
        check bool "has governance.dry_run" true
          (List.mem "governance.dry_run" keys)
      );

      test_case "list_prompts sorted by key" `Quick (fun () ->
        let prompts = Lib.Prompt_registry.list_prompts () in
        let keys = List.filter_map (fun j ->
          match j with
          | `Assoc l -> (match List.assoc "key" l with `String s -> Some s | _ -> None)
          | _ -> None
        ) prompts in
        let sorted = List.sort String.compare keys in
        check (list string) "keys are sorted" sorted keys
      );
    ]);

    ("override", [
      test_case "set_override replaces default" `Quick (fun () ->
        let key = "keeper.constitution" in
        let original = Lib.Prompt_registry.get_prompt key in
        let override_text = "Custom constitution text for testing" in
        (match Lib.Prompt_registry.set_override key override_text with
         | Ok () -> ()
         | Error msg -> fail msg);
        let current = Lib.Prompt_registry.get_prompt key in
        check string "override applied" override_text current;
        check bool "different from original" true (current <> original);
        (* Check source *)
        check string "source is override" "override"
          (Lib.Prompt_registry.prompt_source key);
        (* Cleanup *)
        Lib.Prompt_registry.clear_prompt_override key
      );

      test_case "clear_override reverts to default" `Quick (fun () ->
        let key = "keeper.world" in
        let original = Lib.Prompt_registry.get_prompt key in
        (match Lib.Prompt_registry.set_override key "temporary override" with
         | Ok () -> ()
         | Error msg -> fail msg);
        Lib.Prompt_registry.clear_prompt_override key;
        let reverted = Lib.Prompt_registry.get_prompt key in
        check string "reverted to default" original reverted;
        check string "source is default" "default"
          (Lib.Prompt_registry.prompt_source key)
      );

      test_case "set_override rejects empty value" `Quick (fun () ->
        match Lib.Prompt_registry.set_override "keeper.world" "" with
        | Error _ -> ()
        | Ok () -> fail "should reject empty value"
      );

      test_case "set_override rejects whitespace-only value" `Quick (fun () ->
        match Lib.Prompt_registry.set_override "keeper.world" "   \n  " with
        | Error _ -> ()
        | Ok () -> fail "should reject whitespace-only value"
      );

      test_case "set_override rejects oversized value" `Quick (fun () ->
        let long = String.make 10001 'x' in
        match Lib.Prompt_registry.set_override "keeper.world" long with
        | Error msg ->
          check bool "mentions max" true
            (try ignore (Str.search_forward (Str.regexp_string "10000") msg 0); true
             with Not_found -> false)
        | Ok () -> fail "should reject oversized value"
      );
    ]);

    ("keeper_prompt_integration", [
      test_case "keeper_constitution() uses registry" `Quick (fun () ->
        let from_fn = Lib.Keeper_prompt.keeper_constitution () in
        let from_default = Lib.Keeper_prompt.keeper_constitution_default in
        (* Before any override, function should return the default *)
        check string "matches default" from_default from_fn
      );

      test_case "keeper_constitution() reflects override" `Quick (fun () ->
        let override_text = "Overridden constitution for test" in
        (match Lib.Prompt_registry.set_override "keeper.constitution" override_text with
         | Ok () -> ()
         | Error msg -> fail msg);
        let from_fn = Lib.Keeper_prompt.keeper_constitution () in
        check string "override applied via function" override_text from_fn;
        (* Cleanup *)
        Lib.Prompt_registry.clear_prompt_override "keeper.constitution"
      );
    ]);

    ("prompts_json", [
      test_case "prompts_json returns valid structure" `Quick (fun () ->
        let json = Lib.Prompt_registry.prompts_json () in
        match json with
        | `Assoc [("prompts", `List items)] ->
          check bool "has entries" true (List.length items > 0)
        | _ -> fail "unexpected JSON structure"
      );
    ]);
  ]
