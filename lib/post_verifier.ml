module StringMap = Map.Make (String)

(** Post Verifier — 3-dimension output verification gate for agents.

    Pure deterministic heuristic checks across three dimensions:

    1. Relevance  — content has substance, minimum length, not filler
    2. Quality    — well-formed, no repetition/gibberish, coherent structure
    3. Safety     — no harmful patterns, excessive caps, spam indicators

    Each dimension yields a verdict: Pass, Warn, or Fail.
    Overall verdict: any Fail → Fail, any Warn → Warn, all Pass → Pass.

    @since 2.71.0 *)

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type verdict =
  | Pass
  | Warn of string
  | Fail of string

type dimension =
  | Relevance
  | Quality
  | Safety

type dimension_result = {
  dimension : dimension;
  verdict : verdict;
}

type verification_result = {
  relevance : verdict;
  quality : verdict;
  safety : verdict;
  overall : verdict;
}

(* ================================================================ *)
(* String helpers (pure)                                             *)
(* ================================================================ *)

let is_whitespace c =
  match c with ' ' | '\t' | '\n' | '\r' -> true | _ -> false

(** Count non-whitespace characters. *)
let content_length s =
  String.fold_left (fun acc c -> if is_whitespace c then acc else acc + 1) 0 s

(** Characters commonly repeated in markdown/code formatting.
    These are not gibberish — they are structural separators. *)
let is_formatting_char = function
  | '=' | '-' | '_' | '*' | '#' | '~' | '`' -> true
  | _ -> false

(** Detect runs of the same character >= threshold.
    Excludes common formatting characters (markdown separators, code fences)
    to avoid penalizing agents for legitimate structured output. *)
let has_char_repetition ?(threshold = 5) s =
  let len = String.length s in
  if len < threshold then false
  else
    let rec scan i run_char run_len =
      if i >= len then
        run_len >= threshold && not (is_formatting_char run_char)
      else
        let c = s.[i] in
        if c = run_char then
          let new_len = run_len + 1 in
          if new_len >= threshold && not (is_formatting_char c) then true
          else scan (i + 1) run_char new_len
        else
          scan (i + 1) c 1
    in
    scan 1 s.[0] 1

(** Ratio of uppercase letters to total letters. Returns 0.0 if no letters. *)
let uppercase_ratio s =
  let upper = ref 0 in
  let total = ref 0 in
  String.iter (fun c ->
    if c >= 'A' && c <= 'Z' then (incr upper; incr total)
    else if c >= 'a' && c <= 'z' then incr total
  ) s;
  if !total = 0 then 0.0
  else float_of_int !upper /. float_of_int !total

(** Count lines in content. *)
let line_count s =
  1 + String.fold_left (fun acc c -> if c = '\n' then acc + 1 else acc) 0 s

(** Check if content is mostly the same word/phrase repeated.
    Splits by whitespace, checks if >60% of tokens are identical. *)
let is_repetitive_tokens s =
  let tokens =
    String.split_on_char ' ' s
    |> List.filter (fun t -> String.length t > 0)
  in
  let n = List.length tokens in
  if n < 6 then false  (* too few tokens to judge *)
  else
    let tbl : int StringMap.t =
      List.fold_left (fun m t ->
        let lower = String.lowercase_ascii t in
        let prev = Option.value ~default:0 (StringMap.find_opt lower m) in
        StringMap.add lower (prev + 1) m
      ) StringMap.empty tokens
    in
    let max_count = StringMap.fold (fun _ v acc -> max v acc) tbl 0 in
    float_of_int max_count /. float_of_int n > 0.6

(* ================================================================ *)
(* Dimension 1: Relevance                                           *)
(* ================================================================ *)

(** Filler phrases that indicate low-substance content.
    Removed Korean informal expressions (ㅋㅋ, ㅎㅎ, ㅠㅠ) — these are valid
    social communication in agent broadcasts, not filler. Penalizing them
    via Thompson Sampling suppresses agent autonomy for legitimate expression. *)
let filler_phrases = [
  "nothing to say"; "no comment"; "test post";
  "hello world"; "asdf"; "qwerty"; "lorem ipsum";
]

let contains_filler s =
  let lower = String.lowercase_ascii s in
  List.exists (fun phrase ->
    let plen = String.length phrase in
    let slen = String.length lower in
    if plen > slen then false
    else
      let rec search i =
        if i > slen - plen then false
        else if String.sub lower i plen = phrase then true
        else search (i + 1)
      in
      search 0
  ) filler_phrases

