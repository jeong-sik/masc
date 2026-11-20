module Status = Masc.Keeper_cleanup_status
module Status_json = Masc.Keeper_cleanup_status_json
module Step = Masc.Keeper_cleanup_step
module Tools = Masc.Tui_decode_tools

module Say = Masc_tui_say

let single_line = Masc.Tui_terminal_text.sanitize_terminal_text
let received text = Say.as_received (single_line text)
let ( ++ ) = Say.( ++ )
let dot = Say.code " · "

type tone =
  | Heading
  | Plain
  | Dim
  | Warn
  | Bad

let step_label = function
  | Step.Guest_builds -> Say.both ~ko:"게스트 _build" ~en:"guest _build"
  | Step.Remote_workspace -> Say.both ~ko:"원격 작업 폴더" ~en:"remote workspace"
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
  | Tools.Host_disk_absent ->
    Dim, Say.both ~ko:"호스트 디스크: 서버가 잰 값이 아직 없습니다."
           ~en:"Host disk: the server has not measured it yet."
  | Tools.Host_disk_probe_failed detail ->
    Bad, Say.both ~ko:"호스트 디스크: 서버가 재지 못했습니다 · " ~en:"Host disk: the server could not measure it · "
         ++ received detail
  | Tools.Host_disk_unreadable reason ->
    Bad, Say.both ~ko:"호스트 디스크: 서버가 보낸 값을 읽지 못했습니다 · "
           ~en:"Host disk: the value the server sent could not be read · "
         ++ received reason
  | Tools.Host_disk_measured { Tools.hd_mounted_on; hd_total_bytes; hd_available_bytes } ->
    let share =
      if hd_total_bytes > 0
      then
        Printf.sprintf
          " (%.1f%%)"
          (Float.of_int hd_available_bytes /. Float.of_int hd_total_bytes *. 100.)
      else ""
    in
    let available = bytes_text hd_available_bytes and total = bytes_text hd_total_bytes in
    ( Plain
    , Say.both ~ko:"호스트 디스크 " ~en:"Host disk " ++ received hd_mounted_on
      ++ Say.per_language (function
           | Say.Ko -> Printf.sprintf ": 남은 공간 %s / 전체 %s%s" available total share
           | Say.En -> Printf.sprintf ": %s free of %s%s" available total share) )
;;

let since_start =
  Say.both ~ko:"아래 정리 결과는 서버가 뜬 뒤의 것입니다."
    ~en:"The cleanup results below are from after the server started."

let uptime_line = function
  | Some uptime ->
    Dim, Say.both ~ko:"서버 가동 " ~en:"Server up " ++ received uptime ++ dot ++ since_start
  | None -> Dim, since_start
;;

let names_text names = Say.as_received (String.concat ", " (List.map single_line names))

let pass_lines ~timestamp = function
  | Error reason ->
    [ Bad, Say.both ~ko:"정리 주기 요약을 읽지 못했습니다: " ~en:"The cleanup pass summary could not be read: "
           ++ received reason ]
  | Ok None ->
    [ Dim, Say.both ~ko:"정리 주기: 서버가 뜬 뒤 아직 돌지 않았습니다."
             ~en:"Cleanup pass: it has not run since the server started." ]
  | Ok (Some (pass : Status.pass)) ->
    let steps =
      List.map
        (fun ({ step; enabled; selected } : Status.step_pass) ->
          if enabled
          then
            ( Dim
            , Say.code "  " ++ step_label step
              ++ Say.per_language (function
                   | Say.Ko -> Printf.sprintf ": 켜짐 · 고른 Keeper %d" selected
                   | Say.En -> Printf.sprintf ": on · %d Keepers chosen" selected) )
          else Warn, Say.code "  " ++ step_label step ++ Say.both ~ko:": 꺼짐" ~en:": off")
        pass.steps
    in
    let still_running =
      match pass.still_running with
      | [] -> []
      | names ->
        [ Dim, Say.both ~ko:"  앞 시도가 아직 안 끝난 Keeper: " ~en:"  Keepers whose last attempt is still running: "
               ++ names_text names ]
    in
    let started = timestamp pass.started_at in
    (* How often the pass runs is a setting (RFC tui-one-screen-grammar 6.2):
       [5m], [1m30s], not [300초] or [300s]. *)
    let interval = Masc_tui_value.Interval.of_seconds pass.interval_sec in
    [ ( Plain
      , Say.per_language (function
          | Say.Ko -> Printf.sprintf "정리 주기 %s · 간격 %s · 훑은 Keeper %d"
              started interval pass.owners
          | Say.En -> Printf.sprintf "Cleanup pass %s · every %s · %d Keepers looked at"
              started interval pass.owners) )
    ; ( Dim
      , Say.per_language (function
          | Say.Ko -> Printf.sprintf
              "  예약 %d · 앞 시도가 안 끝남 %d · 맞는 단계 없음 %d · 꺼짐 %d · meta 없음 %d · 선언을 못 읽음 %d"
              pass.scheduled (List.length pass.still_running) pass.no_step pass.switched_off
              pass.without_meta (List.length pass.unreadable)
          | Say.En -> Printf.sprintf
              "  scheduled %d · still running %d · no step %d · off %d · no meta %d · unreadable %d"
              pass.scheduled (List.length pass.still_running) pass.no_step pass.switched_off
              pass.without_meta (List.length pass.unreadable)) )
    ]
    @ steps
    @ still_running
