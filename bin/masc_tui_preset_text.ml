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

let listing_lines (snapshot : D.presets_snapshot) =
  let presets =
    match snapshot.D.pss_presets with
    (* Presets whose manifest did not read are still presets; saying "no
       presets yet" beside their rows would send the operator to save one
       when the fix is to look at why the manifest is unreadable. *)
    | [] when snapshot.D.pss_unreadable <> [] ->
      [ "읽을 수 있는 프리셋이 없습니다 — 아래 줄이 이유입니다" ]
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

let restore_lines (report : D.preset_restore_report) =
  (Printf.sprintf
     "restored preset %s (the state before it is %s)"
     report.D.prr_restored
     report.D.prr_autosave
   :: part_lines ~label:"prompt overrides" report.D.prr_prompt_overrides)
  @ part_lines ~label:"keeper instructions" report.D.prr_instructions
  @ [ runtime_line report.D.prr_runtime ]
;;

(* One list row in the Config pane: the name, then the counts, then when it
   was saved. The description is detail, not a row. *)
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
  sized "override" d.D.pd_overrides
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
;;

let detail_lines ~(selected : D.preset_manifest option)
      ~(detail : D.preset_detail option)
      ~(report : D.preset_restore_report option) =
  let preset =
    match selected with
    | None -> [ "선택한 프리셋이 없습니다" ]
    | Some m ->
      [ Printf.sprintf "%s · %s" m.D.pm_name (counts m)
      ; (if String.equal m.D.pm_description "" then "설명 없음" else m.D.pm_description)
      ; "저장 시각 " ^ m.D.pm_created_at
      ; (* Which prompts, not how many. A count cannot be chosen between,
           and choosing is what this pane is for. A preset saved before the
           server named them says so rather than reading as "none". *)
        (match m.D.pm_override_keys, m.D.pm_override_count with
         | Some [], _ -> "프롬프트 override 없음"
         | Some keys, _ -> "프롬프트 override " ^ String.concat ", " keys
         | None, 0 -> "프롬프트 override 없음"
         | None, n ->
           Printf.sprintf "프롬프트 override %d개 — 어느 것인지는 이 프리셋에 적혀 있지 않습니다" n)
      ; (match m.D.pm_keepers with
         | [] -> "지시문을 담은 keeper 없음"
         | keepers -> "지시문 " ^ String.concat ", " keepers)
      ]
  in
  let contents =
    match selected, detail with
    | Some m, Some d when String.equal m.D.pm_name d.D.pd_name ->
      (match contents_lines d with
       | [] -> []
       | lines -> "" :: lines)
    | Some _, _ -> [ ""; "내용을 읽는 중…" ]
    | None, _ -> []
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
