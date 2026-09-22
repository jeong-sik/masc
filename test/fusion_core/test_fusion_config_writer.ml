(* Fusion_config_writer: a typed preset edit rewrites one preset region, keeps
   every other line byte-for-byte, carries in-region comments with their keys,
   and produces text that Fusion_config reads back as exactly the preset given.
   The last case runs the shipped config/runtime.toml through the writer. *)

open Alcotest

let preset_t = testable Fusion_policy.pp_preset Fusion_policy.equal_preset

let policy_of text =
  match Fusion_config.of_toml (Otoml.Parser.from_string text) with
  | Ok policy -> policy
  | Error errors ->
    failf "written text must load: %s"
      (String.concat "; " (List.map Fusion_config.config_error_message errors))
;;

let preset_of policy name =
  match Fusion_policy.find_preset policy name with
  | Some validated -> Fusion_policy.Validated_preset.preset validated
  | None -> failf "preset %s must exist" name
;;

let ok_or_fail = function
  | Ok text -> text
  | Error error -> failf "edit refused: %s" (Fusion_config_writer.error_message error)
;;

let lines text = String.split_on_char '\n' text

let index_of_line text line =
  let rec find index = function
    | [] -> None
    | candidate :: rest ->
      if String.equal candidate line then Some index else find (index + 1) rest
  in
  find 0 (lines text)
;;

let line_follows text ~first ~then_ =
  let rec scan = function
    | a :: (b :: _ as rest) -> (String.equal a first && String.equal b then_) || scan rest
    | [] | [ _ ] -> false
  in
  scan (lines text)
;;

let prefix_until text marker =
  match index_of_line text marker with
  | Some index -> List.filteri (fun i _ -> i < index) (lines text)
  | None -> failf "marker %S missing" marker
;;

let suffix_from text marker =
  match index_of_line text marker with
  | Some index -> List.filteri (fun i _ -> i >= index) (lines text)
  | None -> failf "marker %S missing" marker
;;

let comment_lines text =
  List.filter
    (fun line ->
       let trimmed = String.trim line in
       String.length trimmed > 0 && Char.equal trimmed.[0] '#')
    (lines text)
;;

let fixture =
  {|# head comment
[runtime]
default = "a.b"

# ── fusion ──
[fusion]
enabled = true
default_preset = "trio"
staged_judge_group_size = 3

# trio preset note
[fusion.presets.trio]
panel = [
  "p.one",
  "p.two",
]
# judge note
judge = "j.one"
panel_system_prompt = """
You are a "panelist" \\ answer.
"""
judge_system_prompt = """
Judge.
"""
min_answered = 1

# quorum note
[fusion.presets.quorum]
panel = ["p.one", "p.two"]
judge = "j.meta"
panel_system_prompt = "Answer."
judge_system_prompt = "Meta."

# lens A note
[[fusion.presets.quorum.judges]]
model = "j.a"
label = "evidence"
system_prompt = "Lens A."

[[fusion.presets.quorum.judges]]
model = "j.b"
label = "coverage"
system_prompt = "Lens B."

# voice note
[voice.tts]
default_model = "x"
|}
;;

let test_upsert_changes_values_and_keeps_the_rest () =
  let before = policy_of fixture in
  let trio = preset_of before "trio" in
  let edited = { trio with Fusion_policy.judge = "j.two"; min_answered = 2 } in
  let text = ok_or_fail (Fusion_config_writer.upsert_preset fixture edited) in
  let after = policy_of text in
  check preset_t "the preset reads back as written" edited (preset_of after "trio");
  check preset_t "the next preset is untouched" (preset_of before "quorum")
    (preset_of after "quorum");
  check (list string) "everything above the preset header is byte-identical"
    (prefix_until fixture "[fusion.presets.trio]")
    (prefix_until text "[fusion.presets.trio]");
  check (list string) "everything from the next preset's note on is byte-identical"
    (suffix_from fixture "# quorum note")
    (suffix_from text "# quorum note");
  check bool "a comment stays with its key" true
    (line_follows text ~first:"# judge note" ~then_:{|judge = "j.two"|})
;;

