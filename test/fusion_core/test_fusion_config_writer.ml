(* Fusion_config_writer: a typed preset edit changes only the keys whose value
   changed, keeps every other line byte-for-byte, and produces text that
   Fusion_config reads back as exactly the preset given. The seed case runs the
   shipped config/runtime.toml through the writer. *)

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

let valid (preset : Fusion_policy.preset) =
  match Fusion_policy.Validated_preset.of_preset preset with
  | Ok validated -> validated
  | Error _ -> failf "fixture preset %s must be valid" preset.name
;;

let upsert text preset = Fusion_config_writer.upsert_preset text (valid preset)

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

let lines_in_a_row text expected =
  let rec starts = function
    | _, [] -> true
    | [], _ :: _ -> false
    | line :: rest, wanted :: others -> String.equal line wanted && starts (rest, others)
  in
  let rec scan = function
    | [] -> starts ([], expected)
    | _ :: rest as here -> starts (here, expected) || scan rest
  in
  scan (lines text)
;;

let position text line =
  match index_of_line text line with
  | Some index -> index
  | None -> failf "line %S missing" line
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
  let text = ok_or_fail (upsert fixture edited) in
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
  let text = ok_or_fail (upsert fixture edited) in
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
  let text = ok_or_fail (upsert fixture edited) in
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
  let text = ok_or_fail (upsert fixture solo) in
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
  match upsert scattered split with
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

(* An unchanged preset is written back byte for byte, whatever order its keys
   are in and however its values are spelled. A changed key is rewritten where
   it stands, under its note. *)
