(* Fusion — 심판 LLM-facing JSON → judge_synthesis (구현).
   계약/문서: fusion_judge_parse.mli, docs/rfc/RFC-0252 §7.2 *)

let ( let* ) = Result.bind

let wire_field_consensus = "consensus"
let wire_field_consensus_text = "text"
let wire_field_supporting_models = "supporting_models"
let wire_field_contradictions = "contradictions"
let wire_field_topic = "topic"
let wire_field_positions = "positions"
let wire_field_model = "model"
let wire_field_stance = "stance"
let wire_field_evidence = "evidence"
let wire_field_partial_coverage = "partial_coverage"
let wire_field_addressed_by = "addressed_by"
let wire_field_missing = "missing"
let wire_field_unique_insights = "unique_insights"
let wire_field_blind_spots = "blind_spots"
let wire_field_resolved_answer = "resolved_answer"
let wire_field_decision = "decision"
let wire_field_decision_kind = "kind"
let wire_field_answer = "answer"
let wire_decision_answer = "answer"
let wire_decision_recommend = "recommend"
let wire_decision_insufficient = "insufficient"
let wire_field_recommend_action = "action"
let wire_field_recommend_rationale = "rationale"

(* One typed field definition supplies both the JSON schema and its decoder.
   A present malformed array element fails the whole synthesis; no element is
   silently omitted while constructing a judge result. *)

type 'a codec =
  { schema : Yojson.Safe.t
  ; decode : string -> Yojson.Safe.t -> ('a, string) result
  }

type 'a field =
  { key : string
  ; value : 'a codec
  ; required : bool
  ; default : 'a option
  }

type packed_field = Field : 'a field -> packed_field

let required key value = { key; value; required = true; default = None }
let optional ?default key value = { key; value; required = false; default }

let string_codec =
  { schema = `Assoc [ "type", `String "string" ]
  ; decode =
      (fun path -> function
        | `String value -> Ok value
        | _ -> Error (path ^ ": expected string"))
  }

(* Match [String.trim]'s whitespace set in both the schema and decoder.
   Preserve the original content once it contains an actual answer. *)
let nonblank_string_codec =
  { schema =
      `Assoc
        [ "type", `String "string"
        ; "pattern", `String "[^ \t\n\r\012]"
        ]
  ; decode =
      (fun path json ->
        let* value = string_codec.decode path json in
        if String.equal (String.trim value) ""
        then Error (path ^ ": expected nonblank string")
        else Ok value)
  }

let enum_codec values =
  { schema =
      `Assoc
        [ "type", `String "string"
        ; "enum", `List (List.map (fun value -> `String value) values)
        ]
  ; decode =
      (fun path json ->
        let* value = string_codec.decode path json in
        if List.mem value values then Ok value
        else Error (path ^ ": unknown value " ^ value))
  }

let list_codec item =
  let rec collect path index acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest ->
      let* parsed =
        item.decode (Printf.sprintf "%s[%d]" path index) value
      in
      collect path (index + 1) (parsed :: acc) rest
  in
  { schema = `Assoc [ "type", `String "array"; "items", item.schema ]
  ; decode =
      (fun path -> function
        | `List values -> collect path 0 [] values
        | _ -> Error (path ^ ": expected array"))
  }

let object_codec fields construct =
  let properties =
    List.map (fun (Field field) -> field.key, field.value.schema) fields
  in
  let required_fields =
    fields
    |> List.filter (fun (Field field) -> field.required)
    |> List.map (fun (Field field) -> `String field.key)
  in
  let allowed = List.map fst properties in
  let rec check_keys path = function
    | [] -> Ok ()
    | (key, _) :: rest ->
      if List.mem key allowed then check_keys path rest
      else Error (path ^ "." ^ key ^ ": unknown field")
  in
  { schema =
      `Assoc
        [ "type", `String "object"
        ; "additionalProperties", `Bool false
        ; "properties", `Assoc properties
        ; "required", `List required_fields
        ]
  ; decode =
      (fun path -> function
        | `Assoc kvs ->
          let* () = check_keys path kvs in
          construct path kvs
        | _ -> Error (path ^ ": expected object"))
  }

