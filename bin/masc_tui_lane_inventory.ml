module Inventory = Masc.Tui_decode_lane_inventory
open Inventory

module Category = Masc.Lane_addon_category
module L = Masc_tui_page_line
let row_category (row : row) = match row.selection with
  | Exact _ | Browser _ | Machine _ -> row.ui_category
  | Declaration _ ->
      (match row.state with
       | Package_state {declaration=Some (Valid value);_} -> value.ui_category
       | Package_state {declaration=Some (Invalid _ | Absent | Unobserved) | None;_}
       | Exact_state _ | Browser_clients _ | Machine_state _ -> None)
  | Manual_instance {instance_id;incarnation} ->
      (match row.state with
       | Package_state {declaration=None;instances} ->
           Option.bind (List.find_opt (fun (item:instance) ->
             item.instance_id=instance_id && item.incarnation=incarnation) instances)
             (fun item -> item.ui_category)
       | Package_state {declaration=Some _;_}
       | Exact_state _ | Browser_clients _ | Machine_state _ -> None)
let category_label = function
  | Some Category.Memory_and_judgment -> "기억 · 판단"
  | Some Category.Browser -> "브라우저"
  | Some Category.External_communications -> "외부 소통"
  | Some Category.Voice_and_media -> "음성 · 미디어"
  | Some Category.Execution_environment -> "실행 환경"
  | Some Category.Analysis -> "분석"
  | None -> "미분류"
type overview_entry = Category_header of Category.t option | Lane_row of row
let overview_entries rows =
  [Some Category.Memory_and_judgment;Some Category.Browser;
   Some Category.External_communications;Some Category.Voice_and_media;
   Some Category.Execution_environment;Some Category.Analysis;None]
  |> List.concat_map (fun category ->
       match List.filter (fun row -> row_category row=category) rows with
       | [] -> []
       | grouped -> Category_header category :: List.map (fun row -> Lane_row row) grouped)
let ordered_rows rows = overview_entries rows |> List.filter_map (function
  | Category_header _ -> None | Lane_row row -> Some row)
let row_position ~id entries = List.find_index (function
  | Category_header _ -> false | Lane_row row -> String.equal row.id id) entries
let row_lead ~id entries =
  match row_position ~id entries with
  | None | Some 0 -> 0
  | Some position ->
      (match List.nth_opt entries (position - 1) with
       | Some (Category_header _) -> 1
       | Some (Lane_row _) | None -> 0)
type identity = {row_id:string;target:selection;installation_id:string option}
let identity (row : row) =
  let installation_id=match row.selection with
    | Declaration _ -> (match row.state with
        | Package_state {declaration=Some (Valid value);_} -> Some value.installation_id
        | Package_state {declaration=Some (Invalid _ | Absent | Unobserved) | None;_}
        | Exact_state _ | Browser_clients _ | Machine_state _ -> None)
    | Exact _ | Browser _ | Machine _ | Manual_instance _ -> None in
  {row_id=row.id;target=row.selection;installation_id}
let identity_matches selected row =
  let current=identity row in
  selected.row_id=current.row_id && selected.target=current.target
    && selected.installation_id=current.installation_id
let find_identity selected rows = List.find_opt (identity_matches selected) rows
let identity_index selected rows = List.find_index (identity_matches selected) rows

(* Every sentence of the reading is written in both screen languages here;
   [ko] picks one. Text the server sent (a refusal detail, a declaration
   error) is drawn as it came. *)
let say ko korean english = if ko then korean else english
let clause_gap ko = if ko then " · " else "; "

let family_label ~ko = function
  | Exact _ -> say ko "정확 출력" "Exact-output"
  | Browser _ -> say ko "브라우저" "Browser"
  | Machine _ -> say ko "머신" "Machines"
  | Declaration _ | Manual_instance _ -> say ko "패키지" "Packages"
let phase ~ko = function
  | Attached -> say ko "연결" "attached"
  | Observing -> say ko "관측 중" "observing"
  | Failed detail -> say ko "실패: " "failed: " ^ detail
  | Detaching -> say ko "정리 중" "cleanup pending"
  | Detached -> say ko "종료 기록" "detached history"
let instance_summary ~ko (item : instance) =
  (match item.presence with
   | Live -> say ko "현재 " "live "
   | Retained -> say ko "보존 " "retained ")
  ^ phase ~ko item.phase
