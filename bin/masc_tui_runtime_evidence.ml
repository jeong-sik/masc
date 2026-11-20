(* A moment the zone can break down, checked when read so that drawing it
   cannot fail later. *)
type timestamp = { epoch : float }
type successful_outcome = Completed | Checkpoint | Input_required
type recent = { timestamp : timestamp; outcome : successful_outcome; input : int option; output : int option }
type stats = {
  id : string; samples : int; successes : int; errors : int;
  usage_samples : int; telemetry_samples : int;
  cached : (int * int * int) option; cost : float option; recent : recent list;
}
type specification = {
  id : string; catalog : int option; output : int option;
  model : int option; provider : int option; binding : int option;
}
type cost_read =
  | Cost_store_unavailable
  | Cost_store_available of { malformed : int; violations : int; conflicts : int }
type history =
  | Decision_directory_unavailable | Decision_files_unreadable of int
  | Decision_rows_invalid of { malformed : int; schema_invalid : int }
  | Observed of {
  window : int; generated_at : timestamp; unattributed : int;
  cost_read : cost_read; runtimes : stats list;
}
type t = { history : history; specifications : specification list }
open Result.Syntax
let field name = function `Assoc fields -> List.assoc_opt name fields | _ -> None
let required name json = match field name json with
  | Some value -> Ok value | None -> Error ("runtime evidence missing " ^ name)
let text = function `String value when value <> "" -> Ok value | _ -> Error "runtime evidence has an invalid identity"
let nat = function `Int n when n >= 0 -> Ok n | _ -> Error "runtime evidence has an invalid count"
let number = function
  | `Float n when Float.is_finite n && n >= 0. -> Ok n
  | `Int n when n >= 0 -> Ok (float_of_int n)
  | _ -> Error "runtime evidence has an invalid measurement"
let time value =
  let* epoch = number value in
  match Unix.localtime epoch with
  | _ -> Ok { epoch }
  | exception (Unix.Unix_error _ | Invalid_argument _) ->
      Error "runtime evidence has an unrenderable timestamp"
let successful_outcome = function
  | `String "success" -> Ok Completed
  | `String "checkpoint" -> Ok Checkpoint
  | `String "input_required" -> Ok Input_required
  | _ -> Error "runtime recent non-error turn has an unrecognized outcome"
let outcome_label ~ko = function
  | Completed -> if ko then "완료" else "completed"
  | Checkpoint -> if ko then "체크포인트" else "checkpoint"
  | Input_required -> if ko then "입력 필요" else "input required"
let optional parse = function `Null -> Ok None | value -> Result.map Option.some (parse value)
let member parse name json = let* value = required name json in parse value
let rec rows parse = function
  | [] -> Ok []
  | value :: rest -> let* value = parse value in let* rest = rows parse rest in Ok (value :: rest)
let list parse = function `List values -> rows parse values | _ -> Error "runtime evidence has an invalid list"
let unique ids = List.length ids = List.length (List.sort_uniq String.compare ids)
let recent json =
  let* timestamp = member time "ts_unix" json in
  let* outcome = member successful_outcome "outcome" json in
  let* input = member (optional nat) "input_tokens" json in
  let* output = member (optional nat) "output_tokens" json in
  Ok {timestamp; outcome; input; output}