let test_unchanged_keys_keep_their_lines () =
  let text =
    {|[fusion]
enabled = true
default_preset = "odd"

[fusion.presets.odd]
# the judge comes first here
judge = "j.one"  # inline note
web_tools = false
min_answered = 1
panel = [
  "p.one",  # first seat
  "p.two",
]
panel_system_prompt = """\
  A prompt wrapped \
  with line-ending backslashes."""
judge_system_prompt = "Judge."
judge_timeout_s = 120
|}
  in
  let odd = preset_of (policy_of text) "odd" in
  check string "an unchanged preset leaves the file byte-identical" text
    (ok_or_fail (upsert text odd));
  let edited = { odd with Fusion_policy.judge = "j.two" } in
  let written = ok_or_fail (upsert text edited) in
  check preset_t "the change reads back" edited (preset_of (policy_of written) "odd");
  check bool "the note above the changed key stays with it" true
    (line_follows written ~first:"# the judge comes first here" ~then_:{|judge = "j.two"|});
  check bool "an unchanged array keeps its inline comment" true
    (Option.is_some (index_of_line written {|  "p.one",  # first seat|}));
  check bool "an unchanged wrapped prompt keeps its wrapping" true
    (Option.is_some (index_of_line written {|  with line-ending backslashes."""|}));
  check bool "a whole number of seconds is the same value as its float" true
    (Option.is_some (index_of_line written "judge_timeout_s = 120"));
  check bool "keys keep their order" true
    (position written {|judge = "j.two"|} < position written "panel = [")
;;

(* A group's label may equal another group's first route. Each entry is known
   by its label and its routes, so each keeps its own note, and the notes move
   with the groups when the preset reorders them. *)
let test_entries_keep_their_own_notes () =
  let text =
    {|[fusion.presets.pair]
judge = "j.one"
judge_system_prompt = "Judge."

# note for the labelled group
[[fusion.presets.pair.panels]]
label = "p.one"
panel = ["p.two"]
panel_system_prompt = "Labelled."

# note for the bare group
[[fusion.presets.pair.panels]]
panel = ["p.one"]
panel_system_prompt = "Bare."
|}
  in
  let pair = preset_of (policy_of text) "pair" in
  check string "an unchanged preset leaves the file byte-identical" text
    (ok_or_fail (upsert text pair));
  let reordered = { pair with Fusion_policy.panels = List.rev pair.panels } in
  let written = ok_or_fail (upsert text reordered) in
  check preset_t "the new order reads back" reordered (preset_of (policy_of written) "pair");
  check bool "the bare group carries its note" true
    (lines_in_a_row written
       [ "# note for the bare group"; "[[fusion.presets.pair.panels]]"; {|panel = ["p.one"]|} ]);
  check bool "the labelled group carries its note" true
    (lines_in_a_row written
       [ "# note for the labelled group"; "[[fusion.presets.pair.panels]]"; {|label = "p.one"|} ]);
  check bool "the bare group now comes first" true
    (position written "# note for the bare group"
     < position written "# note for the labelled group");
  let rerouted =
    { pair with
      Fusion_policy.panels =
        List.map
          (fun (group : Fusion_policy.panel_group) ->
             if String.equal group.label "p.one"
             then { group with Fusion_policy.models = [ "p.three" ] }
             else group)
          pair.panels
    }
  in
  let written = ok_or_fail (upsert text rerouted) in
  check preset_t "the new route reads back" rerouted (preset_of (policy_of written) "pair");
  check bool "a group that keeps its label keeps its note when its routes change" true
    (lines_in_a_row written
       [ "# note for the labelled group"
       ; "[[fusion.presets.pair.panels]]"
       ; {|label = "p.one"|}
       ; "panel = ["
       ; {|  "p.three",|}
       ; "]"
       ])
;;

(* Two groups without a label differ only by their routes. *)
let test_unlabelled_groups_are_told_apart_by_routes () =
  let text =
    {|[fusion.presets.bare]
judge = "j.one"
judge_system_prompt = "Judge."

# note for one
[[fusion.presets.bare.panels]]
panel = ["p.one"]
panel_system_prompt = "One."

# note for two
[[fusion.presets.bare.panels]]
panel = ["p.two"]
panel_system_prompt = "Two."
|}
  in
  let bare = preset_of (policy_of text) "bare" in
  let reordered = { bare with Fusion_policy.panels = List.rev bare.panels } in
  let written = ok_or_fail (upsert text reordered) in
  check preset_t "the new order reads back" reordered (preset_of (policy_of written) "bare");
  check bool "each group carries its own note" true
    (lines_in_a_row written
       [ "# note for two"; "[[fusion.presets.bare.panels]]"; {|panel = ["p.two"]|} ]
     && lines_in_a_row written
          [ "# note for one"; "[[fusion.presets.bare.panels]]"; {|panel = ["p.one"]|} ]);
  check bool "the second group now comes first" true
    (position written "# note for two" < position written "# note for one")
;;

(* A key the preset's table gets from outside the region would stay where it
   is while the writer wrote its own: the file would name it twice. *)
let test_a_key_written_elsewhere_is_unaddressable () =
  let text =
    {|[fusion]
enabled = true
default_preset = "trio"
presets.trio.min_answered = 2

[fusion.presets.trio]
panel = ["p.one", "p.two"]
judge = "j.one"
panel_system_prompt = "A."
judge_system_prompt = "J."
|}
  in
  let trio = preset_of (policy_of text) "trio" in
  check int "the dotted key is part of the preset" 2 trio.min_answered;
  (match upsert text { trio with Fusion_policy.judge = "j.two" } with
   | Error (Fusion_config_writer.Unaddressable_preset "trio") -> ()
   | Error error -> failf "unexpected error: %s" (Fusion_config_writer.error_message error)
   | Ok _ -> fail "a preset with a key outside its table must not be edited by lines");
  match Fusion_config_writer.delete_preset text ~name:"trio" with
  | Error (Fusion_config_writer.Unaddressable_preset "trio") -> ()
  | Error error -> failf "unexpected error: %s" (Fusion_config_writer.error_message error)
  | Ok _ -> fail "deleting the table would leave the dotted key behind"
;;

let test_unreadable_text_is_an_error () =
  let text = "[fusion.presets.trio]\njudge = \"a\"\njudge = \"b\"\n" in
  match Fusion_config_writer.delete_preset text ~name:"trio" with
  | Error (Fusion_config_writer.Unreadable _) -> ()
  | Error error -> failf "unexpected error: %s" (Fusion_config_writer.error_message error)
  | Ok _ -> fail "a file with a duplicate key must not be edited"
;;

let test_rename_keeps_a_header_comment () =
  let text =
    String.concat "\n"
      [ "[fusion.presets.quorum]  # the three-seat panel"
      ; {|panel = ["p.one", "p.two"]|}
      ; {|judge = "j.one"|}
      ; {|panel_system_prompt = "A."|}
      ; {|judge_system_prompt = "J."|}
      ; ""
      ; "[[fusion.presets.quorum.judges]] # lens"
      ; {|model = "j.a"|}
      ; {|system_prompt = "Lens."|}
      ; ""
      ]
  in
  let renamed = ok_or_fail (Fusion_config_writer.rename_preset text ~from:"quorum" ~target:"q") in
  check bool "the table header keeps its comment" true
    (Option.is_some (index_of_line renamed "[fusion.presets.q]  # the three-seat panel"));
  check bool "the entry header keeps its comment" true
    (Option.is_some (index_of_line renamed "[[fusion.presets.q.judges]] # lens"))
;;

(* A key [\[fusion\]] lacks goes after its last key, not below the blank line
   and the note that belong to the next table. *)
let test_a_new_setting_joins_the_table () =
  let text =
    {|[fusion]
enabled = true
default_preset = "trio"

# trio preset note
[fusion.presets.trio]
panel = ["p.one", "p.two"]
judge = "j.one"
panel_system_prompt = "A."
judge_system_prompt = "J."
|}
  in
  let written =
    Fusion_config_writer.set_settings text
      { Fusion_config_writer.enabled = true
      ; default_preset = "trio"
      ; staged_judge_group_size = 4
      }
  in
  check int "the new key reads back" 4 (policy_of written).Fusion_policy.staged_judge_group_size;
  check bool "the new key follows the last key" true
    (line_follows written ~first:{|default_preset = "trio"|} ~then_:"staged_judge_group_size = 4");
  check bool "the next table keeps its note" true
    (line_follows written ~first:"# trio preset note" ~then_:"[fusion.presets.trio]");
  let unchanged =
    Fusion_config_writer.set_settings text
      { Fusion_config_writer.enabled = true
      ; default_preset = "trio"
      ; staged_judge_group_size = Fusion_policy.default_staged_judge_group_size
      }
  in
  check string "settings equal to the file leave it byte-identical" text unchanged
;;

let test_deleting_the_last_preset_leaves_no_blank_at_the_end () =
  let text =
    {|[fusion]
enabled = true

[fusion.presets.trio]
panel = ["p.one"]
judge = "j.one"
panel_system_prompt = "A."
judge_system_prompt = "J."

[fusion.presets.last]
panel = ["p.one"]
judge = "j.one"
panel_system_prompt = "A."
judge_system_prompt = "J."
|}
  in
  let deleted = ok_or_fail (Fusion_config_writer.delete_preset text ~name:"last") in
  check string "the file ends where the previous preset ends"
    {|[fusion]
enabled = true

[fusion.presets.trio]
panel = ["p.one"]
judge = "j.one"
panel_system_prompt = "A."
judge_system_prompt = "J."
|}
    deleted
;;

(* The shipped seed carries long notes and wrapped prompts inside its presets.
   Writing each preset back unchanged must not move a byte. *)
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
         ok_or_fail (Fusion_config_writer.upsert_preset text validated))
      seed before.presets
  in
  check string "writing every preset back unchanged leaves the file byte-identical" seed
    rewritten
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
        ; test_case "unchanged keys keep their lines" `Quick
            test_unchanged_keys_keep_their_lines
        ; test_case "entries keep their own notes" `Quick test_entries_keep_their_own_notes
        ; test_case "unlabelled groups are told apart by routes" `Quick
            test_unlabelled_groups_are_told_apart_by_routes
        ; test_case "a key written elsewhere is unaddressable" `Quick
            test_a_key_written_elsewhere_is_unaddressable
        ; test_case "unreadable text is an error" `Quick test_unreadable_text_is_an_error
        ] )
    ; ( "delete and rename"
      , [ test_case "delete takes the attached note" `Quick test_delete_takes_the_attached_note
        ; test_case "rename moves headers and default" `Quick test_rename_moves_headers_and_default
        ; test_case "rename onto an existing preset is refused" `Quick
            test_rename_onto_an_existing_preset_is_refused
        ; test_case "rename keeps a header comment" `Quick test_rename_keeps_a_header_comment
        ; test_case "deleting the last preset leaves no blank at the end" `Quick
            test_deleting_the_last_preset_leaves_no_blank_at_the_end
        ] )
    ; ( "settings"
      , [ test_case "settings are written" `Quick test_settings_are_written
        ; test_case "a new setting joins the table" `Quick test_a_new_setting_joins_the_table
        ] )
    ; ( "seed"
      , [ test_case "seed runtime.toml round-trips" `Quick test_seed_runtime_toml_round_trips ] )
    ]
;;