let application_summary ~ko : Masc.Lane_addon_application.t -> string = function
  | Starting_worker -> say ko "워커 시작 대기" "worker startup pending"
  | Cleaning_workers -> say ko "워커 정리 중" "worker cleanup pending"
  | Applied id -> say ko "워커 실행 중: " "worker running: " ^ id
  | Inactive -> say ko "워커 정리 확인" "worker cleanup confirmed"
  | Failed messages -> say ko "적용 실패: " "application failed: " ^ String.concat "; " messages
  | Unknown messages -> say ko "적용 미확인: " "application unknown: " ^ String.concat "; " messages
let declaration_summary ~ko = function
  | Valid value ->
      (if value.enabled then say ko "켜짐으로 설정" "configured on"
       else say ko "꺼짐으로 설정" "configured off")
      ^ clause_gap ko ^ application_summary ~ko value.application
  | Invalid _ -> say ko "선언 오류" "declaration invalid"
  | Absent -> say ko "선언 파일 없음" "declaration absent"
  | Unobserved -> say ko "선언 미관측" "declaration not observed"
let browser_switch_line ~ko =
  say ko "브라우저 소스는 browser-<source> 패키지 행에서 켜고 끕니다: Enter, Space, s 순서."
    "A source is switched on or off from its browser-<source> package row: Enter, then Space, then s."
let browser_reading_label ~ko observed = function
  | Browser_observed value -> observed value
  | Browser_addon_absent -> say ko "브라우저 플러그인 선언 없음" "no browser Add-on"
  | Browser_addon_off -> say ko "브라우저 플러그인 꺼짐" "browser Add-on switched off"
  | Browser_addon_not_running ->
      say ko "브라우저 플러그인 켜짐 선언 · 실행 안 됨" "browser Add-on declared on, not running"
  | Browser_addon_unavailable detail ->
      say ko "브라우저 플러그인 조회 실패: " "browser Add-on unavailable: " ^ detail
let machine_activity_label ~ko = function
  | Machine_enabled -> say ko "켜짐" "on"
  | Machine_disabled -> say ko "꺼짐 · 머신 상태 보존" "off; machine state retained"
  | Machine_unobserved -> say ko "활동 미관측" "activity unavailable"
let machine_publication_label ~ko = function
  | No_screen -> say ko "게시된 화면 없음" "no screen published"
  | Stable -> say ko "화면 안정" "screen stable"
  | Running -> say ko "머신 실행 중" "machine running"
  | Publication_unavailable -> say ko "워커 관측 불가" "worker observation unavailable"
let row_summary ~ko (row : row) = match row.state with
  | Exact_state (Disabled _) -> say ko "꺼짐 · 후보 보존" "off; candidates retained"
  | Exact_state (Unconfigured _) -> say ko "미설정" "unconfigured"
  | Exact_state (Registry_unavailable _) -> say ko "레지스트리 조회 불가" "registry unavailable"
  | Exact_state (Configured c) ->
      if c.admitted_slots=[] && c.cli_slots=[] then say ko "수락된 슬롯 없음" "no admitted slots"
      else if Option.is_some c.admission_error then say ko "실행 준비 오류" "admission issue"
      else
        Printf.sprintf (if ko then "수락된 슬롯 %d개" else "%d admitted slots")
          (List.length c.admitted_slots + List.length c.cli_slots)
  | Browser_clients reading ->
      browser_reading_label ~ko
        (Printf.sprintf (if ko then "연결된 클라이언트 %d개" else "%d connected clients"))
        reading
  | Machine_state (activity,publication) ->
      machine_activity_label ~ko activity ^ clause_gap ko ^ machine_publication_label ~ko publication
  | Package_state {declaration;instances} ->
      let declared = match declaration with
        | None -> say ko "수동 연결" "manual attachment"
        | Some value -> declaration_summary ~ko value in
      declared ^ " · " ^ (match instances with
        | [] -> say ko "관측된 워커 없음" "no worker observed"
        | values -> String.concat "; " (List.map (instance_summary ~ko) values))

module Standing = Masc_tui_lane_standing

let instance_failed (item : instance) = match item.phase with
  | Failed _ -> true
  | Attached | Observing | Detaching | Detached -> false
