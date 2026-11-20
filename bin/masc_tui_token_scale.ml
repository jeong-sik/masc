(* How a byte figure is read in tokens, and where the ratio came from. *)

type own_ratio_refusal =
  | No_body
  | No_count
  | Turn_total_count
  | Cumulative_count
  | Unknown_scope

type basis =
  | This_turn of { wire_bytes : int; tokens : int }
  | Keeper_page of { samples : int; own : own_ratio_refusal }
  | Fleet_measured of { own : own_ratio_refusal option }

type t =
  { tokens_per_byte : float
  ; basis : basis
  }

(* Median of request_body_bytes / input_tokens over the 2,004 per-request
   turn records the fleet wrote on 2026-09-13..15 (p10 3.17, p90 3.89;
   glm-5.3-flash 3.34, deepseek-v4.1-flash 3.29, minimax-m3 3.90). The last
   resort when neither this turn nor its keeper's page carries a wire body
   beside a per-request count -- every official-client lane, whose client
   assembles its own wire. *)
let fleet_bytes_per_token = 3.39

let fleet_scale own =
  { tokens_per_byte = 1. /. fleet_bytes_per_token; basis = Fleet_measured { own } }

let fleet = fleet_scale None

(* A per-request count over the serialized body of the same record, or the
   reason the record cannot give one. A conversation-cumulative count puts
   the whole conversation over one request's bytes, and a count of unknown
   scope might, so neither divides. *)
let wire_ratio_of_record (turn : Turn_record.t) =
  match turn.usage.scope with
  | Runtime_usage_scope.Turn_total -> Error Turn_total_count
  | Runtime_usage_scope.Conversation_cumulative -> Error Cumulative_count
  | Runtime_usage_scope.Usage_scope_unavailable -> Error Unknown_scope
  | Runtime_usage_scope.Per_request -> (
      match turn.request_wire_observation, turn.usage.input_tokens with
      | Some { Turn_record.body_bytes; _ }, Some tokens
        when body_bytes > 0 && tokens > 0 -> Ok (body_bytes, tokens)
      | Some _, Some _ | Some _, None -> Error No_count
      | None, Some _ | None, None -> Error No_body)

let median sorted =
  let n = List.length sorted in
  if n = 0 then None
  else if n mod 2 = 1 then List.nth_opt sorted (n / 2)
  else
    match List.nth_opt sorted ((n / 2) - 1), List.nth_opt sorted (n / 2) with
    | Some low, Some high -> Some ((low +. high) /. 2.)
    | Some _, None | None, Some _ | None, None -> None

let of_turn ~(rows : Turn_record.t list) (turn : Turn_record.t) =
  match wire_ratio_of_record turn with
  | Ok (wire_bytes, tokens) ->
      { tokens_per_byte = float tokens /. float wire_bytes
      ; basis = This_turn { wire_bytes; tokens }
      }
  | Error own -> (
      let ratios =
        List.filter_map
          (fun row ->
            match wire_ratio_of_record row with
            | Ok (wire_bytes, tokens) -> Some (float tokens /. float wire_bytes)
            | Error (No_body | No_count | Turn_total_count | Cumulative_count | Unknown_scope) -> None)
          rows
        |> List.sort Float.compare
      in
      match median ratios with
      | Some tokens_per_byte ->
          { tokens_per_byte
          ; basis = Keeper_page { samples = List.length ratios; own }
          }
      | None -> fleet_scale (Some own))

let estimate scale bytes =
  int_of_float (Float.round (float bytes *. scale.tokens_per_byte))

let format_estimate scale bytes =
  "\xe2\x89\x88" ^ Masc_tui_context_inspector.format_tokens (estimate scale bytes)

let own_sentence ~ko = function
  | No_body ->
      if ko then "이 턴은 직렬화된 본문을 포함하지 않았습니다"
      else "this turn carried no serialized body"
  | No_count ->
      if ko then "이 턴은 입력 토큰 수를 보고하지 않았습니다"
      else "this turn reported no input count"
  | Turn_total_count ->
      if ko then "이 수치는 여러 요청을 합산한 클라이언트 턴 총합이라 나눌 수 없습니다"
      else "this count is the client turn's total over requests, so it is not divided"
  | Cumulative_count ->
      if ko then "이 수치는 전체 대화 누적값이라 단일 요청 바이트로 나눌 수 없습니다"
      else "this turn's count covers the whole conversation, which one request's \
            bytes cannot divide"
  | Unknown_scope ->
      if ko then "이 수치는 집계 범위가 불명확해 나눌 수 없습니다"
      else "this turn's count is of unknown scope, so it is not divided"

let turns ~ko n =
  if ko then Printf.sprintf "%d개 턴" n
  else if n = 1 then "1 turn"
  else Printf.sprintf "%d turns" n

let note ?(ko = false) scale =
  match scale.basis with
  | This_turn { wire_bytes; tokens } ->
      if ko then
        Printf.sprintf
          "\xe2\x89\x88 tok은 이 턴의 공급자 집계 기준(전송 본문 %s당 %s 토큰, 토큰당 %.2f바이트)으로 환산한 추정치이며 실제 집계가 아닙니다."
          (Masc_tui_context_inspector.format_bytes wire_bytes)
          (Masc_tui_context_inspector.format_tokens tokens)
          (1. /. scale.tokens_per_byte)
      else
        Printf.sprintf
          "\xe2\x89\x88 tok is bytes at this turn's %.2f bytes per \
           provider-counted token (%s tokens over %s on the wire): an \
           estimate, not a count."
          (1. /. scale.tokens_per_byte)
          (Masc_tui_context_inspector.format_tokens tokens)
          (Masc_tui_context_inspector.format_bytes wire_bytes)
  | Keeper_page { samples; own } ->
      if ko then
        Printf.sprintf
          "\xe2\x89\x88 tok은 이 페이지에서 전송 본문과 요청별 집계를 모두 기록한 %s의 중앙값(토큰당 %.2f바이트) 기준 환산치입니다(%s). 실제 집계가 아닌 추정치입니다."
          (turns ~ko samples) (1. /. scale.tokens_per_byte) (own_sentence ~ko own)
      else
        Printf.sprintf
          "\xe2\x89\x88 tok is bytes at %.2f bytes per provider-counted token, \
           the median of %s on this page that carried a wire body beside a \
           per-request count; %s. An estimate, not a count."
          (1. /. scale.tokens_per_byte)
          (turns ~ko samples) (own_sentence ~ko own)
  | Fleet_measured { own } ->
      if ko then
        Printf.sprintf
          "\xe2\x89\x88 tok은 전체 플릿 중앙값(2026-09-13..15 측정, 토큰당 %.2f바이트) 기준 환산치입니다(%s). 실제 집계가 아닌 추정치입니다."
          fleet_bytes_per_token
          (match own with
           | Some own ->
               own_sentence ~ko own
               ^ ", 이 페이지에 전송 본문과 요청별 집계를 함께 기록한 턴이 없습니다"
           | None -> "비율을 구할 턴 기록이 이 화면에 없습니다")
      else
        Printf.sprintf
          "\xe2\x89\x88 tok is bytes at %.2f bytes per provider-counted token, \
           the fleet median measured 2026-09-13..15; %s. An estimate, not a \
           count."
          fleet_bytes_per_token
          (match own with
           | Some own ->
               own_sentence ~ko own
               ^ ", and no turn on this page carried a wire body beside a \
                  per-request count"
           | None -> "this screen has no turn record to take a ratio from")
