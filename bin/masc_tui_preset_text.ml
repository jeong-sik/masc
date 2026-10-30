(* The words a /preset command leaves in the chat pane. Pure, so a test can
   read the exact lines an operator sees for a listing, a save, and a restore
   report — including the one thing a restore must never hide: what was
   skipped, and that runtime.toml did or did not commit. *)

module D = Masc.Tui_decode

let counts (m : D.preset_manifest) =
  Printf.sprintf
    "overrides %d · keepers %d · assignments %d · lanes %d"
    m.D.pm_override_count
    (List.length m.D.pm_keepers)
    m.D.pm_assignment_count
    m.D.pm_lane_count
;;

let unreadable_only_line = "읽을 수 있는 프리셋이 없습니다 — 아래 줄이 이유입니다"

let listing_lines (snapshot : D.presets_snapshot) =
  let presets =
    match snapshot.D.pss_presets with
    (* Presets whose manifest did not read are still presets; saying "no
       presets yet" beside their rows would send the operator to save one
       when the fix is to look at why the manifest is unreadable. *)
    | [] when snapshot.D.pss_unreadable <> [] -> [ unreadable_only_line ]
    | [] ->
      [ "no presets yet — /preset save <name> [description] snapshots the live state" ]
    | presets ->
      Printf.sprintf "presets (%d):" (List.length presets)
      :: List.map
           (fun (m : D.preset_manifest) ->
             let description =
               if String.equal m.D.pm_description "" then "" else " — " ^ m.D.pm_description
             in
             Printf.sprintf "  %s  %s%s  (%s)" m.D.pm_name (counts m) description m.D.pm_created_at)
           presets
  in
  let unreadable =
    List.map
      (fun (name, reason) -> Printf.sprintf "  ! %s — %s" name reason)
      snapshot.D.pss_unreadable
  in
  presets @ unreadable
;;

(* A reason names what to do at its end, so cutting the row at the pane
   width hides the part the operator needs. Each reason is folded at spaces
   instead; continuation rows are indented under the name. *)
let unreadable_rows ~max_cells unreadable =
  let budget = max 1 (max_cells - 2) in
  List.concat_map
    (fun (name, reason) ->
      match
        Masc_tui_message_layout.wrap_words ~max_cells:budget
          (Printf.sprintf "! %s — %s" name reason)
      with
      | [] -> []
      | first :: rest -> first :: List.map (fun row -> "  " ^ row) rest)
    unreadable
;;

let saved_line (m : D.preset_manifest) =
  Printf.sprintf "saved preset %s — %s" m.D.pm_name (counts m)
;;

let text ~ko korean english = if ko then korean else english

let part_lines ~ko ~label ~timing (part : D.preset_part) =
  let head =
    Printf.sprintf
      (if ko then "%s (%s) · 적용 %d · 제외 %d" else "%s (%s) · applied %d · skipped %d")
      label
      timing
      (List.length part.D.pp_applied)
      (List.length part.D.pp_skipped)
  in
  head
  :: List.map (fun (key, reason) -> Printf.sprintf "  - %s: %s" key reason) part.D.pp_skipped
;;

let runtime_lines ~ko = function
  | D.Preset_runtime_unchanged ->
    [ text ~ko "런타임 · 변경 없음" "Runtime · unchanged" ]
  | D.Preset_runtime_committed commit ->
    [ text ~ko "런타임 · 파일 변경 적용됨" "Runtime · file changes committed" ]
    @ (match commit.D.prc_durability with
       | Runtime.Durable -> []
       | Runtime.Durability_unconfirmed { detail } ->
         [ text ~ko "  ! 적용됐지만 디스크 저장 내구성은 미확인 — " "  ! Applied; disk durability unconfirmed — " ^ detail
         ; text ~ko "    다시 복원하기 전 저장소를 확인하세요. 재복원은 이전 백업을 덮어씁니다."
             "    Check storage before restoring again; another restore replaces the backup."
         ])
    @ List.map
        (function Runtime.Config_lock_release_unconfirmed detail ->
          text ~ko "  ! 런타임 잠금 해제 미확인 — " "  ! Runtime lock release unconfirmed — " ^ detail)
        commit.D.prc_lock_warnings
    @ (match commit.D.prc_registry with
       | D.Preset_registry_applied D.Preset_registry_runtime_bindings ->
         [ text ~ko "정확 출력 레인 · 런타임 바인딩 적용" "Exact lanes · runtime bindings applied" ]
       | D.Preset_registry_applied D.Preset_registry_replacement_catalog ->
         [ text ~ko "정확 출력 레인 · 교체 목록 적용" "Exact lanes · replacement catalog applied" ]
       | D.Preset_registry_unpublished ->
         [ text ~ko "  ! 정확 출력 레인 · 게시되지 않음, 재시작 필요" "  ! Exact lanes · unpublished; restart required" ]
       | D.Preset_registry_kept reason ->
         [ text ~ko "  ! 정확 출력 레인 · 이전 목록 유지, 다음 시작에 파일을 게시할 수 없음 — "
             "  ! Exact lanes · previous registry retained; committed file cannot publish at next start — " ^ reason ])
  | D.Preset_runtime_failed reason -> [ text ~ko "런타임 · 실패 — " "Runtime · failed — " ^ reason ]
