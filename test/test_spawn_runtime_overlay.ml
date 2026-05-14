open Alcotest
module Spawn_overlay = Masc_mcp.Spawn_runtime_overlay

let test_resolve_spawn_aliases () =
  check (option string) "claude code alias" (Some "claude")
    (Spawn_overlay.resolve_spawn_key "claude-code");
  check (option string) "gemini cli alias" (Some "gemini")
    (Spawn_overlay.resolve_spawn_key "gemini_cli");
  check (option string) "glm is not spawnable" None
    (Spawn_overlay.resolve_spawn_key "glm")
;;

let test_spawnable_canonical_names () =
  let names = Spawn_overlay.spawnable_canonical_names () in
  check bool "contains llama" true (List.mem "llama" names);
  check bool "contains claude" true (List.mem "claude" names);
  check bool "contains codex" true (List.mem "codex" names);
  check bool "contains gemini" true (List.mem "gemini" names);
  check bool "does not contain ollama" false (List.mem "ollama" names)
;;

let test_local_label_helper () =
  check string "local label" "llama:test-model"
    (Spawn_overlay.make_local_label "test-model")
;;

let test_bare_ollama_guard () =
  check bool "explicit ollama model is not bare" false
    (Spawn_overlay.is_bare_ollama_label "ollama:test-model");
  if Spawn_overlay.is_bare_ollama_label "ollama" then
    check bool "migration mentions explicit model label" true
      (String.contains (Spawn_overlay.bare_ollama_migration_message ()) ':')
;;

let () =
  run "spawn_runtime_overlay"
    [ ( "spawn"
      , [ test_case "resolve spawn aliases" `Quick test_resolve_spawn_aliases
        ; test_case "spawnable canonical names" `Quick test_spawnable_canonical_names
        ; test_case "local label helper" `Quick test_local_label_helper
        ; test_case "bare ollama guard" `Quick test_bare_ollama_guard
        ] )
    ]
;;
