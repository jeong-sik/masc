(* The NEXT REQUEST band of the context inspector: the turn's own composition
   run forward by the server (the carried range from the pair's front over
   the durable history), drawn in tokens at the tab's scale.
   Under the figures, the same parts in the order the request carries them. *)

module Inspector = Masc_tui_context_inspector

let signed_tokens n =
  if n < 0 then "\xe2\x88\x92" ^ Inspector.format_tokens (-n)
  else Inspector.format_tokens n
;;

let rec origin_sentence ~ko ~safe_detail = function
  | Inspector.Carried_from_ledger ->
      if ko then "이 런타임의 원장에서 시작 위치를 가져옴"
      else "front from this runtime's ledger"
  | Inspector.Carried_from_turn_record { turn } ->
      if ko then Printf.sprintf "턴 #%d 기록에서 시작 위치를 가져옴 · 서버 시작 이후 집계 없음" turn
      else Printf.sprintf "front from turn #%d's record; nothing counted since the server started" turn
  | Inspector.Carried_turn_start_after_refusal ->
      if ko then "범위가 거절되어 턴 경계로 시작 위치를 옮김"
      else "the range was refused: front moved to the turn boundary"
  | Inspector.Carried_this_turn_start_after_refusal ->
      if ko then "턴 경계 범위도 거절되어 이번 턴 시작 위치로 옮김"
      else "the range from the turn boundary was refused too: front moved to where this turn began"
  | Inspector.Carried_turn_start_at_max_context ->
      if ko then "직전 요청과 최대 턴 증가량 합이 max-context를 초과해 턴 경계로 옮김"
      else "the last request plus the largest growth of one turn passed max-context: front moved to the turn boundary"
  | Inspector.Carried_librarian_point_at_max_context ->
      if ko then "직전 요청과 최대 턴 증가량 합이 max-context를 초과해 사서가 읽은 끝 지점으로 옮김"
      else "the last request plus the largest growth of one turn passed max-context: front moved to the end of what the Librarian read"
  | Inspector.Carried_past_librarian_point { librarian_end_atom; front } ->
      if ko then
        Printf.sprintf "사서 기준점은 아톰 %d이며, 공급자가 마지막으로 수락한 위치(%s)부터 포함"
          librarian_end_atom (origin_sentence ~ko ~safe_detail front)
      else
        Printf.sprintf
          "the Librarian point is atom %d; the range opens where the provider last accepted it (%s)"
          librarian_end_atom (origin_sentence ~ko ~safe_detail front)
  | Inspector.Carried_turn_start { end_atom } ->
      (* The fact line ahead of this sentence already says which atom the
         range opens on ([first_atom]); [end_atom] is the completed boundary
         itself, which sits past the newest atom when the boundary record
         is in an older numbering. *)
      if ko then
        Printf.sprintf "기준 위치가 없어 이번 턴 아톰만 포함 (직전 완료 턴 종료: 아톰 %d)" end_atom
      else
        Printf.sprintf
          "no front to start from: this turn's own atoms; the last completed turn ended at atom %d"
          end_atom
  | Inspector.Carried_turn_start_unknown { reason } ->
      if ko then
        Printf.sprintf "기준 위치와 이번 턴 시작점을 읽지 못해 최신 아톰만 포함 (%s)"
          (safe_detail reason)
      else
        Printf.sprintf
          "no front, and where this turn began could not be read: the newest atom alone (%s)"
          (safe_detail reason)
  | Inspector.Carried_covered { end_atom } ->
      if ko then
        Printf.sprintf "메모리가 아톰 %d 이전 내용을 보관하고 있어 다시 전송하지 않음" end_atom
      else
        Printf.sprintf "Memory holds the atoms before %d, so they are not sent again" end_atom
;;

(* A moment in the operator's zone, the date added once the day differs:
   the band used to draw a UTC clock with the day dropped, so a rest ending
   tomorrow read as one ending today. *)
let clock epoch =
  Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_second ~now:(Unix.gettimeofday ()) epoch
;;

let ordinal ~ko = function
  | 0 -> if ko then "1번째" else "first"
  | 1 -> if ko then "2번째" else "second"
  | 2 -> if ko then "3번째" else "third"
  | n ->
      let n = n + 1 in
      if ko then Printf.sprintf "%d번째" n
      else
        let suffix =
          if n mod 100 >= 11 && n mod 100 <= 13 then "th"
          else (match n mod 10 with 1 -> "st" | 2 -> "nd" | 3 -> "rd" | _ -> "th")
        in
        Printf.sprintf "%d%s" n suffix
;;

(* Why the candidate walks where it does: the declared order, with a resting
   path moved behind its siblings and named with its release. *)