;;

(* What happened, and the step's or the Owner's own words when it gave any.
   The words can run long, so the row puts them last. *)
let outcome_text report_text = function
  | Status.Reclaimed report -> report_text report, None
  | Status.Deferred reason -> Say.both ~ko:"Keeper 가 바빠 미룸" ~en:"deferred, the Keeper was busy", Some reason
  | Status.Not_running -> Say.both ~ko:"붙을 대상이 떠 있지 않음" ~en:"nothing running to attach to", None
  | Status.Failed reason -> Say.both ~ko:"실패" ~en:"failed", Some reason
;;

let builds_text ({ cleaned; failed } : Status.builds) =
  Say.per_language (function
    | Say.Ko -> Printf.sprintf "지움 %d · 못 지움 %d" cleaned failed
    | Say.En -> Printf.sprintf "removed %d · not removed %d" cleaned failed)
;;

let workspace_text
      ({ removed; skipped; failed; freed_kib; available_kib } : Status.workspace)
  =
  let change = change_text freed_kib and available = kib_text available_kib in
  Say.per_language (function
    | Say.Ko -> Printf.sprintf "지움 %d · 남김 %d · 못 지움 %d · 여유 변화 %s · 남은 공간 %s"
        removed skipped failed change available
    | Say.En -> Printf.sprintf "removed %d · kept %d · not removed %d · free space change %s · %s free"
        removed skipped failed change available)
;;

let attempt_text = function
  | Status.Guest_builds outcome -> outcome_text builds_text outcome
  | Status.Remote_workspace outcome -> outcome_text workspace_text outcome
;;

(* A row whose latest attempt ran to its end is its own last success. *)
let last_success_text ~timestamp (row : Status.row) =
  match row.attempt with
  | Status.Guest_builds (Status.Reclaimed _) | Status.Remote_workspace (Status.Reclaimed _) ->
    Say.empty
  | Status.Guest_builds (Status.Deferred _ | Status.Not_running | Status.Failed _)
  | Status.Remote_workspace (Status.Deferred _ | Status.Not_running | Status.Failed _) ->
    (match row.reclaimed_at with
     | Some at ->
       Say.both ~ko:" · 마지막으로 끝까지 돈 때 " ~en:" · last ran to the end at " ++ Say.as_received (timestamp at)
     | None -> Say.both ~ko:" · 서버가 뜬 뒤 끝까지 돈 적 없음" ~en:" · has not run to the end since the server started")
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
  , Say.code "  " ++ received row.keeper
    ++ dot ++ step_label (Status.step row.attempt)
    ++ dot ++ happened
    ++ dot ++ Say.as_received (timestamp row.finished_at)
    ++ last_success_text ~timestamp row
    ++ (match words with
        | Some words -> dot ++ received words
        | None -> Say.empty) )
;;

let unreadable_line ({ keeper; reason } : Status.unreadable) =
  ( Bad
  , Say.code "  " ++ received keeper
    ++ Say.both ~ko:" · 선언을 읽지 못해 정리하지 않음 · " ~en:" · declaration unreadable, not cleaned · "
    ++ received reason )
;;

(* A block of the pane, set off from the one above by an empty line. *)
let block = function
  | [] -> []
  | lines -> (Plain, Say.empty) :: lines
;;

let section title = function
  | [] -> []
  | rows ->
    block ((Heading, title ++ Say.code (Printf.sprintf " %d" (List.length rows))) :: rows)
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
       | Ok (Some _) ->
         block [ Dim, Say.both ~ko:"Keeper 별 결과: 아직 끝난 시도가 없습니다."
                        ~en:"Results by Keeper: no attempt has finished yet." ]
       | Ok None | Error _ -> [])
    | _ :: _ ->
      section (Say.both ~ko:"Keeper 별 결과" ~en:"Results by Keeper") (List.map (row_line ~timestamp) others)
  in
  let unread =
    section
      (Say.both ~ko:"읽지 못한 행" ~en:"Rows not read")
      (List.map (fun reason -> Bad, Say.code "  " ++ received reason) reading.unread_rows)
  in
  let unknown =
    match reading.unknown_fields with
    | [] -> []
    | names ->
      block [ Warn, Say.both ~ko:"이 TUI 가 모르는 칸: " ~en:"Fields this TUI does not know: " ++ names_text names ]
  in
  pass_lines ~timestamp reading.read_pass
  @ section (Say.both ~ko:"먼저 볼 것" ~en:"Look at these first") (unreadable @ List.map (row_line ~timestamp) first)
  @ results
  @ unread
  @ unknown
;;

let cleanup_lines ~timestamp = function
  | Tools.Keeper_cleanup_absent ->
    [ Dim, Say.both ~ko:"정리 결과: 이 서버는 정리 결과를 내지 않습니다."
             ~en:"Cleanup results: this server does not report them." ]
  | Tools.Keeper_cleanup_unreadable reason ->
    [ Bad, Say.both ~ko:"정리 결과를 읽지 못했습니다: " ~en:"The cleanup results could not be read: "
           ++ received reason ]
  | Tools.Keeper_cleanup_read reading -> reading_lines ~timestamp reading
;;

let lines ~timestamp ~uptime ({ Tools.st_host_disk; st_keeper_cleanup } : Tools.storage) =
  host_disk_line st_host_disk
  :: uptime_line uptime
  :: block (cleanup_lines ~timestamp st_keeper_cleanup)
;;
