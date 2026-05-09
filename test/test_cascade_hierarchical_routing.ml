open Alcotest

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" then
    ()
  else if Sys.file_exists path then
    ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let write_file path content =
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let with_env name value f =
  let saved = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match saved with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let with_config_dir config_dir f =
  let reset () =
    Masc_mcp.Config_dir_resolver.reset ();
    Masc_mcp.Cascade_catalog_runtime.reset_cache_for_tests ()
  in
  with_env "MASC_BASE_PATH" None @@ fun () ->
  with_env "MASC_CONFIG_DIR" (Some config_dir) @@ fun () ->
  reset ();
  Fun.protect ~finally:reset f

(* -------------------------------------------------------------------------- *)
(* Hierarchical JSON format: {name}_groups                                  *)
(* -------------------------------------------------------------------------- *)

let test_load_cascade_profile_hierarchical () =
  with_temp_dir "cascade_hier" @@ fun config_dir ->
  with_config_dir config_dir @@ fun () ->
  let json_path = Filename.concat config_dir "cascade.json" in
  let json_content =
    {|{
      "test_profile_groups": [
        {
          "name": "primary",
          "items": [
            {"id": "ollama-qwen", "provider": "ollama", "model": "qwen3:14b", "timeout_ms": 30000, "priority": 1},
            {"id": "ollama-llama", "provider": "ollama", "model": "llama3:8b", "timeout_ms": 30000, "priority": 2}
          ],
          "strategy": "priority",
          "fallback_group": "fallback"
        },
        {
          "name": "fallback",
          "items": [
            {"id": "gemini-flash", "provider": "gemini_cli", "model": "gemini-3-flash-preview", "timeout_ms": 60000, "priority": 1}
          ],
          "strategy": "priority",
          "fallback_group": null
        }
      ]
    }|}
  in
  write_file json_path json_content;
  let profile_opt =
    Masc_mcp.Cascade_config_loader.load_cascade_profile
      ~config_path:json_path ~name:"test_profile"
  in
  match profile_opt with
  | None -> fail "expected hierarchical profile to parse"
  | Some profile ->
      check string "profile name" "test_profile" profile.name;
      check int "group count" 2 (List.length profile.groups);
      let primary = List.nth profile.groups 0 in
      check string "primary group name" "primary" primary.name;
      check int "primary item count" 2 (List.length primary.items);
      check (option string) "primary fallback_group" (Some "fallback")
        primary.fallback_group;
      let first_item = List.nth primary.items 0 in
      check string "first item id" "ollama-qwen" first_item.id;
      check string "first item provider" "ollama" first_item.provider;
      check int "first item timeout" 30000 first_item.timeout_ms;
      let fallback = List.nth profile.groups 1 in
      check string "fallback group name" "fallback" fallback.name;
      check (option string) "fallback fallback_group" None fallback.fallback_group

(* -------------------------------------------------------------------------- *)
(* Legacy JSON format: {name}_models (backward compatibility)                *)
(* -------------------------------------------------------------------------- *)

let test_load_cascade_profile_legacy_fallback () =
  with_temp_dir "cascade_legacy" @@ fun config_dir ->
  with_config_dir config_dir @@ fun () ->
  let json_path = Filename.concat config_dir "cascade.json" in
  let json_content =
    {|{
      "legacy_profile_models": [
        {"model": "ollama:qwen3:14b", "weight": 1},
        {"model": "gemini_cli:gemini-3-flash-preview", "weight": 2}
      ],
      "legacy_profile_temperature": 0.7
    }|}
  in
  write_file json_path json_content;
  let profile_opt =
    Masc_mcp.Cascade_config_loader.load_cascade_profile
      ~config_path:json_path ~name:"legacy_profile"
  in
  match profile_opt with
  | None -> fail "expected legacy profile to parse"
  | Some profile ->
      check string "profile name" "legacy_profile" profile.name;
      check int "group count" 1 (List.length profile.groups);
      let group = List.nth profile.groups 0 in
      check string "group name" "legacy_profile" group.name;
      check int "item count" 2 (List.length group.items);
      let first_item = List.nth group.items 0 in
      check string "first item id" "ollama:qwen3:14b" first_item.id;
      check string "first item provider" "ollama" first_item.provider;
      check string "first item model" "qwen3:14b" first_item.model;
      let second_item = List.nth group.items 1 in
      check string "second item id" "gemini_cli:gemini-2.5-flash" second_item.id

(* -------------------------------------------------------------------------- *)
(* TOML materializer: groups array -> JSON                                  *)
(* -------------------------------------------------------------------------- *)

let test_toml_materializer_groups () =
  let toml_content =
    {|[[groups]]
name = "primary"
strategy = "priority"
fallback_group = "fallback"

[[groups.items]]
id = "ollama-qwen"
provider = "ollama"
model = "qwen3:14b"
timeout_ms = 30000
priority = 1

[[groups.items]]
id = "ollama-llama"
provider = "ollama"
model = "llama3:8b"
timeout_ms = 30000
priority = 2

[[groups]]
name = "fallback"
strategy = "priority"

[[groups.items]]
id = "gemini-flash"
provider = "gemini_cli"
model = "gemini-2.5-flash"
timeout_ms = 60000
priority = 1
|}
  in
  match Masc_mcp.Cascade_toml_materializer.render_toml_string_to_json_string
          toml_content with
  | Error msg -> fail msg
  | Ok json_str ->
      let json = Yojson.Safe.from_string json_str in
      let groups = Yojson.Safe.Util.to_list
        (Yojson.Safe.Util.member "groups" json)
      in
      check int "group count" 2 (List.length groups);
      let primary_json = List.nth groups 0 in
      check string "primary name"
        "primary"
        (Yojson.Safe.Util.to_string
           (Yojson.Safe.Util.member "name" primary_json));
      let items = Yojson.Safe.Util.to_list
        (Yojson.Safe.Util.member "items" primary_json)
      in
      check int "primary item count" 2 (List.length items);
      let fallback_json = List.nth groups 1 in
      check string "fallback name"
        "fallback"
        (Yojson.Safe.Util.to_string
           (Yojson.Safe.Util.member "name" fallback_json))

(* -------------------------------------------------------------------------- *)
(* Suite                                                                    *)
(* -------------------------------------------------------------------------- *)

let () =
  run "Cascade Hierarchical Routing"
    [
      ( "loader",
        [
          test_case "hierarchical JSON profile" `Quick
            test_load_cascade_profile_hierarchical;
          test_case "legacy JSON fallback" `Quick
            test_load_cascade_profile_legacy_fallback;
        ] );
      ( "materializer",
        [
          test_case "TOML groups to JSON" `Quick test_toml_materializer_groups;
        ] );
    ]
