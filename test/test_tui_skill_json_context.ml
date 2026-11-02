open Alcotest

let contains text needle =
  let rec loop offset =
    offset + String.length needle <= String.length text
    && (String.sub text offset (String.length needle) = needle || loop (offset + 1))
  in
  loop 0

let strip_sgr text =
  let out = Buffer.create (String.length text) in
  let rec loop offset =
    if offset < String.length text then
      if text.[offset] = '\027' && offset + 1 < String.length text
         && text.[offset + 1] = '[' then
        match String.index_from_opt text (offset + 2) 'm' with
        | Some ending -> loop (ending + 1)
        | None -> fail "unterminated style sequence"
      else begin
        Buffer.add_char out text.[offset];
        loop (offset + 1)
      end
  in
  loop 0;
  Buffer.contents out

let test_skill_schema_source_context () =
  let module Tools = Masc.Tui_decode_tools in
  let selector = "\239\184\143" in
  let reference =
    Skill_reference.of_yojson (`Assoc [
      "identity", `Assoc ["source_id", `String "workspace";
        "package_id", `String "fixture"; "name", `String "fixture"];
      "content_revision", `String (String.make 64 'a')]) |> Result.get_ok in
  let schema = `Assoc [
    "key\000" ^ selector, `String ("VALUE\000" ^ selector);
    "legitimate", `String "HEART ❤️ EMOJI 👩‍💻" ] in
  let profile : Tools.effective_skill_profile = {
    esp_reference=reference; esp_name="fixture"; esp_kind="composition";
    esp_execution="inline"; esp_body_bytes=0; esp_discovery_bytes=0;
    esp_load_reasons=[]; esp_node_count=0; esp_batch_count=0; esp_max_parallelism=0;
    esp_flow=None; esp_io=Composition_io {input_schema=schema; exports=[]} } in
  let inventory : Tools.tool_snapshot = {
    ts_tools=[]; ts_count=0; ts_freshness=Settled; ts_skill_activations=None;
    ts_effective=Some (Effective_surface_available {
      ets_keeper_name="fixture"; ets_runtime_id="fixture"; ets_official_client_kind="fixture";
      ets_tool_delivery=Effective_tools_delivered; ets_native_posture=None;
      ets_skill_snapshot_revision="snapshot"; ets_skill_resource_read_max_bytes=None;
      ets_instruction_skills=[]; ets_skills_left_out=[]; ets_unavailable_skill_names=[];
      ets_composition_skills=[reference]; ets_skill_profiles=[profile];
      ets_tool_surface_bytes=None; ets_skill_tool_surface_bytes=None; ets_skill_discovery_bytes=0;
      ets_skill_body_bytes=None; ets_tools=[]; ets_tool_surface_sha256=None }) } in
  let state = Masc_tui_types.create_state ~workspace:"fixture" ~port:0 ~refresh_interval:0. () in
  state.tools_inventory <- Some inventory;
  let shown = Masc_tui_render_tools.tools_display_lines ~cols:120 state
    |> List.map (fun (_, line) -> strip_sgr line) |> String.concat "\n" in
  check bool "orphan selector in a key is visible" true
    (contains shown "key\\u0000\\uFE0F");
  check bool "orphan selector in a value is visible" true
    (contains shown "VALUE\\u0000\\uFE0F");
  check bool "legitimate emoji remains intact" true (contains shown "HEART ❤️ EMOJI 👩‍💻")

let () =
  run "tui_skill_json_context"
    ["source context", [test_case "Skill schema key and value" `Quick test_skill_schema_source_context]]
