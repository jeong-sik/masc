module String_map = Map.Make (String)

let openai_max_length = 40
let anthropic_max_length = 64
let digest_hex_length = 16

let is_anthropic_safe_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
  | _ -> false
;;

let is_openai_passthrough_char c =
  let code = Char.code c in
  code >= 0x21 && code <= 0x7e
;;

let is_nonempty_within ~max_len ~pred id =
  let len = String.length id in
  len >= 1 && len <= max_len && String.for_all pred id
;;

let strip_trailing_underscores s =
  let rec last_non_underscore i =
    if i < 0 then -1
    else if s.[i] = '_' then last_non_underscore (i - 1)
    else i
  in
  let last = last_non_underscore (String.length s - 1) in
  if last < 0 then "" else String.sub s 0 (last + 1)
;;

let remap_with_digest ~max_len id =
  let full_hex = Agent_core_sha256.(to_hex (digest_string id)) in
  let digest = String.sub full_hex 0 digest_hex_length in
  let prefix_budget = max_len - 1 - digest_hex_length in
  let take_len = Int.min (String.length id) prefix_budget in
  let raw_prefix =
    String.init take_len (fun i ->
      let c = id.[i] in
      if is_anthropic_safe_char c then c else '_')
    |> strip_trailing_underscores
  in
  let prefix = if String.equal raw_prefix "" then "tc" else raw_prefix in
  prefix ^ "_" ^ digest
;;

let wire_id_for_openai id =
  if is_nonempty_within ~max_len:openai_max_length ~pred:is_openai_passthrough_char id
  then id
  else remap_with_digest ~max_len:openai_max_length id
;;

let wire_id_for_anthropic id =
  if is_nonempty_within ~max_len:anthropic_max_length ~pred:is_anthropic_safe_char id
  then id
  else remap_with_digest ~max_len:anthropic_max_length id
;;

let wire_id_for_provider_kind = function
  | Provider_kind.OpenAI_compat | Provider_kind.Glm -> wire_id_for_openai
  | Provider_kind.Anthropic | Provider_kind.Kimi -> wire_id_for_anthropic
  | Provider_kind.Gemini | Provider_kind.Ollama -> Fun.id
;;

type correlation =
  { map_fn : string -> string
  ; to_wire_map : string String_map.t
  ; to_canonical_map : string String_map.t
  }

let build_correlation map_fn canonical_ids =
  let to_wire_map, to_canonical_map =
    List.fold_left
      (fun (wire_acc, canon_acc) canon ->
         let wire = map_fn canon in
         let wire_acc = String_map.add canon wire wire_acc in
         let canon_acc =
           if String_map.mem wire canon_acc
           then canon_acc
           else String_map.add wire canon canon_acc
         in
         wire_acc, canon_acc)
      (String_map.empty, String_map.empty)
      canonical_ids
  in
  { map_fn; to_wire_map; to_canonical_map }
;;

let to_wire correlation canon =
  match String_map.find_opt canon correlation.to_wire_map with
  | Some wire -> wire
  | None -> correlation.map_fn canon
;;

let to_canonical correlation wire =
  match String_map.find_opt wire correlation.to_canonical_map with
  | Some canon -> canon
  | None -> wire
;;

[@@@coverage off]

let%test "wire_id_for_openai preserves short compliant ids and bounds long ones" =
  let short = "call_abc-123" in
  let legacy = "call_agent_core_0123456789abcdef0123456789abcdef_12345_0" in
  let legacy2 = "call_agent_core_0123456789abcdef0123456789abcdef_12345_1" in
  let mapped1 = wire_id_for_openai legacy in
  let mapped2 = wire_id_for_openai legacy2 in
  String.equal (wire_id_for_openai short) short
  && String.length mapped1 <= openai_max_length
  && String.length mapped2 <= openai_max_length
  && String.equal mapped1 (wire_id_for_openai legacy)
  && not (String.equal mapped1 mapped2)
;;

let%test "wire_id_for_anthropic sanitizes disallowed characters and preserves distinctness" =
  let valid = "toolu_01ABC-def" in
  let colon_id = "functions.bash:0" in
  let dot_id = "functions_bash.0" in
  let mapped_colon = wire_id_for_anthropic colon_id in
  let mapped_dot = wire_id_for_anthropic dot_id in
  String.equal (wire_id_for_anthropic valid) valid
  && String.length mapped_colon <= anthropic_max_length
  && String.for_all is_anthropic_safe_char mapped_colon
  && String.for_all is_anthropic_safe_char mapped_dot
  && not (String.equal mapped_colon mapped_dot)
;;

let%test "correlation round-trips mapped ids and leaves unknown ids verbatim" =
  let long_id = "call_agent_core_0123456789abcdef0123456789abcdef_999_42" in
  let corr = build_correlation wire_id_for_openai [ long_id; "short_1" ] in
  let wire = to_wire corr long_id in
  String.length wire <= openai_max_length
  && String.equal (to_canonical corr wire) long_id
  && String.equal (to_canonical corr "fresh_provider_id") "fresh_provider_id"
;;
