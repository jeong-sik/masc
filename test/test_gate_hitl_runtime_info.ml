open Alcotest

let member name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some value -> value
     | None -> failf "missing field %s" name)
  | _ -> fail "expected JSON object"
;;

let has_field name = function
  | `Assoc fields -> Option.is_some (List.assoc_opt name fields)
  | _ -> false
;;

let test_nonblocking_hitl_is_available () =
  let json = Server_dashboard_http_runtime_info.gate_hitl_json () in
  check string
    "schema"
    "masc.gate_hitl.v1"
    Yojson.Safe.Util.(member "schema" json |> to_string);
  check string
    "state"
    "available"
    Yojson.Safe.Util.(member "state" json |> to_string);
  check bool
    "nonblocking"
    true
    Yojson.Safe.Util.(member "nonblocking" json |> to_bool);
  check bool "no environment kill switch" false (has_field "disable_env_key" json)
;;

(* Runtime declaration data must survive the same public inventory projection
   used by the Dashboard, independently of provider connectivity. *)
let test_default_on_effort_inventory_roundtrip () =
  let source format = Printf.sprintf
    {|[runtime]
default = "test_provider.test_model"
[providers.test_provider]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"
[models.test_model]
api-name = "test-model"
max-context = 8192
[models.test_model.capabilities]
thinking-control-format = "%s"
[test_provider.test_model]
is-default = true
|} format in
  let path = Filename.temp_file "runtime-effort-" ".toml" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
    Out_channel.with_open_bin path (fun ch -> output_string ch (source "reasoning_effort_default_on"));
    (match Runtime.init_default ~config_path:path with
     | Ok () -> () | Error detail -> fail detail);
    let inventory = Server_dashboard_http_runtime_info.runtime_inventory_json () in
    let rows = Yojson.Safe.Util.(member "providers" inventory |> to_list) in
    let row = match rows with [row] -> row | _ -> fail "expected one declared runtime" in
    let format = Yojson.Safe.Util.(row |> member "declared_spec" |> member "model"
      |> member "capabilities" |> member "thinking_control_format" |> to_string) in
    check string "inventory retains canonical default-on format" "reasoning-effort-default-on" format;
    match Runtime_toml.parse_string (source format) with
    | Error _ -> fail "projected format cannot be reloaded"
    | Ok cfg ->
      match cfg.Runtime_schema.models with
      | [{capabilities=Some caps;_}] ->
        check bool "reloaded declaration retains typed control" true
          (caps.Runtime_schema.thinking_control_format=Runtime_schema.Reasoning_effort_default_on)
      | _ -> fail "reloaded runtime lost model capabilities")
;;

let () =
  run
    "gate_hitl_runtime_info"
    [ "gate_hitl", [ test_case "available and nonblocking" `Quick test_nonblocking_hitl_is_available ]
    ; "runtime inventory", [test_case "default-on effort declaration roundtrip" `Quick
        test_default_on_effort_inventory_roundtrip] ]
;;
