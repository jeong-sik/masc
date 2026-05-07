(** Unit tests for [Provider_id] (RFC-0038 §5 Phase B). *)

open Alcotest
module P = Masc_mcp.Provider_id
module PA = Masc_mcp.Provider_adapter

(* ── Construction ─────────────────────────────────────────────── *)

let test_of_canonical_accepts_known () =
  match P.of_canonical "ollama" with
  | None -> fail "of_canonical \"ollama\" returned None"
  | Some t -> check string "round-trip" "ollama" (P.to_string t)

let test_of_canonical_rejects_unknown () =
  check (option string) "unknown name returns None"
    None
    (Option.map P.to_string (P.of_canonical "no-such-provider"))

let test_of_canonical_rejects_alias () =
  (* Aliases ("ollama-local", "claude_code", etc.) are not canonical
     names — only the cn_* values qualify. *)
  check (option string) "alias is not canonical" None
    (Option.map P.to_string (P.of_canonical "ollama-local"))

let test_of_canonical_exn_raises_on_unknown () =
  match P.of_canonical_exn "no-such-provider" with
  | exception Invalid_argument _ -> ()
  | _ -> fail "expected Invalid_argument on unknown name"

(* ── SSOT drift guard ─────────────────────────────────────────── *)

(* Provider_id duplicates the cn_* string set rather than depending
   on Provider_adapter (which would create a dependency cycle for
   modules Provider_adapter consumes).  This test catches drift
   between the two SSOT lists. *)

let test_ssot_alignment_ollama () =
  check string "Provider_id.ollama matches PA.cn_ollama"
    PA.cn_ollama (P.to_string P.ollama)

let test_ssot_alignment_llama () =
  check string "Provider_id.llama matches PA.cn_llama"
    PA.cn_llama (P.to_string P.llama)

let test_ssot_alignment_claude () =
  check string "Provider_id.claude matches PA.cn_claude"
    PA.cn_claude (P.to_string P.claude)

let test_ssot_alignment_glm () =
  check string "Provider_id.glm matches PA.cn_glm"
    PA.cn_glm (P.to_string P.glm)

let test_ssot_alignment_kimi () =
  check string "Provider_id.kimi matches PA.cn_kimi"
    PA.cn_kimi (P.to_string P.kimi)

let test_ssot_alignment_codex () =
  check string "Provider_id.codex matches PA.cn_codex"
    PA.cn_codex (P.to_string P.codex)

let test_ssot_alignment_gemini () =
  check string "Provider_id.gemini matches PA.cn_gemini"
    PA.cn_gemini (P.to_string P.gemini)

let test_ssot_alignment_custom () =
  check string "Provider_id.custom matches PA.cn_custom"
    PA.cn_custom (P.to_string P.custom)

(* ── Comparison ───────────────────────────────────────────────── *)

let test_equal_reflexive () =
  check bool "ollama equals ollama" true (P.equal P.ollama P.ollama)

let test_equal_distinguishes_kinds () =
  check bool "ollama not equal claude" false (P.equal P.ollama P.claude)

let test_matches_string_canonical () =
  check bool "ollama matches \"ollama\"" true
    (P.matches_string P.ollama "ollama")

let test_matches_string_distinguishes () =
  check bool "ollama does not match \"claude\"" false
    (P.matches_string P.ollama "claude")

(* ── Set membership ───────────────────────────────────────────── *)

let test_all_canonical_nonempty () =
  check bool "all_canonical is non-empty" true
    (List.length P.all_canonical > 0)

let test_all_canonical_includes_ollama () =
  check bool "ollama is in all_canonical" true
    (List.exists (P.equal P.ollama) P.all_canonical)

let test_all_canonical_validates_via_of_canonical () =
  (* Every value listed in all_canonical must round-trip through
     of_canonical. *)
  List.iter
    (fun t ->
      let s = P.to_string t in
      match P.of_canonical s with
      | Some _ -> ()
      | None ->
        failf "all_canonical entry %S did not round-trip through of_canonical" s)
    P.all_canonical

(* ── Suite ─────────────────────────────────────────────────────── *)

let () =
  run "Provider_id"
    [
      "of_canonical", [
        test_case "accepts known canonical name" `Quick
          test_of_canonical_accepts_known;
        test_case "rejects unknown name" `Quick
          test_of_canonical_rejects_unknown;
        test_case "rejects alias (only canonical accepted)" `Quick
          test_of_canonical_rejects_alias;
        test_case "of_canonical_exn raises on unknown" `Quick
          test_of_canonical_exn_raises_on_unknown;
      ];
      "ssot_alignment", [
        test_case "ollama" `Quick test_ssot_alignment_ollama;
        test_case "llama" `Quick test_ssot_alignment_llama;
        test_case "claude" `Quick test_ssot_alignment_claude;
        test_case "glm" `Quick test_ssot_alignment_glm;
        test_case "kimi" `Quick test_ssot_alignment_kimi;
        test_case "codex" `Quick test_ssot_alignment_codex;
        test_case "gemini" `Quick test_ssot_alignment_gemini;
        test_case "custom" `Quick test_ssot_alignment_custom;
      ];
      "comparison", [
        test_case "equal is reflexive" `Quick test_equal_reflexive;
        test_case "equal distinguishes kinds" `Quick
          test_equal_distinguishes_kinds;
        test_case "matches_string canonical" `Quick
          test_matches_string_canonical;
        test_case "matches_string distinguishes" `Quick
          test_matches_string_distinguishes;
      ];
      "all_canonical", [
        test_case "non-empty" `Quick test_all_canonical_nonempty;
        test_case "includes ollama" `Quick test_all_canonical_includes_ollama;
        test_case "every entry round-trips" `Quick
          test_all_canonical_validates_via_of_canonical;
      ];
    ]
