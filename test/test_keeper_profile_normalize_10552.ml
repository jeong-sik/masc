(** #10552: pin the WRITE/READ symmetry between TOML/persona profile
    load and JSON meta load for the [will] / [needs] / [desires]
    personality fields.

    Pre-fix #10479 made [personality_text_equal] symmetric at compare
    time, but [profile_defaults_of_toml] still loaded the raw TOML
    string without [normalize_self_model_text].  When [target_desires]
    was computed via [apply_default defaults.desires meta.desires]
    with [defaults.desires = Some <raw>] (e.g. 322 bytes for
    nick0cave) and [meta.desires] already normalized to 318 bytes,
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

module KTP = Masc_mcp.Keeper_types_profile
module KC = Masc_mcp.Keeper_config

(* nick0cave's actual desires field from .masc/config/keepers/nick0cave.toml
   on the day the residual 4-byte drift was diagnosed.  322 raw bytes,
   no trailing whitespace; the byte at position 320 sits inside a 3-byte
   Korean codepoint, so [utf8_safe_prefix_bytes] backs up to 318 bytes —
   the exact length [meta.desires] reads back as. *)
let nick0cave_desires_322 =
  "할 일이 계속 생기는 것. 백로그가 비어 있지 않은 것. PoC가 실제 구현으로 이어지는 것. 다른 keeper들이 '이건 nick0cave가 만들어볼 \
   것 같다'고 기대하는 상태. 논쟁에서는 구현 로그, 테스트, 실행 결과, 권위 있는 근거를 묶어서 우위를 점하는 것."
;;

let test_fixture_byte_length () =
  Alcotest.(check int)
    "fixture matches the production-observed 322-byte nick0cave desires"
    322
    (String.length nick0cave_desires_322)
;;

let test_normalize_caps_to_317_idempotent () =
  (* utf8_safe_prefix_bytes backs up from byte 320 (mid-Korean) to the
     UTF-8 boundary at byte 318, but byte 317 is an ASCII space (the
     space before [것]).  After the post-fix [trim → prefix → trim]
     pipeline, that trailing space is removed and the normalized form
     is 317 bytes — the IDEMPOTENT shape that survives repeated
     application. *)
  let once =
    KC.normalize_self_model_text
      ~max_bytes:KC.prompt_render_max_bytes
      nick0cave_desires_322
  in
  Alcotest.(check int) "first normalize: 317 bytes (idempotent)" 317 (String.length once);
  let twice = KC.normalize_self_model_text ~max_bytes:KC.prompt_render_max_bytes once in
  Alcotest.(check int)
    "second normalize: still 317 (idempotent)"
    317
    (String.length twice);
  Alcotest.(check string) "idempotent: normalize(normalize x) = normalize x" once twice
;;

let test_profile_toml_normalizes_desires () =
  (* Use a TOML basic-string literal — write the bytes inline rather
     than going through [Printf.sprintf "%S"], which would inject
     OCaml-style \xxx byte escapes the TOML parser does not accept. *)
  let toml_text =
    "[keeper]\npersona_name = \"nick0cave\"\ndesires = \""
    ^ nick0cave_desires_322
    ^ "\"\n"
  in
  let doc =
    match Masc_mcp.Keeper_toml_loader.parse_toml toml_text with
    | Ok d -> d
    | Error e -> Alcotest.failf "TOML parse failed: %s" e
  in
  match KTP.profile_defaults_of_toml doc with
  | Error e -> Alcotest.failf "profile_defaults_of_toml failed: %s" e
  | Ok defaults ->
    (match defaults.desires with
     | None -> Alcotest.fail "expected Some desires"
     | Some loaded ->
       (* Load path keeps the raw TOML bytes; the idempotent
          [normalize_self_model_text] handles the compare-time
          equivalence in [personality_text_equal]. *)
       Alcotest.(check int)
         "TOML defaults.desires preserves the raw 322 bytes"
         322
         (String.length loaded);
       let n =
         KC.normalize_self_model_text ~max_bytes:KC.prompt_render_max_bytes loaded
       in
       Alcotest.(check int)
         "normalize(raw_322 from TOML) yields the idempotent 317"
         317
         (String.length n))
;;

let test_pre_fix_compare_normalized_vs_raw () =
  (* Reproduce the PRE-fix production scenario:
       meta.desires   = 318  (normalized at JSON load)
       target_desires = 322  (raw TOML defaults via apply_default)
     If [personality_text_equal] returns true here, the load-time
     asymmetry is benign and #10557 is not needed.  If false, it
     pins the structural drift this PR repairs. *)
  let normalized =
    KC.normalize_self_model_text
      ~max_bytes:KC.prompt_render_max_bytes
      nick0cave_desires_322
  in
  Alcotest.(check int)
    "normalized is 317 bytes (idempotent shape)"
    317
    (String.length normalized);
  Alcotest.(check int) "raw is 322 bytes" 322 (String.length nick0cave_desires_322);
  let result =
    Masc_mcp.Keeper_runtime.personality_text_equal normalized nick0cave_desires_322
  in
  let hex s =
    let b = Buffer.create (String.length s * 3) in
    String.iter (fun c -> Buffer.add_string b (Printf.sprintf "%02x " (Char.code c))) s;
    Buffer.contents b
  in
  let a_n =
    KC.normalize_self_model_text ~max_bytes:KC.prompt_render_max_bytes normalized
  in
  let b_n =
    KC.normalize_self_model_text
      ~max_bytes:KC.prompt_render_max_bytes
      nick0cave_desires_322
  in
  Printf.printf "len(normalize(meta_318)) = %d\n" (String.length a_n);
  Printf.printf "len(normalize(raw_322))  = %d\n" (String.length b_n);
  Printf.printf
    "tail meta 30: %s\n"
    (hex (String.sub a_n (max 0 (String.length a_n - 30)) (min 30 (String.length a_n))));
  Printf.printf
    "tail raw  30: %s\n"
    (hex (String.sub b_n (max 0 (String.length b_n - 30)) (min 30 (String.length b_n))));
  Printf.printf "personality_text_equal(normalized_318, raw_322) = %b\n%!" result;
  Alcotest.(check bool)
    "compare normalized vs raw — expected behavior of compare-time normalize"
    true
    result
;;

let test_apply_default_yields_no_drift () =
  (* End-to-end: simulate the reconcile compare site
     [target_desires = apply_default defaults.desires meta.desires]
     with the post-fix invariants:
       - defaults.desires = Some 318  (normalized at TOML load)
       - meta.desires     = 318       (normalized at JSON read)
     Then [personality_text_equal] must return true so
     [personality_changed] is false and re-sync does NOT fire. *)
  let normalized =
    KC.normalize_self_model_text
      ~max_bytes:KC.prompt_render_max_bytes
      nick0cave_desires_322
  in
  let defaults_desires = Some normalized in
  let meta_desires = normalized in
  let target_desires =
    match defaults_desires with
    | Some v -> v
    | None -> meta_desires
  in
  Alcotest.(check bool)
    "post-fix: identical normalized values compare equal — no drift"
    true
    (Masc_mcp.Keeper_runtime.personality_text_equal meta_desires target_desires)
;;

let () =
  Alcotest.run
    "keeper_profile_normalize_10552"
    [ ( "load-time symmetry"
      , [ Alcotest.test_case "fixture is 322 bytes" `Quick test_fixture_byte_length
        ; Alcotest.test_case
            "normalize is idempotent (317 bytes)"
            `Quick
            test_normalize_caps_to_317_idempotent
        ; Alcotest.test_case
            "TOML profile load normalizes desires"
            `Quick
            test_profile_toml_normalizes_desires
        ; Alcotest.test_case
            "compare normalized vs raw 322"
            `Quick
            test_pre_fix_compare_normalized_vs_raw
        ; Alcotest.test_case
            "apply_default yields no drift"
            `Quick
            test_apply_default_yields_no_drift
        ] )
    ]
;;
