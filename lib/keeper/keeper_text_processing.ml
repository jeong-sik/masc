(** Keeper_text_processing — text processing functions shared by
    [Keeper_context_runtime] and [Keeper_prompt].

    Handles reply markup stripping, proactive text normalisation,
    quality checks, and fragment detection. *)

(* Pre-compiled regex patterns — compiled once at module init. *)
let re_whitespace = Re.Pcre.re "[ \t\r\n]+" |> Re.compile
let re_terminal_punct = Re.Pcre.re "[.!?。！？]$" |> Re.compile
let re_korean_ending =
  Re.Pcre.re "(다|요|니다|습니다|중입니다|함)$" |> Re.compile
let re_unclosed_bracket = Re.Pcre.re {|["'(\[{]$|} |> Re.compile
let re_trailing_punct = Re.Pcre.re "[:;,\\-]$" |> Re.compile
let re_trailing_connector =
  Re.Pcre.re "(and|or|with|to|for|그리고|또는|및)$" |> Re.compile

let utf8_char_width s i =
  let byte = Char.code s.[i] in
  if byte land 0x80 = 0 then 1
  else if byte land 0xE0 = 0xC0 then 2
  else if byte land 0xF0 = 0xE0 then 3
  else if byte land 0xF8 = 0xF0 then 4
  else 1

let truncate_utf8_prefix ~max_bytes s =
  let max_bytes = max 0 max_bytes in
  let len = String.length s in
  if len <= max_bytes then s, false
  else
    let rec loop i =
      if i >= len
      then i
      else
        let next = i + utf8_char_width s i in
        if next > max_bytes then i else loop next
    in
    String.sub s 0 (loop 0), true

(* Observability for SKILL: / SKILL_REASON: line scrubbing.  The
   skill-route markers are the resonance-loop input for the
   *skill* marker — assistant replies that still carry them indicate
   the agent is echoing routing metadata back into reply prose.
   Closes the silent gap noted in
   .tmp/memory-compacting-analysis.html (reply skill-route scrub
   visibility). *)
let () =
  Otel_metric_store.register_counter
    ~name:Keeper_metrics.(to_string ReplySkillRouteStrips)
    ~help:
      "Total [Keeper_text_processing.strip_internal_reply_markup] \
       invocations that stripped one or more SKILL: / \
       SKILL_REASON: lines.  Rising rate is the resonance-loop \
       input indicator for the *skill* marker."
    ();
  Otel_metric_store.register_counter
    ~name:Keeper_metrics.(to_string ReplySkillRouteLinesRemoved)
    ~help:
      "Total SKILL: / SKILL_REASON: lines stripped from raw replies. \
       Divide by [_reply_skill_route_strips] for lines-per-invocation."
    ()
;;

(* Observability for the explicit reply-source chain. *)
let () =
  Otel_metric_store.register_counter
    ~name:Keeper_metrics.(to_string UserVisibleReplySource)
    ~help:
      "Total [user_visible_reply_text] returns, classified by label \
       [source] (governed by Keeper_user_visible_reply_source).  \
       Rising [hardcoded_default] rate is the operational signal \
       that the LLM produced no usable reply at all."
    ()
;;

let record_user_visible_reply_source
    ~(source : Keeper_user_visible_reply_source.t) =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string UserVisibleReplySource)
    ~labels:
      [ ("source", Keeper_user_visible_reply_source.to_label source) ]
    ()

let strip_internal_reply_markup (raw : string) : string =
  let skill_lines = Keeper_skill_routing.count_skill_route_lines raw in
  if skill_lines > 0 then begin
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ReplySkillRouteStrips)
      ();
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ReplySkillRouteLinesRemoved)
      ~delta:(float_of_int skill_lines)
      ()
  end;
  raw
  |> Keeper_skill_routing.strip_skill_route_lines
  |> String.trim

let user_visible_reply_text ?fallback (raw : string) : string =
  match String_util.trim_to_option (strip_internal_reply_markup raw) with
  | Some text ->
    record_user_visible_reply_source
      ~source:Keeper_user_visible_reply_source.Stripped_raw;
    text
  | None -> (
      match Option.bind fallback String_util.trim_to_option with
      | Some text ->
        record_user_visible_reply_source
          ~source:Keeper_user_visible_reply_source.Fallback_param;
        text
      | None ->
        record_user_visible_reply_source
          ~source:Keeper_user_visible_reply_source.Hardcoded_default;
        Log.Keeper.warn
          "user_visible_reply_text: no visible reply was produced (raw_len=%d)"
          (String.length raw);
        "No visible reply was produced.")

let normalize_proactive_text (raw : string) : string =
  raw
  |> strip_internal_reply_markup
  |> Re.replace_string re_whitespace ~by:" "
  |> String.trim

let extract_checkin_text (raw : string) : string option =
  let cleaned = normalize_proactive_text raw in
  if cleaned = "" then None else Some cleaned

let proactive_has_terminal_punct (s : string) : bool =
  let t = String.trim s in
  t <> "" && Re.execp re_terminal_punct t

let proactive_has_terminal_korean_ending (s : string) : bool =
  let t = String.trim s in
  t <> "" && Re.execp re_korean_ending t

let proactive_has_terminal_ending (s : string) : bool =
  proactive_has_terminal_punct s || proactive_has_terminal_korean_ending s

let proactive_looks_fragmentary (s : string) : bool =
  let t = String.trim s in
  t = ""
  || Re.execp re_unclosed_bracket t
  || Re.execp re_trailing_punct t

let looks_fragmentary_history_text (raw : string) : bool =
  let t = normalize_proactive_text raw in
  if t = "" then true
  else
    let hard_fragment = proactive_looks_fragmentary t in
    let has_terminal = proactive_has_terminal_ending t in
    let ends_korean_sentence = Re.execp re_korean_ending t in
    let short_unterminated =
      (not has_terminal) && (not ends_korean_sentence) && String.length t <= 24
    in
    let trailing_connector =
      (not has_terminal)
      && Re.execp re_trailing_connector (String.lowercase_ascii t)
    in
    hard_fragment || short_unterminated || trailing_connector
