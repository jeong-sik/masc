module Command = Masc.Keeper_board_attention_quarantine_command
module Candidate = Masc.Keeper_board_attention_candidate
module Terminal_text = Masc_tui_ansi.Terminal_text

type row =
  | Item of Command.inventory_item
  | Unreadable_row of string

type t =
  { rows : row list
  ; errors : Command.inventory_error list
  ; unreadable_errors : string list
  }

let decode json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "items" fields, List.assoc_opt "errors" fields with
     | Some (`List items), Some (`List errors) ->
       let rows =
         List.map
           (fun item ->
              match Command.inventory_item_of_json item with
              | Ok item -> Item item
              | Error detail -> Unreadable_row detail)
           items
       in
       let errors, unreadable_errors =
         List.partition_map
           (fun error ->
              match Command.inventory_error_of_json error with
              | Ok error -> Either.Left error
              | Error detail -> Either.Right detail)
           errors
       in
       Ok { rows; errors; unreadable_errors }
     | _ -> Error "board quarantines: items and errors must be lists")
  | _ -> Error "board quarantines: body must be an object"
;;

type tone =
  | Plain
  | Dim
  | Warn
  | Bad

let category_words ~ko : Candidate.quarantine_failure_category -> string =
  let say korean english = if ko then korean else english in
  function
  | Candidate.Exact_execution_interrupted ->
    say "재시작이 판정 호출을 끊음 (다시 넣으면 다시 보냄)" "a restart cut the judgment call (a requeue sends it again)"
  | Candidate.Exact_execution_quarantined ->
    say "호출 단계를 기록하지 못함 (호출은 이미 나갔을 수 있음)" "the call step could not be recorded (the call may already have gone out)"
  | Candidate.Exact_lane_exhausted -> say "판정 모델이 모두 실패했거나 쓸 수 없음" "every judgment model failed or is unavailable"
  | Candidate.Exact_flow_bookkeeping_failed -> say "판정 흐름이 실행을 기록하지 못함" "judgment flow could not record its run"
  | Candidate.Exact_completion_failed -> say "판정은 왔지만 저장하지 못함" "judgment arrived but could not be saved"
  | Candidate.Candidate_membership_conflict -> say "후보가 다른 partition 에 속함" "candidate belongs to another partition"
  | Candidate.Durable_partition_invariant -> say "partition ledger 가 스스로 어긋남" "partition ledger contradicts itself"
  | Candidate.Exact_setup_unavailable -> say "판정 lane 을 준비하지 못함" "judgment lane could not be set up"
  | Candidate.Exact_flow_replayed -> say "판정이 다시 재생됨" "judgment was replayed"
  | Candidate.Domain_output_invalid -> say "판정 답의 형식이 허용되지 않음" "judge answered in a shape it may not"
  | Candidate.Execution_provenance_mismatch -> say "답이 다른 호출에서 옴" "answer came from a different call"
  | Candidate.Unexpected_worker_failure -> say "worker 가 예기치 않게 실패" "worker failed unexpectedly"
;;

(* An unfinished requeue still waits: Q sends the same request, and the server
   finishes the partition write the earlier attempt did not reach. An
   unreconciled row does not: the request would only come back refused. *)
let awaits_operator (item : Command.inventory_item) =
  match item.Command.phase with
  | Command.Inventory_quarantined
  | Command.Inventory_requeue_requested
  | Command.Inventory_requeue_unfinished -> true
  | Command.Inventory_requeued | Command.Inventory_requeue_unreconciled -> false
;;

let items (quarantines : t) =
  List.filter_map
    (function
      | Item item -> Some item
      | Unreadable_row _ -> None)
    quarantines.rows
;;

let compare_oldest (left : Command.inventory_item) (right : Command.inventory_item) =
  match Float.compare left.Command.quarantined_at right.Command.quarantined_at with
  | 0 -> String.compare left.Command.partition_id right.Command.partition_id
  | order -> order
;;

let waiting quarantines =
  items quarantines |> List.filter awaits_operator |> List.sort compare_oldest
;;

let oldest_waiting quarantines =
  match waiting quarantines with
  | oldest :: _ -> Some oldest
  | [] -> None
;;

type bulk_requeue_decision =
  | Bulk_requeue of Command.inventory_item list
  | Bulk_nothing_waiting
  | Bulk_not_read

