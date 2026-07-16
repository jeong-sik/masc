(* RFC-0306 §3.1 — Fusion_config_json.to_yojson projects the active fusion config
   for the dashboard settings editor. This fixes the JSON shape end-to-end through
   of_toml, covering the JoJ [[...judges]] array-of-tables path that the read
   endpoint must surface (the field the current read-only UI cannot show). *)

let parse s = Otoml.Parser.from_string s

(* Mirrors config/runtime.toml [fusion.presets.quorum] structure with placeholder
   model ids so the JoJ array-of-tables projection is exercised. *)
let joj_preset_toml =
  {|
[fusion]
enabled = true
default_preset = "quorum"
[fusion.presets.quorum]
panel = ["pa", "pb", "pc"]
judge = "meta-reducer"
panel_system_prompt = "answer independently"
judge_system_prompt = "reconcile the first-judge syntheses"
meta_timeout_s = 120.0

[[fusion.presets.quorum.judges]]
model = "judge-evidence"
label = "evidence"
system_prompt = "judge through an evidence lens"

[[fusion.presets.quorum.judges]]
model = "judge-coverage"
label = "coverage"
system_prompt = "judge through a coverage lens"
|}

let test_to_yojson_projects_joj_preset () =
  match Fusion_config.of_toml (parse joj_preset_toml) with
  | Error es ->
    Alcotest.failf "fixture must parse+validate, got: %s"
      (String.concat ", " (List.map Fusion_config.show_config_error es))
  | Ok config ->
    let json = Fusion_config_json.to_yojson config in
    let open Yojson.Safe.Util in
    Alcotest.(check bool) "enabled" true (json |> member "enabled" |> to_bool);
    Alcotest.(check string) "default_preset" "quorum"
      (json |> member "default_preset" |> to_string);
    let presets = json |> member "presets" |> to_list in
    Alcotest.(check int) "one preset" 1 (List.length presets);
    let p = List.hd presets in
    Alcotest.(check string) "preset name" "quorum"
      (p |> member "name" |> to_string);
    Alcotest.(check string) "meta judge" "meta-reducer"
      (p |> member "judge" |> to_string);
    let judges = p |> member "judges" |> to_list in
    Alcotest.(check int) "two JoJ first-round judges serialized" 2
      (List.length judges);
    Alcotest.(check (list string))
      "judge models projected with the j-prefix dropped (jmodel -> model)"
      [ "judge-evidence"; "judge-coverage" ]
      (List.map (fun j -> j |> member "model" |> to_string) judges);
    Alcotest.(check (list string)) "judge lenses projected (jlabel -> label)"
      [ "evidence"; "coverage" ]
      (List.map (fun j -> j |> member "label" |> to_string) judges);
    let panel_models =
      p |> member "panels" |> to_list
      |> List.concat_map (fun g ->
             g |> member "models" |> to_list |> List.map to_string)
    in
    Alcotest.(check (list string)) "panel roster flattened in order"
      [ "pa"; "pb"; "pc" ] panel_models

let () =
  Alcotest.run "fusion_config_json"
    [ ( "to_yojson"
      , [ Alcotest.test_case "projects JoJ preset" `Quick
            test_to_yojson_projects_joj_preset
        ] )
    ]
