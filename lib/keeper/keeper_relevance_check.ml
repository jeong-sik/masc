(** Keeper_relevance_check — structural keyword coverage verification.

    After a keeper turn, checks whether the response actually addresses
    the input signal's topics. Uses keyword intersection rather than
    LLM-based evaluation to keep the check deterministic and zero-cost. *)

(* --- stop words: common English/Korean particles that carry no topic signal --- *)
let stop_words =
  let tbl = Hashtbl.create 128 in
  List.iter (fun w -> Hashtbl.add tbl w ())
    [ "the"; "a"; "an"; "is"; "are"; "was"; "were"; "be"; "been"; "being";
      "have"; "has"; "had"; "do"; "does"; "did"; "will"; "would"; "could";
      "should"; "may"; "might"; "shall"; "can"; "need"; "must"; "ought";
      "i"; "you"; "he"; "she"; "it"; "we"; "they"; "me"; "him"; "her";
      "us"; "them"; "my"; "your"; "his"; "its"; "our"; "their";
      "this"; "that"; "these"; "those"; "which"; "who"; "whom"; "what";
      "where"; "when"; "how"; "why"; "all"; "each"; "every"; "both";
      "few"; "more"; "most"; "other"; "some"; "such"; "no"; "not";
      "only"; "own"; "same"; "so"; "than"; "too"; "very"; "just";
      "because"; "as"; "until"; "while"; "of"; "at"; "by"; "for";
      "with"; "about"; "against"; "between"; "through"; "during";
      "before"; "after"; "above"; "below"; "to"; "from"; "up"; "down";
      "in"; "out"; "on"; "off"; "over"; "under"; "again"; "further";
      "then"; "once"; "and"; "but"; "or"; "nor"; "if"; "else";
      "into"; "also"; "am";
      (* Korean particles *)
      "이"; "고"; "의"; "일";
      "를"; "로"; "와"; "으로";
      "에"; "었"; "은"; "만";
      "이라"; "보다"; "다";
      "지"; "직"; "있다"; "있다면";
      "하"; "했고"; "습니다";
      "거나"; "적"; "었";
      (* common keeper terms that aren't topic-discriminative *)
      "keeper"; "turn"; "response"; "signal"; "observation"; "please";
      "thank"; "yes"; "no"; "ok"; "okay" ];
  tbl

type relevance_result = {
  input_keywords : string list;
  covered_keywords : string list;
  uncovered_keywords : string list;
  coverage_ratio : float;
}

let is_stop_word w = Hashtbl.mem stop_words w

(** Extract meaningful keywords from a string.
    Lowercase, split on whitespace/punctuation, remove stop words and
    short tokens (< 2 chars). *)
let extract_keywords (text : string) : string list =
  let normalized =
    text
    |> String.lowercase_ascii
    |> fun s ->
      String.map (fun c ->
        match c with
        | 'a'..'z' | '0'..'9' | ' ' | '\n' | '\t' -> c
        | _ -> ' ') s
  in
  let tokens = String.split_on_char ' ' normalized in
  let seen = Hashtbl.create 16 in
  List.filter_map (fun tok ->
    let t = String.trim tok in
    if String.length t < 2 then None
    else if is_stop_word t then None
    else if Hashtbl.mem seen t then None
    else (Hashtbl.add seen t (); Some t)
  ) tokens

(** Check keyword coverage of a reply against input keywords. *)
let check
    ?(min_coverage : float = 0.3)
    ~(input_content : string)
    ~(reply_text : string)
    () :
  relevance_result
  =
  let input_kw = extract_keywords input_content in
  let reply_kw =
    let reply_lower = String.lowercase_ascii reply_text in
    extract_keywords reply_lower
  in
  let reply_set = Hashtbl.create 32 in
  List.iter (fun kw -> Hashtbl.replace reply_set kw ()) reply_kw;
  let covered, uncovered =
    List.partition (fun kw -> Hashtbl.mem reply_set kw) input_kw
  in
  let ratio =
    match List.length input_kw with
    | 0 -> 1.0  (* no keywords to cover → trivially relevant *)
    | n -> Float.of_int (List.length covered) /. Float.of_int n
  in
  { input_keywords = input_kw;
    covered_keywords = covered;
    uncovered_keywords = uncovered;
    coverage_ratio = ratio }

let is_relevant (r : relevance_result) : bool =
  r.coverage_ratio >= 0.3