let test_prompt_text_round_trips_exactly () =
  let trio = preset_of (policy_of fixture) "trio" in
  let prompt = "Quote \"\"\" and \\ backslash\tand tab\nsecond line without a newline" in
  let edited =
    { trio with
      Fusion_policy.panels =
        List.map
          (fun (g : Fusion_policy.panel_group) -> { g with Fusion_policy.system_prompt = prompt })
          trio.panels
    }
  in
  let text = ok_or_fail (Fusion_config_writer.upsert_preset fixture edited) in
  check preset_t "a prompt with quotes, backslashes and tabs reads back exactly" edited
    (preset_of (policy_of text) "trio")
;;

let test_groups_and_judges_round_trip () =
  let quorum = preset_of (policy_of fixture) "quorum" in
  let group label models : Fusion_policy.panel_group =
    { Fusion_policy.models
    ; label
    ; system_prompt = "Answer as " ^ label ^ "."
    ; web_tools = String.equal label "skeptic"
    ; max_output_tokens = Some 2048
    ; timeout_s = Some 90.5
    }
  in
  let evidence =
    List.find (fun (j : Fusion_policy.judge_spec) -> String.equal j.jlabel "evidence") quorum.judges
  in
  let edited =
    { quorum with
      Fusion_policy.panels = [ group "skeptic" [ "p.one" ]; group "builder" [ "p.one"; "p.two" ] ]
    ; judges = [ { evidence with Fusion_policy.jtimeout_s = Some 45.0 } ]
    ; judge_timeout_s = Some 120.0
    }
  in
  let text = ok_or_fail (Fusion_config_writer.upsert_preset fixture edited) in
  check preset_t "labelled groups and one judge read back as written" edited
    (preset_of (policy_of text) "quorum");
  check bool "the kept judge keeps its note" true
    (line_follows text ~first:"# lens A note" ~then_:"[[fusion.presets.quorum.judges]]");
  check bool "the removed judge is gone" false
    (Option.is_some (index_of_line text {|model = "j.b"|}))
;;

let test_new_preset_joins_the_fusion_section () =
  let trio = preset_of (policy_of fixture) "trio" in
  let solo = { trio with Fusion_policy.name = "solo"; judge = "j.solo" } in
  let text = ok_or_fail (Fusion_config_writer.upsert_preset fixture solo) in
  check preset_t "the new preset reads back" solo (preset_of (policy_of text) "solo");
  match index_of_line text "[fusion.presets.solo]", index_of_line text "# voice note" with
  | Some solo_at, Some voice_at ->
    check bool "the new preset sits before the next section's note" true (solo_at < voice_at)
  | _ -> fail "both the new preset and the voice note must be present"
;;

let test_delete_takes_the_attached_note () =
  let text = ok_or_fail (Fusion_config_writer.delete_preset fixture ~name:"quorum") in
  let after = policy_of text in
  check bool "the preset is gone" true (Option.is_none (Fusion_policy.find_preset after "quorum"));
  check bool "its attached note is gone" false (Option.is_some (index_of_line text "# quorum note"));
  check bool "its judges' note is gone" false (Option.is_some (index_of_line text "# lens A note"));
  check bool "the next section's note stays" true (Option.is_some (index_of_line text "# voice note"));
  check preset_t "the other preset is untouched" (preset_of (policy_of fixture) "trio")
    (preset_of after "trio")
;;

let test_rename_moves_headers_and_default () =
  let text =
    ok_or_fail (Fusion_config_writer.rename_preset fixture ~from:"quorum" ~target:"panel-of-three")
  in
  let after = policy_of text in
  let before = preset_of (policy_of fixture) "quorum" in
  check preset_t "the body is unchanged under the new name"
    { before with Fusion_policy.name = "panel-of-three" }
    (preset_of after "panel-of-three");
  check bool "the note stays above the header" true
    (line_follows text ~first:"# quorum note" ~then_:"[fusion.presets.panel-of-three]");
  let renamed_default =
    ok_or_fail (Fusion_config_writer.rename_preset fixture ~from:"trio" ~target:"duo")
  in
  check string "default_preset follows the rename" "duo"
    (policy_of renamed_default).Fusion_policy.default_preset
;;

