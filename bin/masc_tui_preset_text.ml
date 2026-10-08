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

let part_lines ~label (part : D.preset_part) =
  let head =
    Printf.sprintf
      "%s (%s): applied %d, skipped %d"
      label
      part.D.pp_effect
      (List.length part.D.pp_applied)
      (List.length part.D.pp_skipped)
  in
  head
  :: List.map (fun (key, reason) -> Printf.sprintf "  - %s: %s" key reason) part.D.pp_skipped
;;

let runtime_line = function
  | D.Preset_runtime_unchanged -> "runtime: unchanged — assignments and exact lanes already matched"
  | D.Preset_runtime_committed ->
    "runtime: committed — runtime.toml rewritten, assignments and exact lanes live"
  | D.Preset_runtime_failed reason -> "runtime: failed — " ^ reason
;;

let default_prompt_lines = function
  | Masc.Prompt_preset.Defaults_unknown -> [ "기본 프롬프트 · 저장된 비교 기준 없음" ]
  | Masc.Prompt_preset.Defaults_match -> [ "기본 프롬프트 · 저장 당시와 동일" ]
  | Masc.Prompt_preset.Defaults_differ changes ->
      [ Printf.sprintf "기본 프롬프트 · 차이 %d건" (List.length changes)
      ; "  복원 후에도 현재 기본값을 사용합니다"
      ]
      @ List.map (fun (key, saved, current) ->
           let change = match saved, current with
             | None, Some _ -> "추가"
             | Some _, None -> "없음"
             | Some _, Some _ -> "변경"
             | None, None -> "확인 불가" in
           Printf.sprintf "  %s · %s" change key) changes
;;

let restore_lines (report : D.preset_restore_report) =
  (Printf.sprintf
     "restored preset %s (the state before it is %s)"
     report.D.prr_restored
     report.D.prr_autosave
   :: part_lines ~label:"prompt overrides" report.D.prr_prompt_overrides)
  @ part_lines ~label:"keeper instructions" report.D.prr_instructions
  @ [ runtime_line report.D.prr_runtime ]
  @ default_prompt_lines report.D.prr_default_prompts
;;

(* One list row in the Config pane: the name, then the counts, then when it
   was saved. The description is detail, not a row. *)
(* The row the Config pane draws where its list would be, for a read that
   came back with no preset to list. It said "s 로 지금 상태를 저장하세요", but
   on Config [s] opens Resources: the pane's save key is [n], the one its
   footer names. And it said so beside the unreadable rows the chat listing
   already refuses to call an empty store. *)
let pane_empty_line (snapshot : D.presets_snapshot) =
  match snapshot.D.pss_presets, snapshot.D.pss_unreadable with
  | _ :: _, _ -> None
  | [], _ :: _ -> Some unreadable_only_line
  | [], [] -> Some "아직 프리셋이 없습니다 · n 으로 지금 상태를 저장하세요"

let pane_row (m : D.preset_manifest) =
  Printf.sprintf "%-28s %s  %s" m.D.pm_name (counts m) m.D.pm_created_at
;;

(* The detail below the list: what the selected preset holds, and the last
   restore report this session saw. *)
(* What the preset actually holds, once the server has answered for it. The
   manifest above says how many; this says which and how big. *)
let contents_lines (d : D.preset_detail) =
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
  [ (match d.D.pd_settings_match with
     | D.Preset_settings_match -> "설정 상태 · 저장 당시와 동일"
     | D.Preset_settings_differ -> "설정 상태 · 현재 설정과 다름"
     | D.Preset_settings_unavailable reason -> "설정 비교 불가 · " ^ reason)
  ]
  @ default_prompt_lines d.D.pd_default_prompts
  @ [ ""; "저장된 설정" ]
  @ sized "프롬프트" d.D.pd_overrides
  @ sized "지시문" d.D.pd_instructions
  @ (match d.D.pd_assignments with
     | [] -> []
     | rows ->
       [ "배정 "
         ^ String.concat ", "
             (List.map (fun (keeper, runtime) -> keeper ^ "→" ^ runtime) rows)
       ])
  @ (match d.D.pd_lanes with
     | [] -> []
     | lanes -> [ "레인 " ^ String.concat ", " lanes ])
  @ (match d.D.pd_prompt_files with
     | [] -> []
     | files -> [ ""; "현재 프롬프트" ]
       @ List.concat_map (fun (key, path, source) ->
         [ key ^ " · " ^ (match source with
             | D.Prompt_override -> "사용자 설정"
             | D.Prompt_file -> "기본값"
             | D.Prompt_missing -> "없음")
         ; "  " ^ (match path with Some path -> path | None -> "등록된 파일 없음")
         ]) files)
  @ [ ""; "저장 위치"; "  " ^ d.D.pd_directory ]
;;

let detail_lines ~(selected : D.preset_manifest option)
      ~(detail : D.preset_detail Masc_tui_fetched.view)
      ~(report : D.preset_restore_report option) =
  let preset =
    match selected with
    | None -> [ "선택한 프리셋이 없습니다" ]
    | Some m ->
      [ Printf.sprintf "Selected: %s · %s" m.D.pm_name (counts m)
      ; (if String.equal m.D.pm_description "" then "설명 없음" else m.D.pm_description)
      ; "저장 시각 " ^ m.D.pm_created_at
      ; (* Which prompts, not how many. A count cannot be chosen between,
           and choosing is what this pane is for. *)
        (match m.D.pm_override_keys with
         | [] -> "프롬프트 override 없음"
         | keys -> "프롬프트 override " ^ String.concat ", " keys)
      ; (match m.D.pm_keepers with
         | [] -> "지시문을 담은 keeper 없음"
         | keepers -> "지시문 " ^ String.concat ", " keepers)
      ]
  in
  (* Four states, and the type makes the pane answer for each. Two of them
     used to be the same silence. *)
  let contents =
    match detail with
    | Masc_tui_fetched.Ready d ->
      (match contents_lines d with
       | [] -> []
       | lines -> "" :: lines)
    | Masc_tui_fetched.Loading -> [ ""; "내용을 읽는 중…" ]
    (* A failed refresh keeps the contents it read last, under a line that
       says they are the last read. *)
    | Masc_tui_fetched.Stale (d, reason) ->
      [ ""; "새로고침 실패 · 마지막으로 읽은 내용입니다 — " ^ reason ] @ contents_lines d
    | Masc_tui_fetched.Failed reason -> [ ""; "내용을 읽지 못했습니다 — " ^ reason ]
    | Masc_tui_fetched.Absent -> []
  in
  match report with
  | None -> preset @ contents
  | Some report -> preset @ contents @ [ "" ] @ restore_lines report
;;

(* Clean means nothing was skipped and runtime.toml did not fail; the pane
   then shows the report as status rather than as an error. *)
let restore_is_clean (report : D.preset_restore_report) =
  report.D.prr_prompt_overrides.D.pp_skipped = []
  && report.D.prr_instructions.D.pp_skipped = []
  &&
  match report.D.prr_runtime with
  | D.Preset_runtime_failed _ -> false
  | D.Preset_runtime_unchanged | D.Preset_runtime_committed -> true
;;