let get path kvs field =
  let location = path ^ "." ^ field.key in
  match List.assoc_opt field.key kvs with
  | Some value -> field.value.decode location value
  | None ->
    (match field.default with
     | Some value -> Ok value
     | None -> Error (location ^ ": missing"))

let get_optional path kvs field =
  match List.assoc_opt field.key kvs with
  | None -> Ok None
  | Some value ->
    let* value = field.value.decode (path ^ "." ^ field.key) value in
    Ok (Some value)

let string_array_codec = list_codec string_codec

let claim_text = required wire_field_consensus_text string_codec
let claim_models = optional ~default:[] wire_field_supporting_models string_array_codec

let claim_codec =
  object_codec [ Field claim_text; Field claim_models ] (fun path kvs ->
    let* text = get path kvs claim_text in
    let* supporting_models = get path kvs claim_models in
    Ok { Fusion_types.text; supporting_models })

let position_model = required wire_field_model string_codec
let position_stance = required wire_field_stance string_codec

let position_codec =
  object_codec [ Field position_model; Field position_stance ] (fun path kvs ->
    let* model = get path kvs position_model in
    let* stance = get path kvs position_stance in
    Ok (model, stance))

let contradiction_topic = required wire_field_topic string_codec
let contradiction_positions =
  optional ~default:[] wire_field_positions (list_codec position_codec)
let contradiction_evidence =
  optional ~default:[] wire_field_evidence string_array_codec

let contradiction_codec =
  object_codec
    [ Field contradiction_topic
    ; Field contradiction_positions
    ; Field contradiction_evidence
    ]
    (fun path kvs ->
      let* topic = get path kvs contradiction_topic in
      let* positions = get path kvs contradiction_positions in
      let* evidence = get path kvs contradiction_evidence in
      Ok { Fusion_types.topic; positions; evidence })

let coverage_topic = required wire_field_topic string_codec
let coverage_models =
  optional ~default:[] wire_field_addressed_by string_array_codec
let coverage_missing = optional wire_field_missing string_codec

let coverage_codec =
  object_codec
    [ Field coverage_topic; Field coverage_models; Field coverage_missing ]
    (fun path kvs ->
      let* gap_topic = get path kvs coverage_topic in
      let* addressed_by = get path kvs coverage_models in
      let* missing = get_optional path kvs coverage_missing in
      Ok { Fusion_types.gap_topic; addressed_by; missing })

let insight_text = required wire_field_consensus_text string_codec
let insight_model = required wire_field_model string_codec

let insight_codec =
  object_codec [ Field insight_text; Field insight_model ] (fun path kvs ->
    let* insight_text = get path kvs insight_text in
    let* from_model = get path kvs insight_model in
    Ok { Fusion_types.insight_text; from_model })

let decision_case kind fields construct =
  let tag = required wire_field_decision_kind (enum_codec [ kind ]) in
  object_codec (Field tag :: fields) (fun path kvs ->
    let* _ = get path kvs tag in
    construct path kvs)

let decision_answer = required wire_field_answer nonblank_string_codec
let decision_action = required wire_field_recommend_action nonblank_string_codec
let decision_rationale = required wire_field_recommend_rationale nonblank_string_codec
let decision_missing =
  optional ~default:[] wire_field_missing string_array_codec

let decision_answer_codec =
  decision_case wire_decision_answer [ Field decision_answer ] (fun path kvs ->
    let* answer = get path kvs decision_answer in
    Ok (Fusion_types.Answer answer))

let decision_recommend_codec =
  decision_case wire_decision_recommend
    [ Field decision_action; Field decision_rationale ]
    (fun path kvs ->
      let* action = get path kvs decision_action in
      let* rationale = get path kvs decision_rationale in
      Ok (Fusion_types.Recommend { action; rationale }))

let decision_insufficient_codec =
  decision_case wire_decision_insufficient [ Field decision_missing ]
    (fun path kvs ->
      let* missing_for_decision = get path kvs decision_missing in
      Ok (Fusion_types.Insufficient { missing_for_decision }))