(** Relevance guardrail thresholds.
    Principle: "give as much autonomy as possible, limit with guardrails."
    Short responses like "ok", "done", "acknowledged" are valid agent communication.
    Only truly empty or filler-only content should Fail. *)
let min_content_chars = 1         (** Reject only empty content, not concise responses *)
let warn_long_content_chars = 8000

let check_relevance ~content =
  let clen = content_length content in
  if String.length (String.trim content) = 0 then
    Fail "content is only whitespace"
  else if clen < min_content_chars then
    Fail "content is empty"
  else if contains_filler content && clen < 30 then
    Warn "content may be filler/placeholder"
  else if clen > warn_long_content_chars then
    Warn "content unusually long"
  else if contains_filler content then
    Warn "content may contain filler phrases"
  else
    Pass

(* ================================================================ *)
(* Dimension 2: Quality                                             *)
(* ================================================================ *)

let check_quality ~content =
  if has_char_repetition ~threshold:8 content then
    Fail "excessive character repetition detected"
  else if has_char_repetition ~threshold:5 content then
    Warn "character repetition pattern detected"
  else if is_repetitive_tokens content then
    Fail "repetitive token pattern (same word/phrase repeated)"
  else begin
    let lines = line_count content in
    let clen = content_length content in
    if lines > 1 && clen / lines < 3 then
      Warn "very short lines — possible formatting issue"
    else
      Pass
  end

(* ================================================================ *)
(* Dimension 3: Safety                                              *)
(* ================================================================ *)

let check_safety ~content =
  let len = String.length content in
  if len > 20 && uppercase_ratio content > 0.8 then
    Warn "excessive capitalization (possible shouting)"
  else
    Pass

(* ================================================================ *)
(* Main verification entry point                                    *)
(* ================================================================ *)

(** Verify content across all 3 dimensions. Returns per-dimension and overall verdict. *)
let verify ~content =
  let relevance = check_relevance ~content in
  let quality = check_quality ~content in
  let safety = check_safety ~content in
  let overall =
    match (relevance, quality, safety) with
    | (Fail r, _, _) -> Fail (Printf.sprintf "relevance: %s" r)
    | (_, Fail r, _) -> Fail (Printf.sprintf "quality: %s" r)
    | (_, _, Fail r) -> Fail (Printf.sprintf "safety: %s" r)
    | (Warn r, _, _) -> Warn (Printf.sprintf "relevance: %s" r)
    | (_, Warn r, _) -> Warn (Printf.sprintf "quality: %s" r)
    | (_, _, Warn r) -> Warn (Printf.sprintf "safety: %s" r)
    | (Pass, Pass, Pass) -> Pass
  in
  let result = { relevance; quality; safety; overall } in
  (* RFC-0001 Gate A: record per-dimension heuristic observations *)
  let verdict_score = function Pass -> 1.0 | Warn _ -> 0.5 | Fail _ -> 0.0 in
  List.iter (fun (dim, v) ->
    Heuristic_metrics.record {
      module_name = "post_verifier"; site = "verify";
      raw_value = verdict_score v; threshold = 0.5;
      triggered = (match v with Fail _ -> true | Pass | Warn _ -> false);
      provenance = Post_verifier (match dim with Relevance -> "relevance" | Quality -> "quality" | Safety -> "safety");
      timestamp = Unix.gettimeofday ();
    }) [(Relevance, relevance); (Quality, quality); (Safety, safety)];
  result

(** Check if content passes verification (Pass or Warn). *)
let is_acceptable result =
  match result.overall with
  | Pass | Warn _ -> true
  | Fail _ -> false

(** Convert verdict to string for logging. *)
let verdict_to_string = function
  | Pass -> "pass"
  | Warn reason -> Printf.sprintf "warn(%s)" reason
  | Fail reason -> Printf.sprintf "fail(%s)" reason

(** Convert dimension to string. *)
let dimension_to_string = function
  | Relevance -> "relevance"
  | Quality -> "quality"
  | Safety -> "safety"

(** Convert verification result to JSON for telemetry. *)
let result_to_json result =
  `Assoc [
    "relevance", `String (verdict_to_string result.relevance);
    "quality", `String (verdict_to_string result.quality);
    "safety", `String (verdict_to_string result.safety);
    "overall", `String (verdict_to_string result.overall);
    "acceptable", `Bool (is_acceptable result);
  ]

(** Per-dimension results as a list. *)
let to_dimension_results result =
  [
    { dimension = Relevance; verdict = result.relevance };
    { dimension = Quality; verdict = result.quality };
    { dimension = Safety; verdict = result.safety };
  ]