let cached = function
  | `Null -> Ok None
  | json ->
    let* input = member nat "input_tokens" json in
    let* read = member nat "cache_read_tokens" json in
    let* samples = member nat "sample_count" json in
    if input > 0 && read <= input && samples > 0 then Ok (Some (input, read, samples))
    else Error "runtime cache evidence has an invalid denominator"
let stats json =
  let* id = member text "runtime_id" json in
  let* samples = member nat "entry_count" json in
  let* successes = member nat "success_count" json in
  let* errors = member nat "error_count" json in
  let* usage_samples = member nat "usage_sample_count" json in
  let* telemetry_samples = member nat "telemetry_sample_count" json in
  let* cached = member cached "cached_input" json in
  let* cost = member (optional number) "total_cost_usd" json in
  let* recent = member (list recent) "recent_entries" json in
  if samples <> successes + errors || usage_samples > successes || telemetry_samples > successes
     || (match cached with Some (_, _, count) -> count > successes | None -> false)
     || List.length recent > successes then Error "runtime evidence counts disagree"
  else Ok {id; samples; successes; errors; usage_samples; telemetry_samples; cached; cost;
           recent = List.sort (fun a b -> Float.compare b.timestamp.epoch a.timestamp.epoch) recent}
let specification json =
  let* id = member text "runtime_id" json in
  let* catalog = member (optional nat) "catalog_context" json in
  let* output = member (optional nat) "catalog_max_output" json in
  let* model = member (optional nat) "model_context" json in
  let* provider = member (optional nat) "provider_context" json in
  let* binding = member (optional nat) "binding_context" json in
  Ok {id; catalog; output; model; provider; binding}
let history json =
  let* state = member text "state" json in
  match state with
  | "unavailable" ->
    let* diagnostic = required "decision_read" json in
    let* cause = member text "cause" diagnostic in
    (match cause with
     | "directory_unavailable" -> Ok Decision_directory_unavailable
     | "files_unreadable" ->
       let* count = member nat "unreadable_files" diagnostic in
       if count > 0 then Ok (Decision_files_unreadable count)
       else Error "runtime history has an invalid unreadable file count"
     | "rows_invalid" ->
       let* malformed = member nat "malformed_rows" diagnostic in
       let* schema_invalid = member nat "schema_violation_rows" diagnostic in
       if malformed > 0 || schema_invalid > 0 then Ok (Decision_rows_invalid {malformed; schema_invalid})
       else Error "runtime history has an invalid dropped row count"
     | _ -> Error "runtime history has an unrecognized decision read failure")
  | "ready" ->
    let* window = member nat "window_minutes" json in
    let* unattributed = member nat "unattributed_entries" json in
    let* runtimes = member (list stats) "runtimes" json in
    let* generated_at = member time "observed_at" json in
    let* store = required "cost_read" json in
    let* store_state = member text "state" store in
    let* cost_read = match store_state with
      | "unavailable" -> Ok Cost_store_unavailable
      | "available" ->
        let* malformed = member nat "malformed_rows" store in
        let* violations = member nat "schema_violation_rows" store in
        let* conflicts = member nat "identity_conflict_rows" store in
        Ok (Cost_store_available { malformed; violations; conflicts })
      | _ -> Error "runtime evidence has an unrecognized cost read state" in
    if unique (List.map (fun (row : stats) -> row.id) runtimes) then
      Ok (Observed {window; generated_at; unattributed; cost_read; runtimes})
    else Error "runtime evidence repeats a runtime identity"
  | _ -> Error "runtime history state is unavailable"
let decode json =
  let* history = member history "history" json in
  let* specifications = member (list specification) "specifications" json in
  if unique (List.map (fun (row : specification) -> row.id) specifications)
  then Ok {history; specifications}
  else Error "runtime specifications repeat an identity"
let timestamp ts =
  Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_minute ~now:(Unix.gettimeofday ()) ts.epoch
let count ~ko = function
  | Some n -> string_of_int n
  | None -> if ko then "미보고" else "not reported"
let store_note_text ~ko = function
  | Cost_store_unavailable ->
      if ko then "비용 저장소 사용 불가 · 의사결정 기록만 표시"
      else "cost store unavailable; decision records only"
  | Cost_store_available { malformed; violations; conflicts } ->
      if ko then
        Printf.sprintf "형식 오류 %d · 스키마 위반 %d · 충돌 %d건의 비용 행 제외"
          malformed violations conflicts
      else
        Printf.sprintf "%d malformed, %d schema, %d conflicting cost rows excluded"
          malformed violations conflicts
let lines ?(ko = false) t ~runtime_id =
  let say korean english = if ko then korean else english in
  let specifications = match List.find_opt (fun (row : specification) -> row.id = runtime_id) t.specifications with
    | None ->
        [ say "원본 컨텍스트" "Original context"
        , say "사용 불가 · 이 런타임의 사양 정보 없음"
            "unavailable; no specification reading for this runtime" ]
    | Some row -> [
        say "사양" "Specification",
        say "현재 설정 기준 · 과거 호출은 이전 설정을 사용했을 수 있음"
          "current configuration; historical calls may use earlier settings";
        say "카탈로그 컨텍스트" "Catalog context", count ~ko row.catalog;
        say "카탈로그 최대 출력" "Catalog max output", count ~ko row.output;
        say "선언된 컨텍스트" "Declared context",
        Printf.sprintf
          (if ko then "모델 %s / 제공자 %s / 바인딩 %s 토큰"
           else "model %s / provider %s / binding %s tokens")
          (count ~ko row.model) (count ~ko row.provider) (count ~ko row.binding)] in
  let history = match t.history with
    | Decision_directory_unavailable ->
        [ say "런타임 이력" "Runtime history"
        , say "사용 불가 · 의사결정 로그 디렉터리를 읽을 수 없음"
            "unavailable; decision log directory could not be read" ]
    | Decision_files_unreadable count ->
        [ say "런타임 이력" "Runtime history"
        , Printf.sprintf
            (if ko then "불완전 · 의사결정 로그 파일 %d개를 읽을 수 없어 런타임 합계 산출 불가"
             else "incomplete; %d decision log files could not be read; runtime totals unavailable")
            count ]
    | Decision_rows_invalid { malformed; schema_invalid } ->
        [ say "런타임 이력" "Runtime history"
        , Printf.sprintf
            (if ko then "불완전 · 형식 오류 %d건, 스키마 위반 %d건으로 런타임 합계 산출 불가"
             else "incomplete; %d malformed and %d schema-invalid decision rows; runtime totals unavailable")
            malformed schema_invalid ]
    | Observed observed ->
      [ say "이력 기간" "History window",
        Printf.sprintf
          (if ko then "최근 %d분 · %s 조회" else "last %d min, read %s")
          observed.window (timestamp observed.generated_at);
        say "귀속 기준" "Attribution",
        Printf.sprintf
          (if ko then "실행된 런타임 ID 기준 · 응답자 없는 기록 %d건 제외"
           else "executed runtime ID; %d records without an answerer excluded")
          observed.unattributed;
        say "저장소 범위" "Store coverage", store_note_text ~ko observed.cost_read ]
      @ (match List.find_opt (fun (row : stats) -> row.id = runtime_id) observed.runtimes with
        | None ->
            [ say "런타임 표본" "Runtime samples",
              say "이 기간에 귀속된 표본 없음" "none attributed in this window";
              say "최근 비오류 턴" "Last non-error turn",
              say "이 기간에 관측 없음" "not observed in this window";
              say "캐시 적중" "Cache hit", say "미보고" "not reported" ]
        | Some row -> [
            say "런타임 표본" "Runtime samples",
            Printf.sprintf
              (if ko then "기록 %d / 비오류 %d / 오류 %d"
               else "%d recorded / %d non-error / %d errors")
              row.samples row.successes row.errors;
            say "표본 범위" "Sample coverage",
            Printf.sprintf
              (if ko then "사용량 %d/%d 비오류 · 텔레메트리 %d/%d 비오류"
               else "usage %d/%d non-error; telemetry %d/%d non-error")
              row.usage_samples row.successes row.telemetry_samples row.successes;
            say "최근 비오류 턴" "Last non-error turn",
            (match row.recent with
             | first :: _ -> timestamp first.timestamp ^ " · " ^ outcome_label ~ko first.outcome
             | [] -> say "이 기간에 관측 없음" "not observed in this window");
            say "캐시 적중" "Cache hit",
            (match row.cached with
             | None -> say "미보고 · 유효한 입력/캐시 쌍 없음" "not reported; no valid input/cache pairs"
             | Some (input, read, samples) ->
                 Printf.sprintf
                   (if ko then "입력 토큰 %.1f%% (%d/%d) · 비오류 표본 %d/%d"
                    else "%.1f%% input tokens (%d/%d); %d/%d non-error samples")
                   (100. *. float_of_int read /. float_of_int input) read input samples row.successes);
            say "기록된 비용" "Recorded cost",
            (match row.cost with
             | None -> say "미보고" "not reported"
             | Some cost ->
                 Printf.sprintf
                   (if ko then "$%.4f (기록된 표본 기준)" else "$%.4f (recorded samples)")
                   cost)]
          @ List.map (fun row ->
              say "최근 비오류 턴 기록" "Recent non-error turn",
              Printf.sprintf
                (if ko then "%s · %s · 입력 %s / 출력 %s 토큰"
                 else "%s · %s · input %s / output %s tokens")
                (timestamp row.timestamp) (outcome_label ~ko row.outcome)
                (count ~ko row.input) (count ~ko row.output)) row.recent) in
  specifications @ history