let consensus = optional ~default:[] wire_field_consensus (list_codec claim_codec)
let contradictions =
  optional ~default:[] wire_field_contradictions (list_codec contradiction_codec)
let partial_coverage =
  optional ~default:[] wire_field_partial_coverage (list_codec coverage_codec)
let unique_insights =
  optional ~default:[] wire_field_unique_insights (list_codec insight_codec)
let blind_spots = optional ~default:[] wire_field_blind_spots string_array_codec
let synthesis_case ~resolved_value ~decision_value =
  let resolved_answer = required wire_field_resolved_answer resolved_value in
  let decision = required wire_field_decision decision_value in
  object_codec
    [ Field consensus
    ; Field contradictions
    ; Field partial_coverage
    ; Field unique_insights
    ; Field blind_spots
    ; Field resolved_answer
    ; Field decision
    ]
    (fun path kvs ->
      let* consensus = get path kvs consensus in
      let* contradictions = get path kvs contradictions in
      let* partial_coverage = get path kvs partial_coverage in
      let* unique_insights = get path kvs unique_insights in
      let* blind_spots = get path kvs blind_spots in
      let* resolved_answer = get path kvs resolved_answer in
      let* decision = get path kvs decision in
      Ok
        { Fusion_types.consensus
        ; contradictions
        ; partial_coverage
        ; unique_insights
        ; blind_spots
        ; resolved_answer
        ; decision
        })

let synthesis_codec =
  let cases =
    [ wire_decision_answer,
      synthesis_case ~resolved_value:nonblank_string_codec
        ~decision_value:decision_answer_codec
    ; wire_decision_recommend,
      synthesis_case ~resolved_value:nonblank_string_codec
        ~decision_value:decision_recommend_codec
    ; wire_decision_insufficient,
      synthesis_case ~resolved_value:string_codec
        ~decision_value:decision_insufficient_codec
    ]
  in
  { schema =
      `Assoc [ "oneOf", `List (List.map (fun (_, codec) -> codec.schema) cases) ]
  ; decode =
      (fun path -> function
        | `Assoc kvs as json ->
          let decision_path = path ^ "." ^ wire_field_decision in
          let* fields =
            match List.assoc_opt wire_field_decision kvs with
            | Some (`Assoc fields) -> Ok fields
            | Some _ -> Error (decision_path ^ ": expected object")
            | None -> Error (decision_path ^ ": missing")
          in
          let kind_path = decision_path ^ "." ^ wire_field_decision_kind in
          let* kind =
            match List.assoc_opt wire_field_decision_kind fields with
            | Some value -> string_codec.decode kind_path value
            | None -> Error (kind_path ^ ": missing")
          in
          (match List.assoc_opt kind cases with
           | Some codec -> codec.decode path json
           | None -> Error (kind_path ^ ": unknown value " ^ kind))
        | _ -> Error (path ^ ": expected object"))
  }

let output_schema = synthesis_codec.schema

let of_json (json : Yojson.Safe.t) : (Fusion_types.judge_synthesis, string) result =
  synthesis_codec.decode "judge" json

(* 코드펜스 구분자 — 마커와 그 길이를 한 곳에 묶어 drift를 막는다. *)
let fence = "```"
let fence_len = String.length fence

(* ```json ... ``` 또는 ``` ... ``` 코드펜스를 벗긴다. *)
let strip_fences (s : string) : string =
  let s = String.trim s in
  if String.length s >= fence_len && String.equal (String.sub s 0 fence_len) fence then
    match String.index_opt s '\n' with
    | Some nl ->
      let body = String.trim (String.sub s (nl + 1) (String.length s - nl - 1)) in
      if String.length body >= fence_len
         && String.equal
              (String.sub body (String.length body - fence_len) fence_len)
              fence
      then String.trim (String.sub body 0 (String.length body - fence_len))
      else body
    | None -> s
  else s

let of_string (s : string) : (Fusion_types.judge_synthesis, string) result =
  let s = strip_fences s in
  match Yojson.Safe.from_string s with
  | json -> of_json json
  | exception Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
