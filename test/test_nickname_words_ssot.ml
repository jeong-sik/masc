(* RFC-0089 — nickname word-list SSOT. The agent-nickname adjective/animal
   vocabulary lives once in [Nickname_words] (masc.config). The workspace-side
   generator ([Nickname]) and the auth-side classifier ([Auth_nickname]) both
   read it, so a name the generator produces is always recognized by the auth
   classifier — the two lists can no longer drift. *)

open Alcotest

let test_word_list_sizes () =
  check int "30 adjectives" 30 (Array.length Nickname_words.adjectives);
  check int "30 animals" 30 (Array.length Nickname_words.animals)

let test_canonical_words_present () =
  check bool "\"swift\" is an adjective" true
    (Array.exists (String.equal "swift") Nickname_words.adjectives);
  check bool "\"fox\" is an animal" true
    (Array.exists (String.equal "fox") Nickname_words.animals)

let test_cross_module_agreement () =
  (* Both modules consult the same shared lists, so a dictionary-shaped name is
     accepted by the strict generator-side check and the auth-side extractor. *)
  check bool "Nickname strict-accepts a shared-vocabulary name" true
    (Nickname.is_dictionary_generated_nickname "qa-swift-fox");
  check (option string) "Auth extracts the agent prefix from the same name"
    (Some "qa")
    (Auth_nickname.extract_agent_type_prefix "qa-swift-fox")

let test_generator_output_recognized () =
  (* Whatever adjective/animal [generate] picks, it is from the shared list, so
     the strict classifier always recognizes its own output. *)
  check bool "generated nickname is recognized as dictionary-generated" true
    (Nickname.is_dictionary_generated_nickname (Nickname.generate "qa"))

let test_non_dictionary_rejected () =
  check bool "non-dictionary adjective is rejected (the list is consulted)" false
    (Nickname.is_dictionary_generated_nickname "qa-notword-fox")

let () =
  run "nickname_words_ssot"
    [
      ( "ssot",
        [
          test_case "word-list sizes pinned" `Quick test_word_list_sizes;
          test_case "canonical words present" `Quick test_canonical_words_present;
          test_case "cross-module agreement" `Quick test_cross_module_agreement;
          test_case "generator output recognized" `Quick
            test_generator_output_recognized;
          test_case "non-dictionary rejected" `Quick test_non_dictionary_rejected;
        ] );
    ]