(* Without a usable declaration, the workers alone say how the row stands.
   [attached] is what a live attached worker means: ready for a manual
   attachment, changing for one whose declaration was removed and so is
   being detached. A cleanup in progress is changing wherever its record
   lives; a retained worker is no longer running here. *)
let instances_standing ~attached ~none (instances : instance list) =
  if List.exists (fun (item : instance) ->
      item.presence = Live && List.mem item.phase [ Attached; Observing ]) instances then attached
  else if List.exists (fun (item : instance) -> item.phase = Detaching) instances then Standing.Changing
  else match instances with [] -> none | _ :: _ -> Standing.Off
let application_standing : Masc.Lane_addon_application.t -> Standing.t = function
  | Applied _ -> Standing.Ready
  | Starting_worker | Cleaning_workers -> Standing.Changing
  | Inactive -> Standing.Off
  | Failed _ -> Standing.Failing
  | Unknown _ -> Standing.Unobserved
(* Something switched off that still has work in flight is changing, not
   off: the operator would otherwise read it as already stopped. *)
let row_standing (row : row) = match row.state with
  | Exact_state (Unconfigured _) -> Standing.Not_set_up
  | Exact_state (Disabled _) -> Standing.Off
  | Exact_state (Registry_unavailable _) -> Standing.Unobserved
  | Exact_state (Configured c) ->
      if c.admitted_slots=[] && c.cli_slots=[] then Standing.Failing
      else if Option.is_some c.admission_error then Standing.Failing
      else Standing.Configured
  | Browser_clients (Browser_observed connected) ->
      if connected > 0 then Standing.Ready else Standing.Waiting
  (* With no observation, a lane no browser Add-on serves needs one set up;
     one whose Add-ons are all switched off is off; one whose Add-on is
     declared on and not running waits for it; one whose Add-on cannot be
     read is failing. *)
  | Browser_clients Browser_addon_absent -> Standing.Not_set_up
  | Browser_clients Browser_addon_off -> Standing.Off
  | Browser_clients Browser_addon_not_running -> Standing.Waiting
  | Browser_clients (Browser_addon_unavailable _) -> Standing.Failing
  | Machine_state (Machine_disabled, Running) -> Standing.Changing
  | Machine_state (Machine_disabled, (No_screen | Stable | Publication_unavailable)) -> Standing.Off
  | Machine_state (Machine_unobserved, _) -> Standing.Unobserved
  | Machine_state (Machine_enabled, (Stable | Running)) -> Standing.Ready
  | Machine_state (Machine_enabled, No_screen) -> Standing.Waiting
  | Machine_state (Machine_enabled, Publication_unavailable) -> Standing.Failing
  | Package_state {declaration;instances} ->
      (* A failed worker is what the operator has to see, whatever the
         declaration says about the others. *)
      if List.exists instance_failed instances then Standing.Failing
      else match declaration with
        | Some (Valid value) -> application_standing value.application
        | Some (Invalid _) -> Standing.Failing
        | Some Unobserved -> Standing.Unobserved
        | Some Absent -> instances_standing ~attached:Standing.Changing ~none:Standing.Not_set_up instances
        | None -> instances_standing ~attached:Standing.Ready ~none:Standing.Off instances
(* An exact row's run observation can say more than its admission: a lane
   whose latest runs fail needs attention, and one switched off may still be
   finishing runs. Kept beside [row_summary_in], which writes the same
   observation, so the mark and the text read one capture. *)
let exact_standing (admission : Standing.t) (lane : Masc.Tui_decode.standalone_lane) =
  match lane.sl_status with
  | Masc.Tui_decode.Standalone_degraded -> Standing.Failing
  | Masc.Tui_decode.Standalone_off ->
      if lane.sl_running_count > 0 then Standing.Changing else admission
  | Masc.Tui_decode.Standalone_unavailable ->
      (match admission with
       | Standing.(Failing | Not_set_up | Off) -> admission
       | Standing.(Ready | Configured | Waiting | Changing | Unobserved) -> Standing.Unobserved)
  | Masc.Tui_decode.(Standalone_running | Standalone_idle | Standalone_no_retained_observation) -> admission