let decide_bulk_requeue view =
  match view with
  | Masc_tui_fetched.Ready quarantines ->
    (match waiting quarantines with
     | [] -> Bulk_nothing_waiting
     | items -> Bulk_requeue items)
  | Masc_tui_fetched.Absent
  | Masc_tui_fetched.Loading
  | Masc_tui_fetched.Stale _
  | Masc_tui_fetched.Failed _ -> Bulk_not_read
;;

let requeue_request (item : Command.inventory_item) : Command.request =
  { Command.candidate_id = item.Command.candidate_id
  ; expected_quarantine_id = item.Command.quarantine_id
  ; decision = Command.Acknowledge_and_requeue
  }
;;

type outcome_kind =
  | Accepted
  | Refused
  | Uncertain

type batch_counts =
  { attempted : int
  ; total : int
  ; accepted : int
  ; refused : int
  ; uncertain : int
  }

let requeue_all ~send ~classify ~progress items =
  let initial =
    { attempted = 0
    ; total = List.length items
    ; accepted = 0
    ; refused = 0
    ; uncertain = 0
    }
  in
  let rec loop counts outcomes = function
    | [] -> List.rev outcomes
    | (item : Command.inventory_item) :: remaining ->
      let partition_id = item.Command.partition_id in
      let outcome = send ~partition_id ~request:(requeue_request item) in
      let counts =
        match classify outcome with
        | Accepted ->
          { counts with attempted = counts.attempted + 1; accepted = counts.accepted + 1 }
        | Refused ->
          { counts with attempted = counts.attempted + 1; refused = counts.refused + 1 }
        | Uncertain ->
          { counts with attempted = counts.attempted + 1; uncertain = counts.uncertain + 1 }
      in
      progress counts;
      loop counts ((partition_id, outcome) :: outcomes) remaining
  in
  loop initial [] items
;;

let seconds_per_minute = 60
let seconds_per_hour = 3600
let seconds_per_day = 86400

(* The same span words the roster uses for an idle lane. *)
let span_words seconds =
  let seconds = max 0 seconds in
  if seconds < seconds_per_minute then Printf.sprintf "%ds" seconds
  else if seconds < seconds_per_hour then
    Printf.sprintf "%dm" (seconds / seconds_per_minute)
  else if seconds < seconds_per_day then
    Printf.sprintf "%dh" (seconds / seconds_per_hour)
  else Printf.sprintf "%dd" (seconds / seconds_per_day)
;;

let unreadable_rows (quarantines : t) =
  List.filter_map
    (function
      | Unreadable_row detail -> Some detail
      | Item _ -> None)
    quarantines.rows
;;

(* Oldest-first rows grouped by what stopped them. Groups keep the order of
   their oldest row, so the first group holds the requeue key's target. A day
   of one failure can quarantine hundreds of partitions; one line per cause
   keeps the Info tab readable. *)
type category_group =
  { oldest : Command.inventory_item
  ; members : Command.inventory_item list
  }

let by_category (oldest_first : Command.inventory_item list) =
  let same_cause (item : Command.inventory_item) group =
    group.oldest.Command.failure_category = item.Command.failure_category
  in
  List.fold_left
    (fun groups (item : Command.inventory_item) ->
       if List.exists (same_cause item) groups then
         List.map
           (fun group ->
              if same_cause item group then { group with members = group.members @ [ item ] }
              else group)
           groups
       else groups @ [ { oldest = item; members = [ item ] } ])
    []
    oldest_first
;;

