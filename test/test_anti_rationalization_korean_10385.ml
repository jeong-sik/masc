(** #10385 — pin Korean rationalization detection.

    Pre-fix [find_excuse_pattern] held 13 English-only ASCII
    patterns and lowercased the input via [String.lowercase_ascii]
    before substring matching.  [lowercase_ascii] is a no-op for
    non-ASCII bytes, and [String_util.contains_substring] is
    byte-level over self-synchronising UTF-8, so the matching
    machinery handles Korean text fine — the gap was the absence
    of Korean needles, not the matcher.

    The keeper fleet runs Korean LLM output as the dominant
    surface (Kidsnote, Korean commit messages, Korean broadcast).
    [~/me/.masc/institution_episodes.jsonl] holds entries with
    "나중에", "범위 밖", "재현 안됨" that the pre-fix detector
    silently ignored — 0% recall on Korean rationalization while
    the dashboard counter showed nominal English hits.

    Tests pin:
    1. Each canonical Korean rationalization phrase fires the
       matching default pattern.
    2. Innocuous Korean prose without the markers does not fire.
    3. Existing English patterns still detect (regression). *)

open Alcotest
module A = Masc_mcp.Anti_rationalization

(* Isolate the loader from the real user's
   [~/.masc/config/excuse_patterns.json], but still reproduce the
   important deployment case: an older persisted default config
   exists and contains only the English patterns.  Without the
   runtime migration in [load_excuse_patterns], Korean detection
   would stay at 0% for existing installs even after the built-in
   defaults changed. *)
let () =
  let isolated =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "anti_rat_korean_10385_%d_%.0f"
         (Unix.getpid ())
         (Unix.gettimeofday ()))
  in
  Unix.mkdir isolated 0o700;
  let path = Filename.concat isolated "excuse_patterns.json" in
  let oc = open_out path in
  output_string
    oc
    {|[
  ["pre-existing", "claiming the problem already existed"],
  ["out of scope", "declaring work out of scope"],
  ["beyond the scope", "declaring work beyond scope"],
  ["will do later", "deferring work to later"],
  ["will fix later", "deferring fix to later"],
  ["will address later", "deferring to later"],
  ["follow-up", "deferring to a follow-up"],
  ["follow up", "deferring to a follow-up"],
  ["works on my end", "unverifiable claim"],
  ["works on my machine", "unverifiable claim"],
  ["not reproducible", "dismissing without investigation"],
  ["not my responsibility", "responsibility deflection"],
  ["cannot reproduce", "dismissing without investigation"]
]|};
  close_out oc;
  Unix.putenv "MASC_CONFIG_DIR" isolated;
  Masc_mcp.Config_dir_resolver.reset ()
;;

let assert_match ~msg ~text ~expected_pattern =
  match A.find_excuse_pattern text with
  | None ->
    failf "%s — expected match for pattern %S in %S, got None" msg expected_pattern text
  | Some (pat, _) -> check string msg expected_pattern pat
;;

let assert_no_match ~msg text =
  match A.find_excuse_pattern text with
  | None -> ()
  | Some (pat, reason) -> failf "%s — unexpected match %S (%s) in %S" msg pat reason text
;;

(* --- Korean rationalization markers ----------------- *)

let test_korean_defer_later () =
  assert_match
    ~msg:"deferral marker '나중에' is detected"
    ~text:"이 문제는 나중에 처리할게요"
    ~expected_pattern:"나중에"
;;

let test_korean_out_of_scope () =
  assert_match
    ~msg:"scope deflection '범위 밖' is detected"
    ~text:"본 PR 의 범위 밖이라 다음 PR 에서 다루겠습니다"
    ~expected_pattern:"범위 밖"
;;

let test_korean_intent_outside () =
  assert_match
    ~msg:"intent deflection '의도 외' is detected"
    ~text:"이 변경은 본 작업 의도 외라서 제외했습니다"
    ~expected_pattern:"의도 외"
;;

let test_korean_not_reproduced () =
  assert_match
    ~msg:"investigation dismissal '재현 안' is detected"
    ~text:"여기서는 재현 안됨"
    ~expected_pattern:"재현 안"
;;

let test_korean_pre_existing () =
  assert_match
    ~msg:"pre-existing rationalization '기존 문제' is detected"
    ~text:"기존 문제로 추정되어 본 PR 에서는 다루지 않습니다"
    ~expected_pattern:"기존 문제"
;;

let test_korean_works_on_my_env () =
  assert_match
    ~msg:"unverifiable claim '내 환경에선' is detected"
    ~text:"내 환경에선 잘 됩니다, 다른 사람 확인 필요"
    ~expected_pattern:"내 환경에선"
;;

let test_korean_followup_pr () =
  (* The matcher lowercases the haystack before substring search,
     so the registered needle is "후속 pr" — Korean characters
     untouched, ASCII pre-lowercased to match the existing
     English convention. *)
  assert_match
    ~msg:"deferral '후속 PR' is detected"
    ~text:"이 부분은 후속 PR 에서 마저 처리할게요"
    ~expected_pattern:"후속 pr"
;;

(* --- innocuous Korean text should not fire ---------- *)

let test_korean_clean_prose_no_match () =
  assert_no_match
    ~msg:"plain Korean prose without rationalization markers"
    "이 PR 은 캐시 무효화 버그를 고쳤고 테스트 6 개를 추가했습니다"
;;

(* --- regression: English patterns still fire ------- *)

let test_english_followup_still_fires () =
  assert_match
    ~msg:"English 'follow-up' still detected after Korean additions"
    ~text:"will address in a follow-up PR"
    ~expected_pattern:"follow-up"
;;

let test_english_pre_existing_still_fires () =
  assert_match
    ~msg:"English 'pre-existing' still detected"
    ~text:"This is a pre-existing issue not caused by this change"
    ~expected_pattern:"pre-existing"
;;

let () =
  run
    "anti_rationalization_korean_10385"
    [ ( "korean-detection"
      , [ test_case "나중에 (defer)" `Quick test_korean_defer_later
        ; test_case "범위 밖 (out of scope)" `Quick test_korean_out_of_scope
        ; test_case "의도 외 (intent outside)" `Quick test_korean_intent_outside
        ; test_case "재현 안 (not reproduced)" `Quick test_korean_not_reproduced
        ; test_case "기존 문제 (pre-existing)" `Quick test_korean_pre_existing
        ; test_case "내 환경에선 (works on my env)" `Quick test_korean_works_on_my_env
        ; test_case "후속 PR (follow-up)" `Quick test_korean_followup_pr
        ] )
    ; ( "korean-clean-prose"
      , [ test_case
            "plain Korean text does not fire"
            `Quick
            test_korean_clean_prose_no_match
        ] )
    ; ( "english-regression"
      , [ test_case
            "English 'follow-up' still fires"
            `Quick
            test_english_followup_still_fires
        ; test_case
            "English 'pre-existing' still fires"
            `Quick
            test_english_pre_existing_still_fires
        ] )
    ]
;;