;;

let default_prompt_summary ~ko = function
  | Masc.Prompt_preset.Defaults_unknown -> [ text ~ko "기본 프롬프트 · 저장된 비교 기준 없음" "Default prompts · no saved comparison" ]
  | Masc.Prompt_preset.Defaults_match -> [ text ~ko "기본 프롬프트 · 저장 당시와 동일" "Default prompts · match saved version" ]
  | Masc.Prompt_preset.Defaults_differ changes ->
      [ Printf.sprintf (if ko then "기본 프롬프트 · 차이 %d건" else "Default prompts · %d changes") (List.length changes)
      ; text ~ko "  복원 후에도 현재 기본값을 사용합니다" "  Current defaults remain in use after restore"
      ]

let default_prompt_lines ~ko defaults =
  default_prompt_summary ~ko defaults
  @ (match defaults with
    | Masc.Prompt_preset.Defaults_unknown | Masc.Prompt_preset.Defaults_match -> []
    | Masc.Prompt_preset.Defaults_differ changes ->
      List.map (fun (key, saved, current) ->
           let change = match saved, current with
             | None, Some _ -> text ~ko "추가" "added"
             | Some _, None -> text ~ko "없음" "removed"
             | Some _, Some _ -> text ~ko "변경" "changed"
             | None, None -> text ~ko "확인 불가" "unknown" in
           Printf.sprintf "  %s · %s" change key) changes)
;;

let preserved_settings_lines ~ko = function
  | [] -> []
  | settings ->
    text ~ko "저장되지 않은 레인 요청 설정 · 현재 값 유지" "Unsaved lane request settings · current values retained"
    :: List.map (fun (lane, setting) ->
        "  " ^ lane ^ "." ^ (match setting with
          | D.Preset_max_output_tokens -> "max_output_tokens"
          | D.Preset_thinking -> "thinking")) settings
;;

let restore_lines ~ko (report : D.preset_restore_report) =
  (Printf.sprintf
     (if ko then "%s 복원 결과 · 직전 설정 백업: %s" else "%s restore result · previous settings backup: %s")
     report.D.prr_restored
     report.D.prr_autosave
   :: part_lines ~ko ~label:(text ~ko "프롬프트 재정의" "Prompt overrides")
        ~timing:(text ~ko "즉시 반영" "immediate") report.D.prr_prompt_overrides)
  @ part_lines ~ko ~label:(text ~ko "키퍼 지시문" "Keeper instructions")
      ~timing:(text ~ko "각 키퍼의 다음 시작/턴" "each Keeper's next start/turn") report.D.prr_instructions
  @ runtime_lines ~ko report.D.prr_runtime
  @ List.map (fun (lane, reason) -> text ~ko "레인 복원 제외 · " "Lane not restored · " ^ lane ^ ": " ^ reason) report.D.prr_skipped_lanes
  @ List.map (fun (keeper, reason) -> text ~ko "런타임 배정 복원 제외 · " "Runtime assignment not restored · " ^ keeper ^ ": " ^ reason) report.D.prr_skipped_assignments
  @ default_prompt_lines ~ko report.D.prr_default_prompts
  @ preserved_settings_lines ~ko report.D.prr_preserved_lane_settings
;;

(* The list gives the name priority; counts are repeated in the detail. *)
(* The row the Config pane draws where its list would be, for a read that
   came back with no preset to list. It said "s 로 지금 상태를 저장하세요", but
   on Config [s] opens Resources: the pane's save key is [n], the one its
   footer names. And it said so beside the unreadable rows the chat listing
   already refuses to call an empty store. *)
