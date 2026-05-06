open Keeper_types
open Keeper_exec_shared

let assoc_replace key value fields =
  (key, value) :: List.filter (fun (name, _) -> name <> key) fields

let keeper_board_meta ?quantitative_evidence ~source meta =
  let base =
    match meta with
    | `Assoc fields -> assoc_replace "source" (`String source) fields
    | _ -> [ "source", `String source ]
  in
  let fields =
    match quantitative_evidence with
    | Some evidence -> assoc_replace "quantitative_evidence" evidence base
    | None -> base
  in
  `Assoc fields

let assoc_value_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let usable_evidence_json = function
  | `String value when String.trim value <> "" -> Some (`String value)
  | `Assoc fields when fields <> [] -> Some (`Assoc fields)
  | `List values when values <> [] -> Some (`List values)
  | _ -> None

let quantitative_evidence_arg args =
  let meta_evidence () =
    match assoc_value_opt "meta" args with
    | Some meta ->
      (match assoc_value_opt "quantitative_evidence" meta with
       | Some value -> usable_evidence_json value
       | None -> None)
    | None -> None
  in
  match assoc_value_opt "quantitative_evidence" args with
  | Some value -> (
      match usable_evidence_json value with
      | Some _ as evidence -> evidence
      | None -> meta_evidence ())
  | None -> meta_evidence ()

let string_arg key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String value) -> Some value
      | _ -> None)
  | _ -> None

let post_content_arg args =
  match string_arg "body" args with
  | Some body when String.trim body <> "" -> body
  | _ -> Option.value (string_arg "content" args) ~default:""

let re_matches pattern text =
  try
    ignore (Str.search_forward (Str.regexp_case_fold pattern) text 0);
    true
  with Not_found -> false

let contains_substring haystack needle =
  let len_haystack = String.length haystack in
  let len_needle = String.length needle in
  len_needle = 0
  ||
  let rec loop idx =
    idx + len_needle <= len_haystack
    &&
    (String.sub haystack idx len_needle = needle || loop (idx + 1))
  in
  loop 0

let content_has_inline_quantitative_evidence content =
  let lower = String.lowercase_ascii content in
  List.exists
    (contains_substring lower)
    [ "command: rg -n"; "command: grep -n"; "command: git grep -n";
      "command: wc -l"; "$ rg -n"; "$ grep -n"; "$ git grep -n";
      "$ wc -l"; "`rg -n"; "`grep -n"; "`git grep -n"; "`wc -l" ]

let is_digit = function
  | '0' .. '9' -> true
  | _ -> false

let is_numeric_claim_boundary = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | ':' -> false
  | _ -> true

let content_has_standalone_count content =
  let len = String.length content in
  let rec skip_digits idx =
    if idx < len && is_digit content.[idx] then skip_digits (idx + 1) else idx
  in
  let rec loop idx =
    if idx >= len then false
    else if is_digit content.[idx] then
      let next_idx = skip_digits idx in
      let before_ok =
        idx = 0 || is_numeric_claim_boundary content.[idx - 1]
      in
      let after_ok =
        next_idx = len || is_numeric_claim_boundary content.[next_idx]
      in
      (before_ok && after_ok) || loop next_idx
    else loop (idx + 1)
  in
  loop 0

let is_word_char = function
  | 'a' .. 'z' | '0' .. '9' | '_' -> true
  | _ -> false

let contains_word lower word =
  let len_text = String.length lower in
  let len_word = String.length word in
  let rec loop idx =
    if idx + len_word > len_text then false
    else if String.sub lower idx len_word = word then
      let before_ok = idx = 0 || not (is_word_char lower.[idx - 1]) in
      let after_idx = idx + len_word in
      let after_ok = after_idx = len_text || not (is_word_char lower.[after_idx]) in
      (before_ok && after_ok) || loop (idx + 1)
    else loop (idx + 1)
  in
  len_word > 0 && loop 0

let content_has_risky_quantitative_claim content =
  let has_line_ref =
    re_matches "[Ll][0-9][0-9]*" content
    || re_matches "[A-Za-z0-9_./-]+\\.[A-Za-z0-9_]+:[0-9][0-9]*" content
  in
  let lower = String.lowercase_ascii content in
  let has_quantifier =
    List.exists
      (contains_word lower)
      [ "site"; "sites"; "hit"; "hits"; "line"; "lines"; "occurrence";
        "occurrences"; "pattern"; "patterns"; "instance"; "instances";
        "accuracy" ]
    || re_matches "[0-9][0-9]*%" content
    || content_has_standalone_count content
  in
  has_line_ref && has_quantifier

let quantitative_claim_rejection_reason ~content ~quantitative_evidence =
  if content_has_risky_quantitative_claim content
     && Option.is_none quantitative_evidence
     && not (content_has_inline_quantitative_evidence content)
  then Some "missing_quantitative_evidence"
  else None