let test_rename_onto_an_existing_preset_is_refused () =
  match Fusion_config_writer.rename_preset fixture ~from:"trio" ~target:"quorum" with
  | Error (Fusion_config_writer.Preset_exists "quorum") -> ()
  | Error error -> failf "unexpected error: %s" (Fusion_config_writer.error_message error)
  | Ok _ -> fail "renaming onto an existing preset must be refused"
;;

let test_scattered_preset_is_unaddressable () =
  let scattered =
    {|[fusion.presets.split]
panel = ["p.one"]
judge = "j.one"
panel_system_prompt = "A."
judge_system_prompt = "J."

[voice]
enabled = true

[[fusion.presets.split.judges]]
model = "j.a"
system_prompt = "Lens."
|}
  in
  let split =
    { Fusion_policy.name = "split"
    ; panels =
        [ { Fusion_policy.models = [ "p.one" ]
          ; label = ""
          ; system_prompt = "A."
          ; web_tools = false
          ; max_output_tokens = None
          ; timeout_s = None
          }
        ]
    ; judge = "j.one"
    ; judge_system_prompt = "J."
    ; judge_max_output_tokens = None
    ; judge_timeout_s = None
    ; judges = []
    ; min_answered = 1
    }
  in
  match Fusion_config_writer.upsert_preset scattered split with
  | Error (Fusion_config_writer.Unaddressable_preset "split") -> ()
  | Error error -> failf "unexpected error: %s" (Fusion_config_writer.error_message error)
  | Ok _ -> fail "a preset whose judges sit below another table must not be edited by lines"
;;

let test_settings_are_written () =
  let text =
    Fusion_config_writer.set_settings fixture
      { Fusion_config_writer.enabled = false
      ; default_preset = "quorum"
      ; staged_judge_group_size = 4
      }
  in
  let after = policy_of text in
  check bool "enabled" false after.Fusion_policy.enabled;
  check string "default_preset" "quorum" after.default_preset;
  check int "staged_judge_group_size" 4 after.staged_judge_group_size
;;

(* The shipped seed carries long notes inside its presets. Writing each preset
   back unchanged must keep every preset equal and every comment line. *)
let test_seed_runtime_toml_round_trips () =
  let seed =
    let channel = open_in_bin "../../config/runtime.toml" in
    Fun.protect
      ~finally:(fun () -> close_in channel)
      (fun () -> really_input_string channel (in_channel_length channel))
  in
  let before = policy_of seed in
  let rewritten =
    List.fold_left
      (fun text (validated : Fusion_policy.Validated_preset.t) ->
         ok_or_fail
           (Fusion_config_writer.upsert_preset text
              (Fusion_policy.Validated_preset.preset validated)))
      seed before.presets
  in
  let after = policy_of rewritten in
  check int "preset count" (List.length before.presets) (List.length after.presets);
  List.iter
    (fun (validated : Fusion_policy.Validated_preset.t) ->
       let preset = Fusion_policy.Validated_preset.preset validated in
       check preset_t ("seed preset " ^ preset.name) preset (preset_of after preset.name))
    before.presets;
  check (list string) "every comment line survives, in order"
    (comment_lines seed) (comment_lines rewritten)
;;

let () =
  run
    "fusion config writer"
    [ ( "upsert"
      , [ test_case "changes values and keeps the rest" `Quick
            test_upsert_changes_values_and_keeps_the_rest
        ; test_case "prompt text round-trips exactly" `Quick test_prompt_text_round_trips_exactly
        ; test_case "groups and judges round-trip" `Quick test_groups_and_judges_round_trip
        ; test_case "new preset joins the fusion section" `Quick
            test_new_preset_joins_the_fusion_section
        ; test_case "scattered preset is unaddressable" `Quick
            test_scattered_preset_is_unaddressable
        ] )
    ; ( "delete and rename"
      , [ test_case "delete takes the attached note" `Quick test_delete_takes_the_attached_note
        ; test_case "rename moves headers and default" `Quick test_rename_moves_headers_and_default
        ; test_case "rename onto an existing preset is refused" `Quick
            test_rename_onto_an_existing_preset_is_refused
        ] )
    ; ( "settings", [ test_case "settings are written" `Quick test_settings_are_written ] )
    ; ( "seed"
      , [ test_case "seed runtime.toml round-trips" `Quick test_seed_runtime_toml_round_trips ] )
    ]
;;
