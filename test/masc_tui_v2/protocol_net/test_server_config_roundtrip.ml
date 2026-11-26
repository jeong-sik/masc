(** End-to-end server -> TUI protocol round-trip tests for `/api/v1/config/schema`.

    Lives in Layer 3 (`test/masc_tui_v2/protocol_net/`) so Layer 1
    (`test/server_tui_v2_api/`) stays 100% independent of `lib/masc_tui/*`. *)

open Masc

module Candle_cfg_api = Server_dashboard_http_candle_config
module Wc = Masc_tui_protocol.Wire_config

let rec rm_rf path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    (try
       Array.iter
         (fun entry -> rm_rf (Filename.concat path entry))
         (Sys.readdir path)
     with
     | Sys_error _ -> ());
    (try Unix.rmdir path with Unix.Unix_error _ -> ())
  | _ -> (try Unix.unlink path with Unix.Unix_error _ -> ())
;;

let rec mkdir_p path =
  if path = "" || path = "/" || path = "." then ()
  else if Sys.file_exists path then ()
  else (
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

let with_temp_workspace (f : Workspace.config -> 'a) : 'a =
  let base = Filename.temp_dir "masc_tui_v2_cfg_rt_" "" in
  mkdir_p (Filename.concat base ".masc/config/keepers");
  mkdir_p (Filename.concat base ".masc/keepers");
  let config = Workspace.default_config base in
  Fun.protect ~finally:(fun () -> rm_rf base) (fun () -> f config)
;;

let write_file_raw path content =
  mkdir_p (Filename.dirname path);
  match Fs_compat.save_file_atomic path content with
  | Ok () -> ()
  | Error msg -> Alcotest.fail ("write_file_raw failed: " ^ msg)
;;

let ok_or_fail label = function
  | Ok v -> v
  | Error (status, json) ->
    Alcotest.fail
      (Printf.sprintf
         "%s failed (HTTP %d): %s"
         label
         (Httpun.Status.to_code status)
         (Yojson.Safe.to_string json))
;;

let contains_substr ~needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen = 0 then true
  else if nlen > hlen then false
  else (
    let rec loop i =
      if i + nlen > hlen then false
      else if String.sub haystack i nlen = needle then true
      else loop (i + 1)
    in
    loop 0)
;;

let test_config_schema_server_to_tui_roundtrip () =
  with_temp_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    let runtime_toml_path = Filename.concat base_path ".masc/config/runtime.toml" in
    let secret_val = "sk-" ^ "ant-api03-ROUNDTRIPSECRET9876543210" in
    write_file_raw
      runtime_toml_path
      (Printf.sprintf
         "[runtime]\n\
          default = \"lane.primary\"\n\
          media_failover = [\"vision.a\", \"vision.b\"]\n\
          [runtime.assignments]\n\
          code_reviewer = \"lane.review\"\n\
          [runtime.lanes.primary]\n\
          members = [\"local.sample\"]\n\
          [routing]\n\
          strategy = \"priority\"\n\
          [assignment]\n\
          fallback_lane = \"lane.primary\"\n\
          [cascade]\n\
          max_hops = 3\n\
          [failover]\n\
          cooldown_sec = 30\n\
          [providers.openrouter]\n\
          endpoint = \"https://openrouter.ai/api/v1\"\n\
          api_key = \"%s\"\n\
          [models.sample]\n\
          max_context = 128000\n\
          [exec.ssh.endpoints.box1]\n\
          host = \"127.0.0.1\"\n\
          [voice]\n\
          enabled = true\n"
         secret_val);
    let keeper_toml_path = Filename.concat base_path ".masc/config/keepers/alpha.toml" in
    write_file_raw
      keeper_toml_path
      "[keeper]\n\
       name = \"alpha\"\n\
       instructions = \"Round-trip test keeper\"\n\
       activation_mode = \"on_demand\"\n\
       sandbox_profile = \"microvm\"\n\
       microvm_backend = \"apple_container\"\n";
    let env_vars =
      [ "MASC_KEEPER_ENABLE_THINKING"
      ; "MASC_KEEPER_BODY_TIMEOUT_SEC"
      ]
    in
    let saved_env = List.map (fun k -> k, Sys.getenv_opt k) env_vars in
    List.iter Unix.unsetenv env_vars;
    Fun.protect
      ~finally:(fun () ->
        List.iter
          (fun (k, prev) ->
             match prev with
             | Some v -> Unix.putenv k v
             | None -> Unix.unsetenv k)
          saved_env)
      (fun () ->
         let raw_runtime_json =
           Candle_cfg_api.config_schema_json ~base_path ~target:Target_runtime ()
           |> ok_or_fail "GET /api/v1/config/schema?target=runtime"
         in
         Alcotest.(check bool)
           "raw server payload never leaks secret"
           false
           (contains_substr ~needle:secret_val (Yojson.Safe.to_string raw_runtime_json));
         let decoded =
           match Wc.decode_config_schema raw_runtime_json with
           | Ok s -> s
           | Error msg ->
             Alcotest.fail ("Wire_config.decode_config_schema failed on live runtime schema: " ^ msg)
         in
         Alcotest.(check int) "all 7 categories decoded" 7 (List.length decoded.sections);
         let all_decoded_fields =
           List.concat_map (fun (s : Wc.schema_section) -> s.fields) decoded.sections
         in
         Alcotest.(check bool)
           "decoded contains all Registry.all rows"
           true
           (List.length all_decoded_fields >= List.length Keeper_runtime_setting_registry.all);
         let find_decoded key =
           match
             List.find_opt (fun (f : Wc.schema_field) -> String.equal f.full_key key)
               all_decoded_fields
           with
           | Some f -> f
           | None -> Alcotest.fail ("missing decoded field " ^ key)
         in
         let thinking = find_decoded "turn.enable_thinking" in
         Alcotest.(check bool) "turn.enable_thinking kind=Field_bool" true
           (thinking.kind = Wc.Field_bool);
         Alcotest.(check bool) "turn.enable_thinking value=Val_null" true
           (thinking.value = Wc.Val_null);
         let body_timeout = find_decoded "MASC_KEEPER_BODY_TIMEOUT_SEC" in
         (match body_timeout.kind with
          | Wc.Field_float _ -> ()
          | Wc.Field_bool | Wc.Field_int _ | Wc.Field_string | Wc.Field_enum _
          | Wc.Field_string_list | Wc.Field_structured | Wc.Field_secret ->
            Alcotest.fail "MASC_KEEPER_BODY_TIMEOUT_SEC expected Field_float");
         Alcotest.(check bool) "MASC_KEEPER_BODY_TIMEOUT_SEC value=Val_null" true
           (body_timeout.value = Wc.Val_null);
         let routing_sec =
           match
             List.find_opt
               (fun (s : Wc.schema_section) -> s.category = Wc.Cat_routing_failover)
               decoded.sections
           with
           | Some s -> s
           | None -> Alcotest.fail "expected Cat_routing_failover section"
         in
         let routing_keys =
           List.map (fun (f : Wc.schema_field) -> f.full_key) routing_sec.fields
         in
         List.iter
           (fun expected_key ->
              Alcotest.(check bool)
                ("routing_failover contains " ^ expected_key)
                true
                (List.mem expected_key routing_keys))
           [ "runtime.default"
           ; "runtime.media_failover"
           ; "runtime.assignments.code_reviewer"
           ; "runtime.lanes.primary.members"
           ; "routing.strategy"
           ; "assignment.fallback_lane"
           ; "cascade.max_hops"
           ; "failover.cooldown_sec"
           ];
         let secret_decoded =
           List.filter (fun (f : Wc.schema_field) -> f.secret) all_decoded_fields
         in
         Alcotest.(check bool)
           "decoded schema has secret fields"
           true
           (List.length secret_decoded > 0);
         List.iter
           (fun (f : Wc.schema_field) ->
              match f.value with
              | Wc.Val_secret _ -> ()
              | Wc.Val_bool _ | Wc.Val_int _ | Wc.Val_float _ | Wc.Val_string _
              | Wc.Val_string_list _ | Wc.Val_structured _ | Wc.Val_null ->
                Alcotest.fail ("secret field " ^ f.full_key ^ " must decode as Val_secret"))
           secret_decoded;
         let raw_keeper =
           Candle_cfg_api.config_schema_json ~base_path ~target:(Target_keeper "alpha") ()
           |> ok_or_fail "GET /api/v1/config/schema?target=keeper:alpha"
         in
         (match Wc.decode_config_schema raw_keeper with
          | Ok ks ->
            Alcotest.(check bool) "keeper target decoded" true
              (ks.target = Wc.Target_keeper "alpha");
            let keeper_fields =
              List.concat_map (fun (s : Wc.schema_section) -> s.fields) ks.sections
            in
            let keeper_keys =
              List.map (fun (f : Wc.schema_field) -> f.full_key) keeper_fields
            in
            List.iter
              (fun expected_key ->
                 Alcotest.(check bool)
                   ("keeper schema exposes " ^ expected_key)
                   true
                   (List.mem expected_key keeper_keys))
              [ "keeper.tools.native"
              ; "keeper.tools.masc_enabled"
              ; "keeper.tools.deny"
              ; "keeper.tools.attached_allow"
              ; "keeper.skills.names"
              ];
            Alcotest.(check bool)
              "legacy invalid keeper.masc_tools_enabled is absent"
              false
              (List.mem "keeper.masc_tools_enabled" keeper_keys);
            let patch_req : Wc.patch_request =
              { target = Wc.Target_keeper "alpha"
              ; keeper_name = Some "alpha"
              ; dry_run = true
              ; expected_sha256 = Some ks.file_sha256
              ; ops =
                  [ Wc.Set_scalar { table = "keeper.tools"; key = "native"; value = "read" }
                  ; Wc.Set_bool { table = "keeper.tools"; key = "masc_enabled"; value = false }
                  ; Wc.Set_string_array { table = "keeper.tools"; key = "deny"; values = [ "masc_board_post" ] }
                  ; Wc.Set_string_array { table = "keeper.skills"; key = "names"; values = [ "review" ] }
                  ]
              }
            in
            let patch_res =
              Candle_cfg_api.config_patch_json
                ~config
                ~actor:"tui-test"
                ~body_str:(Yojson.Safe.to_string (Wc.encode_patch_request patch_req))
                ()
              |> ok_or_fail "POST /api/v1/config/patch (keeper tools/skills dry_run)"
            in
            (match Wc.decode_patch_response patch_res with
             | Ok pr ->
               Alcotest.(check bool) "keeper tools/skills dry_run changed" true pr.changed;
               Alcotest.(check bool) "keeper tools/skills dry_run flag" true pr.dry_run
             | Error msg -> Alcotest.fail ("decode_patch_response failed: " ^ msg))
          | Error msg -> Alcotest.fail ("keeper schema decode failed: " ^ msg));
         let raw_create =
           Candle_cfg_api.config_schema_json ~base_path ~target:Target_keeper_create ()
           |> ok_or_fail "GET /api/v1/config/schema?target=keeper_create"
         in
         match Wc.decode_config_schema raw_create with
         | Ok cs ->
           Alcotest.(check bool) "keeper_create target decoded" true
             (cs.target = Wc.Target_keeper_create)
         | Error msg -> Alcotest.fail ("keeper_create schema decode failed: " ^ msg)))
;;

let test_quoted_model_entity_meta_roundtrip () =
  with_temp_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    let runtime_toml_path = Filename.concat base_path ".masc/config/runtime.toml" in
    write_file_raw
      runtime_toml_path
      "[providers.openrouter]\n\
       display-name = \"OpenRouter\"\n\
       base-url = \"https://openrouter.ai/api/v1\"\n\
       [providers.openrouter.headers]\n\
       \"x-api.version\" = \"2026-01\"\n\
       [models.\"gpt-5.6\"]\n\
       max_context = 256000\n";
    let schema =
      Candle_cfg_api.config_schema_json ~base_path ~target:Target_runtime ()
      |> ok_or_fail "GET /api/v1/config/schema?target=runtime"
    in
    let _decoded_schema, decoded_meta =
      match Wc.decode_config_schema_with_meta schema with
      | Ok v -> v
      | Error msg -> Alcotest.fail ("decode_config_schema_with_meta failed: " ^ msg)
    in
    let gpt_meta = List.assoc_opt "models.\"gpt-5.6\".max_context" decoded_meta in
    Alcotest.(check (option string))
      "client decoded entity_group for quoted model"
      (Some "model:gpt-5.6")
      (Option.bind gpt_meta (fun m ->
           Option.map Wc.entity_group_to_string m.entity_group)))
;;

let () =
  Alcotest.run
    "server_config_roundtrip"
    [ ( "config_schema_roundtrip"
      , [ Alcotest.test_case
            "live server config schema -> Wire_config.decode_config_schema"
            `Quick
            test_config_schema_server_to_tui_roundtrip
        ; Alcotest.test_case
            "quoted dotted model table -> Wire_config.decode_config_schema_with_meta"
            `Quick
            test_quoted_model_entity_meta_roundtrip
        ] )
    ]
;;