let ensure_keeper_board_post_args ?quantitative_evidence ~author ~source = function
  | `Assoc fields ->
    let raw_meta =
      match List.assoc_opt "meta" fields with
      | Some (`Assoc _ as meta) -> meta
      | _ -> `Assoc []
    in
    let fields =
      List.filter
        (fun (k, _) ->
          k <> "author"
          && k <> "post_kind"
          && k <> "meta"
          && k <> "quantitative_evidence")
        fields
    in
    let has_hearth =
      List.exists
        (fun (k, v) ->
           k = "hearth"
           &&
           match v with
           | `String s -> String.trim s <> ""
           | _ -> false)
        fields
    in
    let fields =
      if has_hearth
      then fields
      else ("hearth", `String author) :: List.filter (fun (k, _) -> k <> "hearth") fields
    in
    `Assoc
      ([ "author", `String author
       (* Variant SSOT: bind the literal to the Variant constructor so a
          rename of [Automation_post] forces this site to update too.
          Same pattern family as #8354 / #8392. *)
       ; "post_kind", `String
           (Board_core_classify.post_kind_to_string Board_types.Automation_post)
       ; "meta", keeper_board_meta ?quantitative_evidence ~source raw_meta
       ]
       @ fields)
  | other -> other
;;

let dispatchable_keeper_board_tool_name name =
  match Tool_name.Keeper.of_string name with
  | Some tool when Tool_name.Keeper.is_board tool -> Some tool
  | Some _ | None -> None
;;

let handle_keeper_board_tool
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  let dispatch tool_name tool_args =
    tool_result_or_error (Tool_board.handle_tool tool_name tool_args)
  in
  let dispatch_board tool tool_args =
    dispatch (Tool_name.Masc.to_string tool) tool_args
  in
  match dispatchable_keeper_board_tool_name name with
  | Some Tool_name.Keeper.Board_post ->
    let author = meta.name in
    let keeper_source = Tool_name.Keeper.to_string Tool_name.Keeper.Board_post in
    let quantitative_evidence = quantitative_evidence_arg args in
    Log.Keeper.debug
      "%s called by %s, raw args: %s"
      keeper_source
      author
      (Yojson.Safe.to_string args);
    (match
       quantitative_claim_rejection_reason
         ~content:(post_content_arg args)
         ~quantitative_evidence
     with
     | Some reason ->
       Prometheus.inc_counter
         Prometheus.metric_keeper_quantitative_claim_rejections
         ~labels:[ "keeper", author; "reason", reason ]
         ();
       error_json
         ~fields:[ "keeper", `String author; "reason", `String reason ]
         "keeper_board_post rejected: quantitative code claims with line/count references require quantitative_evidence metadata or inline rg/grep evidence"
     | None ->
       let board_args =
         ensure_keeper_board_post_args
           ?quantitative_evidence
           ~author
           ~source:keeper_source
           (assoc_override_string "author" author args)
       in
       Log.Keeper.debug "board_args: %s" (Yojson.Safe.to_string board_args);
       let result =
         Tool_board.handle_tool (Tool_name.Masc.to_string Tool_name.Masc.Board_post) board_args
       in
       let ok = result.success in
       let msg = Tool_result.message result in
       Log.Keeper.info
         "handle_tool result: ok=%b msg=%s"
         ok
         (String_util.utf8_safe ~max_bytes:203 ~suffix:"..." msg |> String_util.to_string);
       tool_result_or_error result)
  | Some Tool_name.Keeper.Board_list ->
    dispatch_board Tool_name.Masc.Board_list args
  | Some Tool_name.Keeper.Board_get ->
    dispatch_board Tool_name.Masc.Board_get args
  | Some Tool_name.Keeper.Board_comment ->
    dispatch_board
      Tool_name.Masc.Board_comment
      (assoc_override_string "author" meta.name args)
  | Some Tool_name.Keeper.Board_vote ->
    dispatch_board Tool_name.Masc.Board_vote (assoc_override_string "voter" meta.name args)
  | Some Tool_name.Keeper.Board_comment_vote ->
    dispatch_board
      Tool_name.Masc.Board_comment_vote
      (assoc_override_string "voter" meta.name args)
  | Some Tool_name.Keeper.Board_stats ->
    dispatch_board Tool_name.Masc.Board_stats args
  | Some Tool_name.Keeper.Board_search ->
    dispatch_board Tool_name.Masc.Board_search args
  | Some Tool_name.Keeper.Board_curation_read ->
    dispatch_board Tool_name.Masc.Board_curation_read args
  | Some Tool_name.Keeper.Board_delete ->
    dispatch_board Tool_name.Masc.Board_delete args
  | Some Tool_name.Keeper.Board_cleanup ->
    dispatch_board Tool_name.Masc.Board_cleanup args
  | Some _
  | None ->
    error_json ~fields:[ "tool", `String name ] "unknown_board_tool"
;;