let walk_sentence ~ko ~safe (walk : Inspector.forecast_walk)
    (candidate : Inspector.forecast_candidate) =
  let why =
    match candidate.place.declared_at with
    | Some 0 -> if ko then "선언된 첫 번째 후보" else "the declared head"
    | Some n ->
        if ko then Printf.sprintf "레인 %s에서 %s로 선언됨" (safe walk.lane_id) (ordinal ~ko n)
        else Printf.sprintf "declared %s on lane %s" (ordinal ~ko n) (safe walk.lane_id)
    | None ->
        if ko then Printf.sprintf "레인 %s에 미선언" (safe walk.lane_id)
        else Printf.sprintf "not declared on lane %s" (safe walk.lane_id)
  in
  let rest =
    match candidate.place.rest with
    | Inspector.Rest_serving -> ""
    | Inspector.Rest_resting { release_at } ->
        if ko then Printf.sprintf " · %s까지 휴식 중" (clock release_at)
        else Printf.sprintf "; resting until %s" (clock release_at)
  in
  if ko then
    Printf.sprintf "실행 순서 %s: %s%s." (ordinal ~ko candidate.place.walks_at) why rest
  else
    Printf.sprintf "Walks %s: %s%s." (ordinal ~ko candidate.place.walks_at) why rest
;;

let pad_label ~cells text =
  let w = Masc_tui_message_layout.display_width text in
  if w >= cells then text else text ^ String.make (cells - w) ' '
;;

let candidate_lines ~ko ~runtime_details ~prose ~fact ~detail ~safe ~safe_detail ~scale ~(walk : Inspector.forecast_walk)
    (candidate : Inspector.forecast_candidate) =
  let say korean english = if ko then korean else english in
  let tokens_of_bytes = Masc_tui_token_scale.estimate scale in
  let approx bytes = "\xe2\x89\x88" ^ signed_tokens (tokens_of_bytes bytes) in
  let head =
    match candidate.lane with
    | Inspector.Lane_not_applicable reason ->
        fact (safe candidate.runtime_id) @ detail ~dim:true (safe_detail reason ^ ".")
    | Inspector.Lane_agent_core -> fact (safe candidate.runtime_id)
  in
  (* The pinned figure names its lane only when it is not this one. *)
  let pinned_provenance (parts : Inspector.forecast_parts) =
    if String.equal parts.pinned_measured_on_runtime candidate.runtime_id
    then Printf.sprintf (if ko then "(턴 #%d)" else "(turn #%d)") parts.pinned_measured_on_turn
    else if ko then
      Printf.sprintf "(%s 턴 #%d)"
        (safe parts.pinned_measured_on_runtime) parts.pinned_measured_on_turn
    else
      Printf.sprintf "(turn #%d on %s)"
        parts.pinned_measured_on_turn (safe parts.pinned_measured_on_runtime)
  in
  let parts_line =
    match candidate.parts with
    | Error reason ->
        detail ~dim:true (say "고정 부분 확인 불가: " "Fixed parts unknown: " ^ safe_detail reason ^ ".")
    | Ok parts ->
        fact
          (Printf.sprintf
             (if ko then "고정 부분 %s tok (턴 #%d) + 고정 핀 %s tok %s"
              else "fixed parts %s tok (turn #%d) + pinned %s tok %s")
             (approx parts.reserved_bytes) parts.reserved_measured_on_turn
             (approx parts.pinned_bytes) (pinned_provenance parts))
  in
  let carried_lines =
    match candidate.lane, candidate.carried with
    | Inspector.Lane_not_applicable _, (Some _ | None) -> []
    | Inspector.Lane_agent_core, None ->
        prose
          (say "시작 기준 위치가 없고 고정 부분 크기도 알 수 없어 전송 범위를 계산하지 못했습니다."
             "No front to start from, and the cap fit charges the fixed parts, which are \
              unknown: no range was computed.")
    | Inspector.Lane_agent_core, Some carried ->
        let history =
          if ko then
            Printf.sprintf
              "대화 이력 미리보기: 원본 아톰 %d개 중 %d개 전송 (#%d부터, 추정 %s tok). %s."
              candidate.history_atoms carried.kept_atoms carried.first_atom
              (approx carried.transmitted_bytes) (origin_sentence ~ko ~safe_detail carried.origin)
          else
            Printf.sprintf
              "History preview: send %d of %d original atoms, starting at #%d (%s tok estimated). %s."
              carried.kept_atoms candidate.history_atoms carried.first_atom
              (approx carried.transmitted_bytes) (origin_sentence ~ko ~safe_detail carried.origin)
        in
        (match carried.origin with
         | Inspector.Carried_turn_start_unknown _ -> detail ~dim:false history
         | Inspector.Carried_from_ledger | Inspector.Carried_from_turn_record _
         | Inspector.Carried_turn_start_after_refusal
         | Inspector.Carried_this_turn_start_after_refusal
         | Inspector.Carried_turn_start_at_max_context
         | Inspector.Carried_librarian_point_at_max_context
         | Inspector.Carried_past_librarian_point _ | Inspector.Carried_turn_start _
         | Inspector.Carried_covered _ ->
             fact history)
        @ (match carried.counted_tokens with
           | Some counted ->
               fact
                 (Printf.sprintf
                    (if ko then "원장 기준선 %s tok · 이전 사용량 표본이 유지되거나 이력 정리 후 보정될 수 있습니다."
                     else "Ledger baseline %s tok; may retain an earlier usage sample or be adjusted after history eviction.")
                    (Inspector.format_tokens counted))
           | None -> [])
  in
  (* The request in the order it travels, one numbered row per slot, the
     [system context] blocks named in the order the assembly concatenates
     them. Only drawn when the server laid it out, which is when both the
     range and the fixed parts were known, and only for the candidate that
     walks first: the others are what the walk would send after a failure. *)
  let assembly_lines =
    match candidate.assembly with
    | None -> []
    | Some _ when candidate.place.walks_at > 0 -> []
    | Some slots ->
        let row index label bytes detail =
          let tok_cell = Masc_tui_message_layout.pad_left (approx bytes) 8 in
          fact
            (Printf.sprintf "%d  %s %s tok%s" (index + 1) (pad_label ~cells:16 label) tok_cell
               (if String.equal detail "" then "" else "  \xc2\xb7  " ^ detail))
        in
        prose (say "요청에 실리는 순서:" "In the order the request carries them:")
        @ List.concat
            (List.mapi
               (fun index slot ->
                 match slot with
                 | Inspector.Slot_system_prompt { bytes } ->
                     row index (say "시스템 프롬프트" "system prompt") bytes (say "키퍼 지시문" "keeper instructions")
                 | Inspector.Slot_tools { bytes } ->
                     row index (say "도구" "tools") bytes (say "스키마 표면" "schema surface")
                 | Inspector.Slot_preamble { bytes } ->
                     row index "[context window]" bytes (say "이전 턴 생략 안내" "says older turns are omitted")
                 | Inspector.Slot_history { atoms; of_atoms; bytes } ->
                     row index (say "대화 이력" "history") bytes
                       (if ko then Printf.sprintf "아톰 %d / %d개 (오래된 순)" atoms of_atoms
                        else Printf.sprintf "%d of %d atoms, oldest first" atoms of_atoms)
                 | Inspector.Slot_wake_line { bytes } ->
                     row index (say "호출 줄" "wake line") bytes (say "최신 아톰" "newest atom")
                 | Inspector.Slot_system_context { bytes; blocks } ->
                     row index "[system context]" bytes
                       (String.concat "  \xc2\xb7  "
                          (List.map
                             (fun (name, block_bytes) -> safe name ^ " " ^ approx block_bytes)
                             blocks)))
               slots)
  in
  head @ List.concat_map (fun line -> fact (safe line)) (runtime_details candidate.runtime_id)
  @ prose (walk_sentence ~ko ~safe walk candidate) @ parts_line @ carried_lines
  @ assembly_lines
