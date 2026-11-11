module Status = Masc.Keeper_cleanup_status
module Status_json = Masc.Keeper_cleanup_status_json
module Step = Masc.Keeper_cleanup_step
module Tools = Masc.Tui_decode_tools

let single_line = Masc.Tui_terminal_text.sanitize_terminal_text

type tone =
  | Heading
  | Plain
  | Dim
  | Warn
  | Bad

let step_label = function
  | Step.Guest_builds -> "게스트 _build"
  | Step.Remote_workspace -> "원격 작업 폴더"
;;

(* A step's place in the step list, which is the order steps run. *)
let step_rank step =
  let rec place index = function
    | [] -> index
    | candidate :: rest ->
      if Step.equal candidate step then index else place (index + 1) rest
  in
  place 0 Step.all
;;

let by_keeper_then_step (a : Status.row) (b : Status.row) =
  match String.compare a.keeper b.keeper with
  | 0 -> Int.compare (step_rank (Status.step a.attempt)) (step_rank (Status.step b.attempt))
  | order -> order
;;

type standing =
  | Failed_attempt
  | Left_entries
  | Quiet

let standing (row : Status.row) =
  match Status.concern row.attempt with
  | Some (Status.Attempt_failed _) -> Failed_attempt
  | Some (Status.Entries_left _) -> Left_entries
  | None -> Quiet
;;

let arrange rows =
  let sorted = List.sort by_keeper_then_step rows in
  let standing_is wanted row = standing row = wanted in
  ( List.filter (standing_is Failed_attempt) sorted
    @ List.filter (standing_is Left_entries) sorted
  , List.filter (standing_is Quiet) sorted )
;;

let kib_per_mib = 1024.
let kib_per_gib = 1024. *. 1024.
let bytes_per_kib = 1024

let kib_text kib =
  let size = Float.abs (Float.of_int kib) in
  if size >= kib_per_gib
  then Printf.sprintf "%.1f GiB" (Float.of_int kib /. kib_per_gib)
  else if size >= kib_per_mib
  then Printf.sprintf "%.1f MiB" (Float.of_int kib /. kib_per_mib)
  else Printf.sprintf "%d KiB" kib
;;

let bytes_text bytes = kib_text (bytes / bytes_per_kib)

(* The change in free space carries its sign: other writers move it too. *)
let change_text kib = (if kib > 0 then "+" else "") ^ kib_text kib

let host_disk_line = function
  | Tools.Host_disk_absent -> Dim, "호스트 디스크: 서버가 잰 값이 아직 없습니다."
  | Tools.Host_disk_probe_failed detail ->
    Bad, "호스트 디스크: 서버가 재지 못했습니다 · " ^ single_line detail
  | Tools.Host_disk_unreadable reason ->
    Bad, "호스트 디스크: 서버가 보낸 값을 읽지 못했습니다 · " ^ single_line reason
  | Tools.Host_disk_measured { Tools.hd_mounted_on; hd_total_bytes; hd_available_bytes } ->
    let share =
      if hd_total_bytes > 0
      then
        Printf.sprintf
          " (%.1f%%)"
          (Float.of_int hd_available_bytes /. Float.of_int hd_total_bytes *. 100.)
      else ""
    in
    ( Plain
    , Printf.sprintf
        "호스트 디스크 %s: 남은 공간 %s / 전체 %s%s"
        (single_line hd_mounted_on)
        (bytes_text hd_available_bytes)
        (bytes_text hd_total_bytes)
        share )
;;

let uptime_line = function
  | Some uptime ->
    Dim, "서버 가동 " ^ single_line uptime ^ " · 아래 정리 결과는 서버가 뜬 뒤의 것입니다."
  | None -> Dim, "아래 정리 결과는 서버가 뜬 뒤의 것입니다."
;;

let names_text names = String.concat ", " (List.map single_line names)

let pass_lines ~timestamp = function
  | Error reason -> [ Bad, "정리 주기 요약을 읽지 못했습니다: " ^ single_line reason ]
  | Ok None -> [ Dim, "정리 주기: 서버가 뜬 뒤 아직 돌지 않았습니다." ]
  | Ok (Some (pass : Status.pass)) ->
    let steps =
      List.map
        (fun ({ step; enabled; selected } : Status.step_pass) ->
          if enabled
          then
            Dim, Printf.sprintf "  %s: 켜짐 · 고른 Keeper %d" (step_label step) selected
          else Warn, Printf.sprintf "  %s: 꺼짐" (step_label step))
        pass.steps
    in
    let still_running =
      match pass.still_running with
      | [] -> []
      | names -> [ Dim, "  앞 시도가 아직 안 끝난 Keeper: " ^ names_text names ]
    in
    [ ( Plain
      , Printf.sprintf
          "정리 주기 %s · 간격 %.0f초 · 훑은 Keeper %d"
          (timestamp pass.started_at)
          pass.interval_sec
          pass.owners )
    ; ( Dim
      , Printf.sprintf
          "  예약 %d · 앞 시도가 안 끝남 %d · 맞는 단계 없음 %d · 꺼짐 %d · meta 없음 %d · 선언을 못 읽음 %d"
          pass.scheduled
          (List.length pass.still_running)
          pass.no_step
          pass.switched_off
          pass.without_meta
          (List.length pass.unreadable) )
    ]
    @ steps
    @ still_running
;;

(* What happened, and the step's or the Owner's own words when it gave any.
   The words can run long, so the row puts them last. *)
let outcome_text report_text = function
  | Status.Reclaimed report -> report_text report, None
  | Status.Deferred reason -> "Keeper 가 바빠 넘김", Some reason
  | Status.Not_running -> "붙을 대상이 떠 있지 않음", None
  | Status.Failed reason -> "실패", Some reason
;;

let builds_text ({ cleaned; failed } : Status.builds) =
  Printf.sprintf "지움 %d · 못 지움 %d" cleaned failed
;;

let workspace_text
      ({ removed; skipped; failed; freed_kib; available_kib } : Status.workspace)
  =
  Printf.sprintf
    "지움 %d · 남김 %d · 못 지움 %d · 여유 변화 %s · 남은 공간 %s"
    removed
    skipped
    failed
    (change_text freed_kib)
    (kib_text available_kib)
;;

let attempt_text = function
  | Status.Guest_builds outcome -> outcome_text builds_text outcome
  | Status.Remote_workspace outcome -> outcome_text workspace_text outcome
;;

(* A row whose latest attempt ran to its end is its own last success. *)
let last_success_text ~timestamp (row : Status.row) =
  match row.attempt with
  | Status.Guest_builds (Status.Reclaimed _) | Status.Remote_workspace (Status.Reclaimed _) ->
    ""
  | Status.Guest_builds (Status.Deferred _ | Status.Not_running | Status.Failed _)
  | Status.Remote_workspace (Status.Deferred _ | Status.Not_running | Status.Failed _) ->
    (match row.reclaimed_at with
     | Some at -> " · 마지막으로 끝까지 돈 때 " ^ timestamp at
     | None -> " · 서버가 뜬 뒤 끝까지 돈 적 없음")
;;

let row_tone (row : Status.row) =
  match standing row with
  | Failed_attempt -> Bad
  | Left_entries -> Warn
  | Quiet ->
    (match row.attempt with
     | Status.Guest_builds (Status.Reclaimed _) | Status.Remote_workspace (Status.Reclaimed _) ->
       Plain
     | Status.Guest_builds (Status.Deferred _ | Status.Not_running | Status.Failed _)
     | Status.Remote_workspace (Status.Deferred _ | Status.Not_running | Status.Failed _) ->
       Dim)
;;

let row_line ~timestamp (row : Status.row) =
  let happened, words = attempt_text row.attempt in
  ( row_tone row
  , Printf.sprintf
      "  %s · %s · %s · %s%s%s"
      (single_line row.keeper)
      (step_label (Status.step row.attempt))
      happened
      (timestamp row.finished_at)
      (last_success_text ~timestamp row)
      (match words with
       | Some words -> " · " ^ single_line words
       | None -> "") )
;;

let unreadable_line ({ keeper; reason } : Status.unreadable) =
  ( Bad
  , Printf.sprintf
      "  %s · 선언을 읽지 못해 정리하지 않음 · %s"
      (single_line keeper)
      (single_line reason) )
;;

(* A block of the pane, set off from the one above by an empty line. *)
let block = function
  | [] -> []
  | lines -> (Plain, "") :: lines
;;

let section title = function
  | [] -> []
  | rows -> block ((Heading, Printf.sprintf "%s %d" title (List.length rows)) :: rows)
;;

let reading_lines ~timestamp (reading : Status_json.reading) =
  let unreadable =
    match reading.read_pass with
    | Ok (Some (pass : Status.pass)) -> List.map unreadable_line pass.unreadable
    | Ok None | Error _ -> []
  in
  let first, others = arrange reading.read_rows in
  let results =
    match reading.read_rows with
    | [] ->
      (match reading.read_pass with
       | Ok (Some _) -> block [ Dim, "Keeper 별 결과: 아직 끝난 시도가 없습니다." ]
       | Ok None | Error _ -> [])
    | _ :: _ -> section "Keeper 별 결과" (List.map (row_line ~timestamp) others)
  in
  let unread =
    section
      "읽지 못한 행"
      (List.map (fun reason -> Bad, "  " ^ single_line reason) reading.unread_rows)
  in
  let unknown =
    match reading.unknown_fields with
    | [] -> []
    | names -> block [ Warn, "이 TUI 가 모르는 칸: " ^ names_text names ]
  in
  pass_lines ~timestamp reading.read_pass
  @ section "먼저 볼 것" (unreadable @ List.map (row_line ~timestamp) first)
  @ results
  @ unread
  @ unknown
;;

let cleanup_lines ~timestamp = function
  | Tools.Keeper_cleanup_absent -> [ Dim, "정리 결과: 이 서버는 정리 결과를 내지 않습니다." ]
  | Tools.Keeper_cleanup_unreadable reason ->
    [ Bad, "정리 결과를 읽지 못했습니다: " ^ single_line reason ]
  | Tools.Keeper_cleanup_read reading -> reading_lines ~timestamp reading
;;

let lines ~timestamp ~uptime ({ Tools.st_host_disk; st_keeper_cleanup } : Tools.storage) =
  host_disk_line st_host_disk
  :: uptime_line uptime
  :: block (cleanup_lines ~timestamp st_keeper_cleanup)
;;