let row_standing_in (snapshot : snapshot) (row : row) =
  let admission = row_standing row in
  match row.selection with
  | Exact target ->
      (match List.find_opt (fun (lane : Masc.Tui_decode.standalone_lane) ->
           Standalone_lane.equal lane.sl_lane target) snapshot.exact_snapshot.sls_lanes with
       | None -> admission
       | Some lane -> exact_standing admission lane)
  | Browser _ | Machine _ | Declaration _ | Manual_instance _ -> admission

(* How a standing reads on a page: a failure is a failure, what the operator
   still has to wait for or set up needs attention, and what is off or unseen
   recedes. *)
let standing_tone : Standing.t -> L.tone = function
  | Standing.Failing -> L.Failure
  | Standing.(Waiting | Changing | Not_set_up) -> L.Attention
  | Standing.(Off | Unobserved) -> L.Quiet
  | Standing.Ready -> L.Plain
  | Standing.Configured -> L.Info

let worker_tone (item : instance) = match item.phase with
  | Failed _ -> L.Failure
  | Detaching -> L.Attention
  | Detached -> L.Quiet
  | Attached | Observing -> L.Plain
let instance_lines ~ko (item : instance) =
  let t = say ko in
  [L.fact (t "인스턴스" "Instance") item.instance_id; L.fact "Incarnation" item.incarnation;
   L.fact (t "실행" "Run") item.run_id;
   L.fact (t "패키지" "Package") (item.package_id ^ " · " ^ item.package_revision);
   L.fact ~tone:(worker_tone item) (t "워커" "Worker") (instance_summary ~ko item)]
  @ (match item.applied_revision with
     | None -> []
     | Some revision ->
       [L.fact (t "적용된 선언 revision" "Applied declaration revision") revision])
let refused_cli_slots_line ~ko refused =
  L.fact ~tone:L.Attention (say ko "거절된 CLI 슬롯" "Refused CLI slots") (String.concat ", " refused)
let refused_cli_slot_lines ~ko
    (values : Masc.Keeper_lane_cli_oneshot.refused_slot list)
  =
  match values with
  | [] -> []
  | values ->
    [ refused_cli_slots_line ~ko
        (List.map
           (fun (r : Masc.Keeper_lane_cli_oneshot.refused_slot) ->
              r.slot ^ " (" ^ Runtime.refusal_to_string r.refusal ^ ")")
           values)
    ]