let lines ~ko ~now fetched ~keeper_name =
  let say korean english = if ko then korean else english in
  match Masc_tui_fetched.view_for ~equal:String.equal fetched ~key:keeper_name with
  | Masc_tui_fetched.Absent -> [ Dim, say "읽기 전" "not read yet" ]
  | Masc_tui_fetched.Loading -> [ Dim, say "읽는 중\xe2\x80\xa6" "reading\xe2\x80\xa6" ]
  | Masc_tui_fetched.Stale (_, detail) | Masc_tui_fetched.Failed detail ->
    [ Bad, say "읽지 못함: " "could not read: " ^ Terminal_text.single_line detail ]
  | Masc_tui_fetched.Ready quarantines ->
    let waiting_items = waiting quarantines in
    let unreconciled_items =
      items quarantines
      |> List.filter (fun (item : Command.inventory_item) ->
        item.Command.phase = Command.Inventory_requeue_unreconciled)
      |> List.sort compare_oldest
    in
    let summary =
      match waiting_items, unreconciled_items with
      | [], [] -> [ Dim, say "막힌 것 없음" "nothing blocked" ]
      | [], _ :: _ -> []
      | _ :: _, _ ->
        [ ( Warn
          , Printf.sprintf
              (if ko then "%d건 막힘, 운영자 대기 \xc2\xb7 Q 가장 오래된 것 \xc2\xb7 B 전부"
               else "%d blocked, waiting for an operator \xc2\xb7 Q oldest \xc2\xb7 B all")
              (List.length waiting_items) )
        ]
    in
    let group_lines =
      List.map
        (fun { oldest; members } ->
             let age =
               span_words (Float.to_int (now -. oldest.Command.quarantined_at))
             in
             let asked =
               List.length
                 (List.filter
                    (fun (item : Command.inventory_item) ->
                       match item.Command.phase with
                       | Command.Inventory_requeue_requested
                       | Command.Inventory_requeue_unfinished -> true
                       | Command.Inventory_quarantined
                       | Command.Inventory_requeued
                       | Command.Inventory_requeue_unreconciled -> false)
                    members)
             in
             let asked_words =
               if asked = 0 then ""
               else
                 Printf.sprintf
                   (if ko then " \xc2\xb7 다시 넣기 요청 %d건 미완료"
                    else " \xc2\xb7 %d requeue asked, not finished")
                   asked
             in
             ( Plain
             , Printf.sprintf
                 (if ko then "%d건 \xc2\xb7 %s \xc2\xb7 가장 오래된 것 %s 전 \xc2\xb7 %s%s"
                  else "%d \xc2\xb7 %s \xc2\xb7 oldest %s ago \xc2\xb7 %s%s")
                 (List.length members)
                 (category_words ~ko oldest.Command.failure_category)
                 age
                 (Terminal_text.single_line oldest.Command.partition_id)
                 asked_words ))
        (by_category waiting_items)
    in
    let requeued =
      List.length
        (List.filter
           (fun (item : Command.inventory_item) ->
              item.Command.phase = Command.Inventory_requeued)
           (items quarantines))
    in
    let requeued_lines =
      (if requeued = 0 then []
       else [ Dim, Printf.sprintf (if ko then "다시 넣음 %d건" else "%d requeued") requeued ])
      @
      match unreconciled_items with
      | [] -> []
      | oldest :: _ ->
        [ ( Bad
          , Printf.sprintf
              (if ko then "partition ledger 가 확인하지 않는 다시 넣기 %d건 \xc2\xb7 가장 오래된 것 %s"
               else "%d requeue(s) the partition ledger does not confirm \xc2\xb7 oldest %s")
              (List.length unreconciled_items)
              (Terminal_text.single_line oldest.Command.partition_id) )
        ]
    in
    let unreadable = unreadable_rows quarantines @ quarantines.unreadable_errors in
    let unreadable_lines =
      match unreadable with
      | [] -> []
      | first :: _ ->
        [ ( Bad
          , Printf.sprintf
              (if ko then "이 TUI 가 못 읽는 줄 %d개: %s" else "%d row(s) this TUI cannot read: %s")
              (List.length unreadable)
              (Terminal_text.single_line first) )
        ]
    in
    let ledger_lines =
      List.map
        (fun (error : Command.inventory_error) ->
           let keeper = Terminal_text.single_line error.Command.keeper_name in
           match error.Command.kind with
           | Command.Inventory_candidate_ledger_unavailable ->
             ( Bad
             , if ko then keeper ^ " 의 candidate ledger 를 읽지 못함"
               else "candidate ledger unreadable for " ^ keeper )
           | Command.Inventory_partition_ledger_unavailable ->
             ( Bad
             , if ko then keeper ^ " 의 partition ledger 를 읽지 못함"
               else "partition ledger unreadable for " ^ keeper ))
        quarantines.errors
    in
    summary @ group_lines @ requeued_lines @ unreadable_lines @ ledger_lines
;;