let pane_empty_line ~ko (snapshot : D.presets_snapshot) =
  match snapshot.D.pss_presets, snapshot.D.pss_unreadable with
  | _ :: _, _ -> None
  | [], _ :: _ -> Some (text ~ko unreadable_only_line "No readable presets · see the reasons below")
  | [], [] -> Some (text ~ko "프리셋 없음 · n:현재 상태 저장" "No presets · n:save current state")

let pane_row ~ko ~max_cells (m : D.preset_manifest) =
  let summary =
    Printf.sprintf
      (if ko then "재정의 %d · 지시문 %d · 배정 %d · 레인 %d"
       else "overrides %d · instructions %d · assignments %d · lanes %d")
      m.D.pm_override_count (List.length m.D.pm_keepers)
      m.D.pm_assignment_count m.D.pm_lane_count
  in
  let summary_width = Masc_tui_message_layout.display_width summary + 3 in
  let name = Masc.Tui_terminal_text.sanitize_terminal_text m.D.pm_name in
  if summary_width + Masc_tui_message_layout.display_width name > max_cells then
    Masc_tui_message_layout.fit_middle (max 1 max_cells) name
  else
    name ^ "   " ^ summary
;;

(* The detail below the list: what the selected preset holds, and the last
   restore report this session saw. *)
(* What the preset actually holds, once the server has answered for it. The
   manifest above says how many; this says which and how big. *)
let comparison_lines ~ko (d : D.preset_detail) =
  [ text ~ko "▸ 현재 설정과 비교" "▸ Comparison with current settings"
  ; (match d.D.pd_settings_match with
     | D.Preset_settings_match -> text ~ko "설정 · 저장 당시와 동일" "Settings · match saved version"
     | D.Preset_settings_differ -> text ~ko "설정 · 현재 설정과 다름" "Settings · differ from current"
     | D.Preset_settings_unavailable reason -> text ~ko "설정 비교 불가 · " "Settings comparison unavailable · " ^ reason)
  ]
  @ default_prompt_summary ~ko d.D.pd_default_prompts
  @ (match d.D.pd_skipped_lanes with
     | [] -> []
     | lanes ->
       [Printf.sprintf (if ko then "! 복원 제외 레인 %d개" else "! Lanes not restored: %d")
          (List.length lanes)])
  @ (match d.D.pd_preserved_lane_settings with
     | [] -> []
     | settings ->
       [Printf.sprintf
          (if ko then "미저장 레인 요청 설정 %d개 · 현재 값 유지"
           else "Unsaved lane request settings: %d · current values retained")
          (List.length settings)])
  @ List.map (fun (lane, reason) ->
      text ~ko "! 레인 복원 제외 · " "! Lane not restored · " ^ lane ^ ": " ^ reason)
      d.D.pd_skipped_lanes
;;

let saved_contents_lines ~ko (d : D.preset_detail) =
  let sized label rows =
    match rows with
    | [] -> []
    | rows ->
      [ Printf.sprintf
          "%s %s"
          label
          (String.concat ", "
             (List.map (fun (name, bytes) -> Printf.sprintf "%s(%dB)" name bytes) rows))
      ]
  in
  [ ""; text ~ko "▸ 저장된 내용" "▸ Saved contents" ]
  @ sized (text ~ko "프롬프트 재정의" "Prompt overrides") d.D.pd_overrides
  @ sized (text ~ko "키퍼 지시문" "Keeper instructions") d.D.pd_instructions
  @ (match d.D.pd_assignments with
     | [] -> []
     | rows ->
       [ text ~ko "배정 " "Assignments "
         ^ String.concat ", "
             (List.map (fun (keeper, runtime) -> keeper ^ "→" ^ runtime) rows)
       ])
  @ (match d.D.pd_lanes with
     | [] -> []
     | lanes -> [ text ~ko "레인 " "Lanes " ^ String.concat ", " lanes ])
  @ (match d.D.pd_default_prompts with
     | Masc.Prompt_preset.Defaults_differ _ -> default_prompt_lines ~ko d.D.pd_default_prompts
     | Masc.Prompt_preset.Defaults_unknown | Masc.Prompt_preset.Defaults_match -> [])
  @ preserved_settings_lines ~ko d.D.pd_preserved_lane_settings
  @ [ ""; text ~ko "▸ 현재 프롬프트 파일과 저장 위치" "▸ Current prompt files and preset directory" ]
  @ (match d.D.pd_prompt_files with
     | [] -> []
     | files ->
       List.concat_map (fun (key, path, source) ->
         [ key ^ " · " ^ (match source with
             | D.Prompt_override -> text ~ko "재정의" "override"
             | D.Prompt_file -> text ~ko "기본값" "default"
             | D.Prompt_missing -> text ~ko "없음" "missing")
         ; "  " ^ (match path with Some path -> path | None -> text ~ko "등록된 파일 없음" "No file registered")
         ]) files)
  @ [ text ~ko "저장 위치" "Preset directory"; "  " ^ d.D.pd_directory ]
