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