let detail_lines ~ko (row : row) =
  let t = say ko in
  [L.fact (t "종류" "Surface") (family_label ~ko row.selection);
   L.fact (t "식별자" "Identity") row.id;
   L.fact ~tone:(standing_tone (row_standing row)) (t "관측" "Reading") (row_summary ~ko row)]
  @ (match row.selection with
     | Exact _ ->
       [L.note ~tone:L.Quiet
          (t "정확 출력의 실행 준비와 보존된 실행 근거는 따로 읽습니다."
             "Exact-output admission and retained run evidence are separate readings.")]
     | Browser _ ->
       [L.note ~tone:L.Quiet
          (t "이 행을 열면 선택한 브라우저 백엔드를 읽습니다. 새 세션을 열지 않습니다."
             "Opening this row reads the selected browser backend; it does not open a new session.")]
     | Machine _ ->
       [L.note ~tone:L.Quiet
          (t "활동 설정과 마지막으로 게시된 화면은 따로 읽습니다."
             "Activity configuration and the last published screen are separate readings.")]
     | Declaration path -> [L.fact "TOML" path]
     | Manual_instance _ ->
       [L.note ~tone:L.Quiet
          (t "선언 파일이 없는 수동 연결입니다." "No declaration file; this is a manual attachment.")])
  @ (match row.state with
     | Exact_state (Disabled c) ->
         [L.note ~tone:L.Quiet
            (t "새 작업은 꺼져 있습니다. 이미 받은 실행은 확보한 후보로 끝냅니다."
               "New work is off; accepted runs finish with their acquired candidates.");
          L.fact (t "선언된 HTTP 슬롯" "Declared HTTP slots") (String.concat ", " c.declared_slots);
          L.fact (t "선언된 CLI 슬롯" "Declared CLI slots") (String.concat ", " c.declared_cli_slots)]
     | Exact_state (Configured c) ->
         let refused_cli =
           List.filter
             (fun slot -> not (List.mem slot c.cli_slots))
             c.declared_cli_slots
         in
         let refused_cli_lines =
           match row.selection, refused_cli with
           | _, [] -> []
           | Exact lane, refused ->
             let partitioned =
               Masc.Keeper_lane_cli_oneshot.partition_cli_slots
                 ~lane:(Runtime.requirement_of_exact_lane lane)
                 refused
             in
             (match partitioned.refused_cli_slots with
              | _ :: _ as typed_refusals -> refused_cli_slot_lines ~ko typed_refusals
              | [] -> [refused_cli_slots_line ~ko refused])
           | (Browser _ | Machine _ | Declaration _ | Manual_instance _), refused ->
             [refused_cli_slots_line ~ko refused]
         in
         [L.fact (t "선언된 HTTP 슬롯" "Declared HTTP slots") (String.concat ", " c.declared_slots);
          L.fact (t "선언된 CLI 슬롯" "Declared CLI slots") (String.concat ", " c.declared_cli_slots)]
         @ (match c.dropped_slots with
            | [] -> []
            | values ->
              [L.fact ~tone:L.Attention (t "탈락한 HTTP 슬롯" "Dropped HTTP slots")
                 (String.concat ", " values)])
         @ refused_cli_lines
         @ (match c.admission_error with
            | None -> []
            | Some detail -> [L.fact ~tone:L.Failure (t "실행 준비 오류" "Admission") detail])
     | Exact_state (Unconfigured detail | Registry_unavailable detail) -> [L.note ~tone:L.Attention detail]
     | Browser_clients _ -> [L.note (browser_switch_line ~ko)]
     | Machine_state _ ->
         [L.note ~tone:L.Quiet
            (t "끄면 새 실행과 입력을 거절합니다. 기존 머신 상태와 체크포인트는 보존됩니다."
               "Off refuses new execution and input; existing machine state and checkpoints are retained.");
          L.note
            (t "기능 목록에서 이 머신을 고르고 Space 를 누르면 활동 설정이 열립니다."
               "Select this machine in All Lanes and press Space for activity settings.")]
     | Package_state {declaration;instances} ->
         (match declaration with
          | None -> []
          | Some (Valid value) ->
              [L.fact (t "설치" "Installation") value.installation_id;
               L.fact (t "실행" "Run") value.run_id;
               L.fact (t "패키지" "Package") (value.package_id ^ " · " ^ value.title);
               L.fact (t "목표 revision" "Desired revision") value.desired_revision;
               L.fact (t "원본 revision" "Source revision") value.source_revision]
          | Some (Invalid messages) ->
              List.map
                (fun message -> L.fact ~tone:L.Failure (t "선언 오류" "Declaration error") message)
                messages
          | Some Absent ->
              [L.note ~tone:L.Attention
                 (t "디렉터리를 끝까지 읽었지만 선언이 없습니다. 보존된 워커 상태는 별개입니다."
                    "No declaration was observed in the complete directory reading; retained worker state is separate.")]
          | Some Unobserved ->
              [L.note ~tone:L.Attention
                 (t "디렉터리를 다 읽지 못해 선언이 없다고 단정할 수 없습니다."
                    "Directory reading is incomplete; declaration absence is not established.")])
         @ List.concat_map (instance_lines ~ko) instances)

(* A package row's exact outputs, first and the rest, with the installation
   id their runtime.toml tables are named by. Only a valid declaration that
   lists one has any. *)
let exact_outputs (row : row) = match row.state with
  | Package_state {declaration = Some (Valid value); _} -> (match value.exact_outputs with
      | [] -> None
      | first :: rest -> Some (value.installation_id, first, rest))
  | Package_state {declaration = Some (Invalid _ | Absent | Unobserved) | None; _}
  | Exact_state _ | Browser_clients _ | Machine_state _ -> None

let selected_exact_output ~selected (row : row) =
  Option.map (fun (installation_id, first, rest) ->
    let chosen = Option.bind selected (fun name ->
      List.find_opt (fun (o : exact_output) -> String.equal o.output name) (first :: rest)) in
    installation_id, Option.value chosen ~default:first) (exact_outputs row)

