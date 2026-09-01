type decision_preview = string

let decision_preview_of_string value = value
let decision_preview_to_string value = value

type outcome =
  | Succeeded
  | Succeeded_with_summary of
      { decision : decision_preview
      ; summary : string
      }
  | Failed of
      { reason : string
      ; code : string
      }

type run_status =
  | Running
  | Completed of outcome

type progress =
  | Progress_accepted
  | Progress_panel_running of { expected : int }
  | Progress_judge_running of
      { expected : int
      ; answered : int
      ; failed : int
      }
  | Progress_computed of
      { expected : int
      ; answered : int
      ; failed : int
      }
  | Progress_recording_evidence of
      { expected : int
      ; answered : int
      ; failed : int
      }

type run =
  { run_id : string
  ; keeper : string
  ; preset : string
  ; topology : Fusion_types.fusion_topology
  ; started_at : float
  ; status : run_status
  ; progress : progress option
  }

module Payload = struct
  (* [topology] 는 요청이 고른 심의 위상이다. registry 가 보관하는 이유는 이것이
     완료 후에도 필요한 유일한 자리이기 때문이다 — obligation payload 에도 있지만
     그 레코드는 배달 직후 제거되므로, 완료된 run 의 위상을 되읽을 곳이 없어진다. *)
  type registration =
    { keeper : string
    ; preset : string
    ; topology : Fusion_types.fusion_topology
    }

  type completion = outcome

  let name = "fusion_run_registry"
  let running_noun = "run(s)"
  let restart_reason = "worker fibers do not survive server restart"
  let replayed_running_completion = None
  let completed_retention = `Latest 64
  let retention_group = None

  let registration_to_yojson registration =
    `Assoc
      [ "keeper", `String registration.keeper
      ; "preset", `String registration.preset
      ; ( "topology"
        , `String (Fusion_types.fusion_topology_to_string registration.topology) )
      ]
  ;;

  let registration_of_yojson json =
    let ( let* ) = Result.bind in
    let* fields = Run_registry_core.Json.object_fields json in
    (* [exact_fields] 라 topology 없는 예전 레코드는 여기서 Error 가 되고 replay 가
       그 줄만 스킵한다(경고 1줄). 레거시 폴백을 두지 않는 이유는 registry 가 캐시성
       데이터이기 때문이다 — running 은 재시작으로 이미 무효고 완료분은 Latest 64
       보존이다. 폴백을 두면 "위상 미상" 이라는 새 상태를 UI 까지 끌고 가야 한다. *)
    let* () =
      Run_registry_core.Json.exact_fields
        ~required:[ "keeper"; "preset"; "topology" ]
        fields
    in
    let* keeper = Run_registry_core.Json.string_field "keeper" fields in
    let* preset = Run_registry_core.Json.string_field "preset" fields in
    let* topology_wire = Run_registry_core.Json.string_field "topology" fields in
    match Fusion_types.fusion_topology_of_string topology_wire with
    | None -> Error (Printf.sprintf "unknown fusion topology %S" topology_wire)
    | Some topology -> Ok { keeper; preset; topology }
  ;;

  let completion_to_yojson = function
    | Succeeded -> `Assoc [ "outcome", `String "succeeded" ]
    | Succeeded_with_summary { decision; summary } ->
      `Assoc
        [ "outcome", `String "succeeded"
        ; "decision", `String (decision_preview_to_string decision)
        ; "summary", `String summary
        ]
    | Failed { reason; code } ->
      `Assoc
        [ "outcome", `String "failed"
        ; "reason", `String reason
        ; "code", `String code
        ]
  ;;

  let completion_of_yojson json =
    let ( let* ) = Result.bind in
    let* fields = Run_registry_core.Json.object_fields json in
    let* label = Run_registry_core.Json.string_field "outcome" fields in
    match label with
    | "succeeded" ->
      let* () =
        Run_registry_core.Json.exact_fields ~required:[ "outcome" ]
          ~optional:[ "decision"; "summary" ] fields
      in
      let* decision =
        Run_registry_core.Json.optional_string_field "decision" fields
      in
      let* summary =
        Run_registry_core.Json.optional_string_field "summary" fields
      in
      (match decision, summary with
       | None, None -> Ok Succeeded
       | Some decision, Some summary ->
         Ok
           (Succeeded_with_summary
              { decision = decision_preview_of_string decision; summary })
       | Some _, None | None, Some _ ->
         Error "succeeded fusion completion requires decision and summary together")
    | "failed" ->
      let* () =
        Run_registry_core.Json.exact_fields
          ~required:[ "outcome"; "reason"; "code" ]
          fields
      in
      let* reason = Run_registry_core.Json.string_field "reason" fields in
      let* code = Run_registry_core.Json.string_field "code" fields in
      Ok (Failed { reason; code })
    | other -> Error (Printf.sprintf "unknown fusion outcome %S" other)
  ;;
end

module Store = Run_registry_core.Make (Payload)

type t =
  { store : Store.t
  ; progress_by_run : (string, progress) Hashtbl.t
  ; progress_mutex : Stdlib.Mutex.t
  }

let storage_filename = "fusion-runs.jsonl"
let create ?path () =
  { store = Store.create ?path ()
  ; progress_by_run = Hashtbl.create 16
  ; progress_mutex = Stdlib.Mutex.create ()
  }
;;

let replay path =
  { store = Store.replay path
  ; progress_by_run = Hashtbl.create 16
  ; progress_mutex = Stdlib.Mutex.create ()
  }
;;

let max_completed_retained = Store.max_completed_retained
let cut_replay_log ~execute path = Store.cut_replay_log ~execute path

let register_running t ~run_id ~keeper ~preset ~topology ~started_at =
  Store.register t.store ~id:run_id ~started_at
    ~registration:{ Payload.keeper; preset; topology };
  Stdlib.Mutex.protect t.progress_mutex (fun () ->
    Hashtbl.replace t.progress_by_run run_id Progress_accepted)
;;

let mark_progress t ~run_id ~progress =
  match Store.get t.store ~id:run_id with
  | Some { status = Store.Running; _ } ->
    Stdlib.Mutex.protect t.progress_mutex (fun () ->
      Hashtbl.replace t.progress_by_run run_id progress)
  | Some { status = Store.Completed _; _ } | None -> ()
;;

let mark_completed t ~run_id ~outcome =
  match Store.complete t.store ~id:run_id ~completion:outcome with
  | `Completed ->
    Stdlib.Mutex.protect t.progress_mutex (fun () ->
      Hashtbl.remove t.progress_by_run run_id)
  | `Unknown -> ()
  | `Persistence_failed failure -> raise (Sys_error failure.detail)
;;

let run_of_entry t (entry : Store.entry) =
  let status, progress =
    match entry.status with
    | Store.Running ->
      let progress =
        Stdlib.Mutex.protect t.progress_mutex (fun () ->
          Hashtbl.find_opt t.progress_by_run entry.id)
        |> Option.value ~default:Progress_accepted
      in
      Running, Some progress
    | Store.Completed outcome -> Completed outcome, None
  in
  { run_id = entry.id
  ; keeper = entry.registration.keeper
  ; preset = entry.registration.preset
  ; topology = entry.registration.topology
  ; started_at = entry.started_at
  ; status
  ; progress
  }
;;

let list_runs t =
  let entries = Store.list_entries t.store in
  Stdlib.Mutex.protect t.progress_mutex (fun () ->
    Hashtbl.filter_map_inplace
      (fun run_id progress ->
         if
           List.exists
             (fun (entry : Store.entry) ->
                String.equal entry.id run_id
                &&
                match entry.status with
                | Store.Running -> true
                | Store.Completed _ -> false)
             entries
         then Some progress
         else None)
      t.progress_by_run);
  List.map (run_of_entry t) entries
;;

let get t ~run_id = Option.map (run_of_entry t) (Store.get t.store ~id:run_id)

let status_label = function
  | Running -> "running"
  | Completed (Succeeded | Succeeded_with_summary _) -> "completed"
  | Completed (Failed _) -> "failed"
;;

let progress_stage = function
  | Progress_accepted -> "accepted"
  | Progress_panel_running _ -> "panel"
  | Progress_judge_running _ -> "judge"
  | Progress_computed _ -> "computed"
  | Progress_recording_evidence _ -> "recording_evidence"
;;

let progress_to_yojson = function
  | Progress_accepted -> `Assoc []
  | Progress_panel_running { expected } ->
    `Assoc [ "panel_expected", `Int expected ]
  | Progress_judge_running { expected; answered; failed }
  | Progress_computed { expected; answered; failed }
  | Progress_recording_evidence { expected; answered; failed } ->
    `Assoc
      [ "panel_expected", `Int expected
      ; "panel_answered", `Int answered
      ; "panel_failed", `Int failed
      ]
;;

let run_to_yojson run =
  let stage, progress_json =
    match run.status, run.progress with
    | Running, Some progress -> progress_stage progress, progress_to_yojson progress
    | Running, None -> "accepted", `Assoc []
    | Completed (Succeeded | Succeeded_with_summary _), None ->
      "completed", `Null
    | Completed (Failed _), None -> "failed", `Null
    | Completed _, Some _ -> "completed", `Null
  in
  let base =
    [ "run_id", `String run.run_id
    ; "keeper", `String run.keeper
    ; "preset", `String run.preset
    ; "topology", `String (Fusion_types.fusion_topology_to_string run.topology)
    ; "started_at", `Float run.started_at
    ; "status", `String (status_label run.status)
    ; "stage", `String stage
    ; "progress", progress_json
    ]
  in
  let outcome_fields =
    match run.status with
    | Running | Completed Succeeded -> []
    | Completed (Succeeded_with_summary { decision; summary }) ->
      [ "decision", `String (decision_preview_to_string decision)
      ; "summary", `String summary
      ]
    | Completed (Failed { reason; code }) ->
      [ "error", `String reason; "failure_code", `String code ]
  in
  `Assoc (base @ outcome_fields)
;;

type global_install_error = Already_installed

module Global = Run_registry_core.Global (struct
    type nonrec t = t

    let initial = create ()
  end)

let global = Global.current

let install_global registry =
  match Global.install registry with
  | Ok () -> Ok ()
  | Error Global.Already_installed -> Error Already_installed
;;
