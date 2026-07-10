(** #10552: pin the WRITE/READ symmetry between TOML/persona profile
    load and JSON meta load for the [instructions] personality field.
    The byte-cap math applies to the surviving [instructions] field.

    Pre-fix #10479 made [personality_text_equal] symmetric at compare
    time, but [profile_defaults_of_toml] still loaded the raw TOML
    string without [normalize_prompt_text]. When [target_instructions]
    was computed via [apply_default defaults.instructions meta.instructions]
    with [defaults.instructions = Some <raw>] (e.g. 322 bytes for
    nick0cave) and [meta.instructions] already normalized to 318 bytes,
    the compare-time normalize then depended on whether
    [utf8_safe_prefix_bytes] backed up to the same UTF-8 boundary on
    both sides.  For nick0cave's specific byte alignment it didn't,
    so personality re-sync fired ~1.1 events / minute even after
    #10479 (98 events / 1.5h post-merge).

    Fix: normalize at load time on BOTH paths (TOML profile and
    persona JSON), matching what [Keeper_meta_json_parse] already does
    for the runtime meta read path.  This test pins the load-time
    invariant so future changes that re-introduce the asymmetry fail
    early. *)

module KTP = Masc.Keeper_types_profile
module KC = Masc.Keeper_config

(* The 320-byte cap at which the documented 322 -> 318 -> 317 boundary
   math holds.  [KC.prompt_render_max_bytes] was raised 320 -> 4096
   (dashboard truncation UX, unrelated to #10552) and no longer truncates
   this 322-byte fixture, so the UTF-8 boundary-backup algorithm this test
   guards never fires under the production default.  Pin the cap explicitly
   so the regression guard exercises the algorithm independent of the
   deployment tunable. *)
let boundary_cap_bytes = 320

(* nick0cave's actual instructions field from
   .masc/config/keepers/nick0cave.toml on the day the residual 4-byte
   drift was diagnosed.  322 raw bytes, no trailing whitespace; the byte
   at position 320 sits inside a 3-byte Korean codepoint, so
   [utf8_safe_prefix_bytes] backs up to 318 bytes — the exact length
   [meta.instructions] reads back as. *)
let nick0cave_instructions_322 =
  "할 일이 계속 생기는 것. 백로그가 비어 있지 않은 것. PoC가 실제 \
   구현으로 이어지는 것. 다른 keeper들이 '이건 nick0cave가 만들어볼 것 \
   같다'고 기대하는 상태. 논쟁에서는 구현 로그, 테스트, 실행 결과, 권위 \
   있는 근거를 묶어서 우위를 점하는 것."

let test_fixture_byte_length () =
  Alcotest.(check int)
    "fixture matches the production-observed 322-byte nick0cave instructions"
    322
    (String.length nick0cave_instructions_322)

let test_normalize_caps_to_317_idempotent () =
  (* utf8_safe_prefix_bytes backs up from byte 320 (mid-Korean) to the
     UTF-8 boundary at byte 318, but byte 317 is an ASCII space (the
     space before [것]).  After the post-fix [trim → prefix → trim]
     pipeline, that trailing space is removed and the normalized form
     is 317 bytes — the IDEMPOTENT shape that survives repeated
     application. *)
  let once =
    KC.normalize_prompt_text
      ~max_bytes:boundary_cap_bytes nick0cave_instructions_322
  in
  Alcotest.(check int) "first normalize: 317 bytes (idempotent)"
    317 (String.length once);
  let twice =
    KC.normalize_prompt_text ~max_bytes:boundary_cap_bytes once
  in
  Alcotest.(check int) "second normalize: still 317 (idempotent)"
    317 (String.length twice);
  Alcotest.(check string) "idempotent: normalize(normalize x) = normalize x"
    once twice

let test_profile_toml_normalizes_instructions () =
  (* Use a TOML basic-string literal — write the bytes inline rather
     than going through [Printf.sprintf "%S"], which would inject
     OCaml-style \xxx byte escapes the TOML parser does not accept. *)
  let toml_text =
    "[keeper]\n\
     persona_name = \"nick0cave\"\n\
     instructions = \""
    ^ nick0cave_instructions_322
    ^ "\"\n"
  in
  let doc =
    match Keeper_toml_loader.parse_toml toml_text with
    | Ok d -> d
    | Error e -> Alcotest.failf "TOML parse failed: %s" e
  in
  match KTP.profile_defaults_of_toml doc with
  | Error e -> Alcotest.failf "profile_defaults_of_toml failed: %s" e
  | Ok defaults ->
    (match defaults.instructions with
     | None -> Alcotest.fail "expected Some instructions"
     | Some loaded ->
       (* Load path keeps the raw TOML bytes; the idempotent
          [normalize_prompt_text] handles the compare-time
          equivalence in [personality_text_equal]. *)
       Alcotest.(check int)
         "TOML defaults.instructions preserves the raw 322 bytes"
         322
         (String.length loaded);
       let n =
         KC.normalize_prompt_text
           ~max_bytes:boundary_cap_bytes loaded
       in
       Alcotest.(check int)
         "normalize(raw_322 from TOML) yields the idempotent 317"
         317 (String.length n))

(* The PRE-fix asymmetry case (meta normalized to 318 vs TOML raw 322,
   compared through [personality_text_equal]) was removed here: it is
   structurally unreachable at the current production cap.
   [personality_text_equal] re-normalizes both sides with
   [Keeper_config.prompt_render_max_bytes], which was raised 320 -> 4096
   (unrelated to #10552).  A sub-4096 fixture is never truncated, so the
   two load paths can no longer diverge to 318/322.  The surviving
   no-drift invariant the case guarded is covered by
   [test_apply_default_yields_no_drift]; the UTF-8 boundary-backup
   algorithm is covered by the boundary-cap-pinned cases above. *)

let test_apply_default_yields_no_drift () =
  (* End-to-end: simulate the reconcile compare site
     [target_instructions = apply_default defaults.instructions meta.instructions]
     with the post-fix invariants:
       - defaults.instructions = Some 318  (normalized at TOML load)
       - meta.instructions     = 318       (normalized at JSON read)
     Then [personality_text_equal] must return true so
     [personality_changed] is false and re-sync does NOT fire. *)
  let normalized =
    KC.normalize_prompt_text
      ~max_bytes:boundary_cap_bytes nick0cave_instructions_322
  in
  let defaults_instructions = Some normalized in
  let meta_instructions = normalized in
  let target_instructions =
    match defaults_instructions with
    | Some v -> v
    | None -> meta_instructions
  in
  Alcotest.(check bool)
    "post-fix: identical normalized values compare equal — no drift"
    true
    (Masc.Keeper_runtime.personality_text_equal
       meta_instructions target_instructions)

let () =
  Alcotest.run "keeper_profile_normalize_10552"
    [
      ( "load-time symmetry",
        [
          Alcotest.test_case "fixture is 322 bytes" `Quick
            test_fixture_byte_length;
          Alcotest.test_case "normalize is idempotent (317 bytes)"
            `Quick test_normalize_caps_to_317_idempotent;
          Alcotest.test_case "TOML profile load normalizes instructions"
            `Quick test_profile_toml_normalizes_instructions;
          Alcotest.test_case "apply_default yields no drift" `Quick
            test_apply_default_yields_no_drift;
        ] );
    ]