;;

let lines ?(ko = false) ?(runtime_details = fun _ -> []) ~prose ~fact ~detail ~error ~safe ~safe_detail ~scale
    (forecast : (Inspector.forecast, string) result) =
  let say korean english = if ko then korean else english in
  match forecast with
  | Error detail ->
      error ~label:(say "다음 요청 예측 불가" "Next request not forecast") detail
  | Ok forecast ->
      let checkpoint =
        prose
          (Printf.sprintf
             (if ko then "체크포인트 메시지 %d건 · 호출 줄이 최신 아톰으로 %s tok 추가됩니다."
              else "%d messages in the checkpoint; the wake line adds %s tok as the newest atom.")
             forecast.Inspector.checkpoint_messages (Masc_tui_token_scale.format_estimate scale forecast.Inspector.wake_line_bytes))
      in
      (match forecast.Inspector.walk with
       | Error refusal ->
           error ~label:(say "다음 요청 경로 확인 불가" "Next request not walked") refusal
           @ checkpoint
       | Ok walk ->
           fact
             (Printf.sprintf
                (if ko then "레인 %s · 후보 %d개 · 실행 순서"
                 else "Lane %s · %d candidates · execution order")
                (safe walk.lane_id) (List.length forecast.Inspector.candidates))
           @ List.concat_map
             (candidate_lines ~ko ~runtime_details ~prose ~fact ~detail ~safe ~safe_detail ~scale ~walk)
             forecast.Inspector.candidates
           @ checkpoint
           @ prose
               (say "≈ 표시는 바이트 기준 토큰 추정치이며 실제 공급자 사용량이 아닙니다."
                  "Figures marked ≈ estimate token equivalents from bytes; they are not provider usage.")
           @ prose
               (Printf.sprintf
                  (if ko then
                     "레인 %s: 다음 사이클에서 시도할 후보 %d개 순서입니다. 실패 후 보류된 턴은 남은 후보를 이어서 시도합니다."
                   else
                     "Lane %s: %d candidates in the order the next cycle walks them; a turn \
                      that failed and deferred its input walks its remaining candidates \
                      instead.")
                  (safe walk.lane_id)
                  (List.length forecast.Inspector.candidates)))
;;