let step_exact_output ~selected ~direction (row : row) =
  Option.map (fun (installation_id, first, rest) ->
    let outputs = Array.of_list (first :: rest) in
    let current = match selected_exact_output ~selected row with
      | Some (_, chosen) ->
          Option.value ~default:0
            (Array.find_index (fun (o : exact_output) -> String.equal o.output chosen.output) outputs)
      | None -> 0 in
    let next = max 0 (min (Array.length outputs - 1) (current + direction)) in
    installation_id, outputs.(next).output) (exact_outputs row)

let exact_output_table_path ~installation_id (o : exact_output) =
  Result.map (fun addon -> Runtime_schema.exact_lane_table_path (Runtime_schema.Addon addon))
    (Runtime_schema.addon_lane ~declaration_id:installation_id ~output:o.output)

let exact_output_state ~ko (o : exact_output) =
  (match o.configuration with
   | Configured c -> (match c.admitted_slots @ c.cli_slots with
       | [] -> say ko "연결됨 · 수락된 슬롯 없음" "bound, no admitted slot"
       | slots -> say ko "연결됨: " "bound: " ^ String.concat ", " slots)
   | Disabled _ -> say ko "꺼짐" "off"
   | Unconfigured _ -> say ko "연결 안 됨" "unbound"
   | Registry_unavailable detail -> say ko "조회 불가: " "unavailable: " ^ detail)
  ^ (match o.source with
     | Declared -> ""
     | Table_only ->
       say ko " · 패키지가 선언하지 않은 출력" " · the package declares no such output")

let exact_output_lines ~ko ~selected (row : row) =
  match selected_exact_output ~selected row, exact_outputs row with
  | Some (_, chosen), Some (_, first, rest) ->
      say ko "정확 출력 ([ / ] 고르기, e 는 그 runtime.toml 표를 엽니다):"
        "Exact outputs ([ / ] choose, e opens its runtime.toml table):"
      :: List.map (fun (o : exact_output) ->
           (if String.equal o.output chosen.output then "› " else "  ") ^ o.output ^ " · " ^ exact_output_state ~ko o)
           (first :: rest)
  | None, _ | _, None -> []

let reading_notices ~ko (snapshot : snapshot) =
  (if snapshot.package_read.complete then []
   else
     [say ko "패키지 목록을 다 읽지 못했습니다. 빠진 항목이 제거됐다는 뜻은 아닙니다."
        "Package inventory is incomplete; missing entries do not prove removal."])
  @ (if snapshot.package_read.owner_present then []
     else
       [say ko "패키지 런타임 owner 가 관측되지 않았습니다. 선언과 보존된 바인딩은 그대로 나열합니다."
          "Package runtime owner has not been observed; declarations and retained bindings remain listed."])

let overview_notices ~ko (snapshot : snapshot) =
  reading_notices ~ko snapshot
  @ (match snapshot.package_read.issues with
     | [] -> []
     | issues ->
       [Printf.sprintf
          (if ko then "목록 읽기 문제 %d건 · i: 자세히" else "%d inventory issues · i: details")
          (List.length issues)])
let snapshot_notices ~ko (snapshot : snapshot) =
  reading_notices ~ko snapshot
  @ List.map (fun (path,message) -> path ^ ": " ^ message) snapshot.package_read.issues

let row_summary_in ~ko (snapshot : snapshot) (row : row) =
  let admission = row_summary ~ko row in
  match row.selection with
  | Exact target ->
      (match List.find_opt (fun (lane : Masc.Tui_decode.standalone_lane) ->
           Standalone_lane.equal lane.sl_lane target) snapshot.exact_snapshot.sls_lanes with
       | None -> admission
       | Some lane ->
           let observation = match lane.sl_status with
             | Masc.Tui_decode.Standalone_off ->
               Printf.sprintf (if ko then "꺼짐 · %d건 마무리 중" else "off · %d finishing")
                 lane.sl_running_count
             | Masc.Tui_decode.Standalone_running ->
               Printf.sprintf (if ko then "%d건 실행 중" else "%d running") lane.sl_running_count
             | Standalone_idle -> say ko "대기" "idle"
             | Standalone_degraded -> say ko "주의 필요" "needs attention"
             | Standalone_unavailable -> say ko "사용 불가" "unavailable"
             | Standalone_no_retained_observation -> say ko "보존된 실행 없음" "no retained runs" in
           observation ^ " · " ^ admission)
  | Browser _ | Machine _ | Declaration _ | Manual_instance _ -> admission
