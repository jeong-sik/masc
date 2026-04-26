(** Property-based tests for Keeper_text_processing.

    Uses QCheck via qcheck-alcotest to verify structural properties
    of text normalization, stripping, and quality checks. *)

module Tp = Masc_mcp.Keeper_text_processing

(* ── Generators ── *)

let gen_word =
  QCheck.Gen.(
    let* len = int_range 1 12 in
    let* chars =
      list_size
        (return len)
        (oneof [ char_range 'a' 'z'; char_range 'A' 'Z'; char_range '0' '9' ])
    in
    return (String.init len (fun i -> List.nth chars i)))
;;

let gen_ascii_text =
  QCheck.Gen.(
    let* words = list_size (int_range 1 8) gen_word in
    return (String.concat " " words))
;;

let korean_endings = [| "합니다"; "입니다"; "습니다"; "중입니다"; "해요"; "다"; "요"; "함" |]

let gen_korean_text =
  QCheck.Gen.(
    let* prefix = gen_ascii_text in
    let* idx = int_range 0 (Array.length korean_endings - 1) in
    return (prefix ^ korean_endings.(idx)))
;;

let arb_ascii_text = QCheck.make gen_ascii_text ~print:Fun.id
let arb_korean_text = QCheck.make gen_korean_text ~print:Fun.id

(* ── Properties ── *)

(* normalize_proactive_text is idempotent *)
let prop_normalize_idempotent =
  QCheck.Test.make ~count:1000 ~name:"normalize is idempotent" arb_ascii_text (fun text ->
    let once = Tp.normalize_proactive_text text in
    let twice = Tp.normalize_proactive_text once in
    String.equal once twice)
;;

(* strip_state_blocks preserves content without STATE markers *)
let prop_strip_state_preserves_no_markers =
  QCheck.Test.make
    ~count:1000
    ~name:"strip_state_blocks preserves non-STATE content"
    arb_ascii_text
    (fun text ->
       QCheck.assume
         (not
            (String.ends_with ~suffix:"[STATE]" text
             || String.ends_with ~suffix:"[/STATE]" text));
       let safe = String.map (fun c -> if c = '[' then '(' else c) text in
       String.equal safe (Tp.strip_state_blocks_text safe))
;;

(* strip_state_blocks removes STATE blocks *)
let prop_strip_state_removes_block =
  QCheck.Test.make
    ~count:500
    ~name:"strip_state_blocks removes STATE block"
    arb_ascii_text
    (fun inner ->
       let input = "before[STATE]" ^ inner ^ "[/STATE]after" in
       let result = Tp.strip_state_blocks_text input in
       String.equal result "beforeafter")
;;

(* terminal punct detection: non-empty text + period *)
let prop_terminal_punct =
  QCheck.Test.make
    ~count:500
    ~name:"word + period has terminal punct"
    arb_ascii_text
    (fun prefix ->
       let trimmed = String.trim prefix in
       QCheck.assume (trimmed <> "");
       let text = trimmed ^ "." in
       Tp.proactive_has_terminal_punct text)
;;

(* Korean endings detected *)
let prop_terminal_korean =
  QCheck.Test.make ~count:500 ~name:"Korean endings detected" arb_korean_text (fun text ->
    let trimmed = String.trim text in
    QCheck.assume (String.length trimmed > 2);
    Tp.proactive_has_terminal_ending trimmed)
;;

(* fragmentary detection: trailing colon (safe char class member) *)
let prop_fragmentary_trailing_colon =
  QCheck.Test.make
    ~count:200
    ~name:"trailing colon is fragmentary"
    arb_ascii_text
    (fun prefix ->
       let trimmed = String.trim prefix in
       QCheck.assume (trimmed <> "");
       let text = trimmed ^ ":" in
       Tp.proactive_looks_fragmentary text)
;;

(* normalize collapses whitespace *)
let prop_normalize_no_consecutive_spaces =
  QCheck.Test.make
    ~count:1000
    ~name:"normalize has no consecutive spaces"
    arb_ascii_text
    (fun text ->
       let normalized = Tp.normalize_proactive_text text in
       not
         (try
            ignore (Re.Str.search_forward (Re.Str.regexp "  ") normalized 0);
            true
          with
          | Not_found -> false))
;;

let () =
  let suite =
    List.map
      QCheck_alcotest.to_alcotest
      [ prop_normalize_idempotent
      ; prop_strip_state_preserves_no_markers
      ; prop_strip_state_removes_block
      ; prop_terminal_punct
      ; prop_terminal_korean
      ; prop_fragmentary_trailing_colon
      ; prop_normalize_no_consecutive_spaces
      ]
  in
  Alcotest.run "pbt_text_processing" [ "properties", suite ]
;;