;;

let contents_lines ~ko d = comparison_lines ~ko d @ saved_contents_lines ~ko d

let detail_lines ~ko ~(selected : D.preset_manifest option)
      ~(detail : D.preset_detail Masc_tui_fetched.view)
      ~(report : D.preset_restore_report option) =
  let preset =
    match selected with
    | None -> [ text ~ko "선택한 프리셋이 없습니다" "No preset selected" ]
    | Some m ->
      [ text ~ko "▸ 복원 범위" "▸ Restore scope"
      ; m.D.pm_name ^ " · " ^ text ~ko "저장 " "saved " ^ m.D.pm_created_at
      ; Printf.sprintf
          (if ko then "재정의 %d · 지시문 %d · 배정 %d · 레인 %d"
           else "Overrides %d · instructions %d · assignments %d · lanes %d")
          m.D.pm_override_count (List.length m.D.pm_keepers)
          m.D.pm_assignment_count m.D.pm_lane_count
      ]
      @ (if String.equal m.D.pm_description "" then [] else [m.D.pm_description])
      @ [ text ~ko "프롬프트 재정의 · 키퍼 지시문 · 런타임 배정과 레인"
            "Prompt overrides · Keeper instructions · runtime assignments and lanes"
        ; text ~ko "현재 설정은 _autosave에 백업 · 다음 복원은 이 백업을 덮어씀"
            "Current settings are backed up to _autosave · the next restore replaces it"
        ]
  in
  (* Four states, and the type makes the pane answer for each. Two of them
     used to be the same silence. *)
  let comparison, contents =
    match detail with
    | Masc_tui_fetched.Ready d ->
      ([ "" ] @ comparison_lines ~ko d, saved_contents_lines ~ko d)
    | Masc_tui_fetched.Loading -> [ ""; text ~ko "내용을 읽는 중…" "Loading contents…" ], []
    (* A failed refresh keeps the contents it read last, under a line that
       says they are the last read. *)
    | Masc_tui_fetched.Stale (d, reason) ->
      ([ ""; text ~ko "새로고침 실패 · 마지막으로 읽은 내용 — " "Refresh failed · last read contents — " ^ reason ]
       @ comparison_lines ~ko d, saved_contents_lines ~ko d)
    | Masc_tui_fetched.Failed reason -> [ ""; text ~ko "내용을 읽지 못했습니다 — " "Could not read contents — " ^ reason ], []
    | Masc_tui_fetched.Absent -> [], []
  in
  let report = match report with
    | None -> []
    | Some report -> "" :: restore_lines ~ko report
  in
  let manifest = match selected with
    | None -> []
    | Some m ->
      [ ""; text ~ko "▸ 목록에 기록된 항목" "▸ Items in manifest"
      ; text ~ko "프롬프트 재정의 " "Prompt overrides " ^ String.concat ", " m.D.pm_override_keys
      ; text ~ko "키퍼 지시문 " "Keeper instructions " ^ String.concat ", " m.D.pm_keepers ]
  in
  preset @ comparison @ report @ contents @ manifest
;;

(* Clean means nothing was skipped and the commit has no warnings; the pane
   then shows the report as status rather than as an error. *)
let restore_is_clean (report : D.preset_restore_report) =
  report.D.prr_prompt_overrides.D.pp_skipped = []
  && report.D.prr_instructions.D.pp_skipped = []
  && report.D.prr_skipped_lanes = []
  && report.D.prr_skipped_assignments = []
  &&
  match report.D.prr_runtime with
  | D.Preset_runtime_failed _ -> false
  | D.Preset_runtime_unchanged -> true
  | D.Preset_runtime_committed commit -> not (D.preset_runtime_commit_needs_attention commit)
;;
