(* Manual provider evidence. No browser, Keeper loop or live config mutation.
   Only [emit] writes the shareable JSONL; provider stderr is private. *)
open Masc
module Model = Browser_stagehand_model
module Registry = Runtime_exact_output_registry
module Exact = Agent_core.Exact_output

type fixture = Extract | Progress | Act
type route = Primary | Fallback | Injected_primary_then_fallback
type failure = Model_refused of int | Envelope_invalid | Shape_invalid
             | Semantics_invalid | Injection_missing | Unexpected_exception

let fixture_name = function Extract -> "extract" | Progress -> "progress" | Act -> "act"
let route_name = function
  | Primary -> "primary_only"
  | Fallback -> "fallback_only"
  | Injected_primary_then_fallback -> "synthetic_primary_503_then_real_fallback"
let failure_name = function
  | Model_refused _ -> "model_rpc_refused"
  | Envelope_invalid -> "answer_envelope_invalid"
  | Shape_invalid -> "fixture_shape_invalid"
  | Semantics_invalid -> "fixture_semantics_invalid"
  | Injection_missing -> "injected_primary_not_observed"
  | Unexpected_exception -> "unexpected_exception"

let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None
let string = function Some (`String value) -> Some value | _ -> None
let nonempty = function Some (`String value) -> String.trim value <> "" | _ -> false
let keys_exact names = function
  | `Assoc fields -> List.sort String.compare (List.map fst fields) = List.sort String.compare names
  | _ -> false

let element_id_shape = function
  | Some (`String id) ->
      let digits part = part <> "" && String.for_all (function '0' .. '9' -> true | _ -> false) part in
      (match String.split_on_char '-' id with [frame; node] -> digits frame && digits node | _ -> false)
  | _ -> false

(* These are the three recorded fixture contracts, not a general JSON Schema
   implementation. Shape and task correctness are counted independently. *)
let validate fixture value =
  let shape, semantic = match fixture with
    | Extract ->
        (Option.is_some (string (field "heading" value))
         && Option.is_some (string (field "price" value)),
         field "heading" value = Some (`String "Order form")
         && field "price" value = Some (`String "42 USD"))
    | Progress ->
        (keys_exact ["progress"; "completed"] value
         && Option.is_some (string (field "progress" value))
         && (match field "completed" value with Some (`Bool _) -> true | _ -> false),
         nonempty (field "progress" value) && field "completed" value = Some (`Bool true))
    | Act ->
        let action_shape, action_semantic = match field "action" value with
          | Some `Null -> true, false
          | Some (`Assoc _ as action) ->
              (keys_exact ["elementId"; "description"; "method"; "arguments"] action
               && element_id_shape (field "elementId" action)
               && Option.is_some (string (field "description" action))
               && (match string (field "method" action) with
                   | Some ("click" | "fill" | "type" | "press" | "scrollTo"
                          | "nextChunk" | "prevChunk" | "selectOptionFromDropdown"
                          | "hover" | "doubleClick" | "dragAndDrop") -> true
                   | Some _ | None -> false)
               && (match field "arguments" action with
                   | Some (`List values) -> List.for_all (function `String _ -> true | _ -> false) values
                   | _ -> false),
               field "elementId" action = Some (`String "0-18")
               && field "method" action = Some (`String "click")
               && field "arguments" action = Some (`List [])
               && nonempty (field "description" action))
          | _ -> false, false
        in
        (keys_exact ["action"; "twoStep"] value && action_shape
         && (match field "twoStep" value with Some (`Bool _) -> true | _ -> false),
         action_semantic && field "twoStep" value = Some (`Bool false))
  in
  if not shape then Error Shape_invalid
  else if not semantic then Error Semantics_invalid else Ok ()

let answer_value answer =
  match field "role" answer, field "output_format" answer,
        field "content" answer, field "structured_content" answer with
  | Some (`String "assistant"), Some (`String "json_schema"), Some content, Some value ->
      (match field "type" content, string (field "text" content) with
       | Some (`String "text"), Some text ->
           (match Yojson.Safe.from_string text with
            | parsed when parsed = value -> Ok value
            | _ -> Error Envelope_invalid
            | exception Yojson.Json_error _ -> Error Envelope_invalid)
       | _ -> Error Envelope_invalid)
  | _ -> Error Envelope_invalid

exception Setup of string
let reject category = raise (Setup category)

let load_fixtures path =
  let params = match Yojson.Safe.from_file path with
    | `List [extract; progress; act] -> [Extract, extract; Progress, progress; Act, act]
    | _ -> reject "fixture_count_invalid"
  in
  List.iter (fun (fixture, params) ->
    let expected = match fixture with Extract -> "Extraction" | Progress -> "Metadata" | Act -> "Act" in
    match Model.parse_params params with
    | Ok {generation = Model.Structured {name; _}; _} when name = expected -> ()
    | Ok _ | Error _ -> reject "fixture_protocol_invalid") params;
  params

let lane_pair () =
  let registry = match Registry.current () with Ok r -> r | Error _ -> reject "registry_unavailable" in
  let lane_id = Standalone_lane.to_id Standalone_lane.Browser_stagehand in
  let declared = match Registry.declared_lane registry ~lane_id with
    | Some {slot_ids = [first; second]; cli_slot_ids = []; _} -> first, second
    | Some _ | None -> reject "lane_requires_exactly_two_http_slots_no_cli"
  in
  match Registry.resolve_lane registry ~lane_id with
  | Ok ({selected_slots = [first; second]; cli_slots = []} as lane)
      when declared = (first.slot_id, second.slot_id) ->
      (match Model.admit_lane lane with
       | Ok {http_slots = [_; _]; cli_slots = []; refused_slots = []} -> first, second
       | Ok _ | Error _ -> reject "lane_model_capability_refused")
  | Ok _ | Error _ -> reject "lane_declared_slots_not_both_admitted"

let slot_json (slot : Registry.selected_slot) =
  let projected = Exact.projection_target slot.admitted_target in
  `Assoc ["slot_id", `String slot.slot_id; "model_id", `String projected.config.model_id]

(* Only the first slot of the injected route is synthetic. This loopback
   server never forwards requests, never receives provider credentials, and
   never returns a successful model answer. The real fallback is unchanged. *)
let injected_slot ~sw ~net ~timeout_s ~primary_id =
  let requests = ref 0 and server_errors = ref 0 in
  let socket = Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port | _ -> reject "injection_listener_invalid"
  in
  let callback _conn _request body =
    ignore (Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all));
    incr requests;
    Cohttp_eio.Server.respond_string ~status:`Service_unavailable
      ~headers:(Cohttp.Header.init_with "content-type" "application/json")
      ~body:{|{"error":{"message":"manual probe injected refusal","type":"server_error"}}|} ()
  in
  let server = Cohttp_eio.Server.make ~callback () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> incr server_errors));
  let contents = Printf.sprintf
    "[[providers]]\nid = \"probe-injected\"\nkind = \"openai_compat\"\nbase_url = \"http://127.0.0.1:%d\"\nrequest_path = \"/v1/chat/completions\"\napi_key_env = \"\"\n\n[[models]]\nid_prefix = \"probe-model\"\nprovider_name = \"probe-injected\"\nmax_context_tokens = 65536\nmax_output_tokens = 4096\nsupports_response_format_json = true\nsupports_structured_output = true\nsupports_system_prompt = true\n\n[[targets]]\nid = %S\nprovider_ref = \"probe-injected\"\nmodel_id = \"probe-model\"\nconnect_timeout_s = %g\nbody_timeout_s = %g\n"
    port primary_id timeout_s timeout_s in
  let snapshot = match Exact.load_resolver_snapshot
      ~io:{getenv = (fun _ -> Ok None)}
      ~catalog:(Exact.Full_replacement {source = "manual probe injection"; contents}) () with
    | Ok snapshot -> snapshot | Error _ -> reject "injection_catalog_rejected"
  in
  let admitted_target = match Exact.admit_target_ref snapshot primary_id with
    | Ok target -> target | Error _ -> reject "injection_target_rejected"
  in
  ({Registry.slot_id = primary_id; admitted_target}, requests, server_errors)

let emit channel json = output_string channel (Yojson.Safe.to_string json ^ "\n"); flush channel
let json_result = function
  | Ok () -> `String "valid"
  | Error failure -> `String (failure_name failure)

(* Loading runtimes and publishing Exact lanes are separate production boot
   steps. Both paths below use the same publication boundary as the server;
   the probe's setup test must reach it before any model callback can run. *)
let initialize_runtime ~env ~config =
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_context.set_env env;
  Eio_context.set_clock (Eio.Stdenv.clock env);
  (match Runtime.init_default_strict_report ~config_path:config with
   | Ok () -> ()
   | Error (Runtime.Runtime_config_error _) -> reject "runtime_config_rejected"
   | Error (Runtime.Missing_catalog_models _) -> reject "runtime_catalog_models_missing");
  (try
     Server_runtime_bootstrap.For_testing.configure_exact_output_registry
       ~config_path:config ()
   with Env_config_core.Config_error _ -> reject "registry_publication_rejected");
  lane_pair ()

let run ~env ~sw ~config ~base_path ~fixtures ~repetitions ~injection_timeout_s channel =
  let source_commit = match Build_identity.embedded_commit with
    | Some commit -> commit | None -> reject "embedded_source_commit_required"
  in
  let primary, fallback = initialize_runtime ~env ~config in
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  let injected, requests, server_errors = injected_slot ~sw ~net
      ~timeout_s:injection_timeout_s ~primary_id:primary.slot_id in
  emit channel (`Assoc ["kind", `String "manifest"; "schema_version", `Int 1;
    "source_commit", `String source_commit;
    "primary", slot_json primary; "fallback", slot_json fallback;
    "repetitions", `Int repetitions;
    "injection", `String "primary transport replaced by credential-free loopback HTTP 503; fallback is real";
    "validation", `String "recorded fixture shape plus semantic contract; not general JSON Schema validation"]);
  let all_valid = ref true in
  List.iter (fun route ->
    let selected_slots = match route with Primary -> [primary] | Fallback -> [fallback]
      | Injected_primary_then_fallback -> [injected; fallback] in
    let resolve_lane () = Ok {Registry.selected_slots; cli_slots = []} in
    List.iter (fun (fixture, params) ->
      let valid = ref 0 and shape_valid = ref 0 in
      for trial = 1 to repetitions do
        let before = !requests and errors_before = !server_errors in
        let started = Eio.Time.now clock in
        let result =
          match Model.create ~net ~clock ~base_path ~resolve_lane params with
          | Error error -> Error (Model_refused error.Browser_stagehand_wire.code)
          | Ok answer -> Result.bind (answer_value answer) (validate fixture)
          | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
          | exception _ -> Error Unexpected_exception
        in
        (match result with Ok () | Error Semantics_invalid -> incr shape_valid | Error _ -> ());
        let result = match route with
          | Injected_primary_then_fallback when !requests <= before || !server_errors <> errors_before ->
              Error Injection_missing
          | Primary | Fallback | Injected_primary_then_fallback -> result
        in
        (match result with Ok () -> incr valid | Error _ -> all_valid := false);
        emit channel (`Assoc ["kind", `String "trial"; "route", `String (route_name route);
          "fixture", `String (fixture_name fixture); "trial", `Int trial;
          "elapsed_s", `Float (Eio.Time.now clock -. started); "result", json_result result;
          "rpc_error_code", (match result with Error (Model_refused code) -> `Int code | _ -> `Null);
          "synthetic_primary_requests", `Int (!requests - before)])
      done;
      emit channel (`Assoc ["kind", `String "summary"; "route", `String (route_name route);
        "fixture", `String (fixture_name fixture); "attempts", `Int repetitions;
        "shape_valid", `Int !shape_valid; "valid", `Int !valid;
        "attempt_unit", `String "Model.create invocation; not a provider dispatch count"])
    ) fixtures
  ) [Primary; Fallback; Injected_primary_then_fallback];
  !all_valid

let self_test fixtures =
  let extract = `Assoc ["heading", `String "Order form"; "price", `String "42 USD"] in
  let progress = `Assoc ["progress", `String "heading and price extracted"; "completed", `Bool true] in
  let action = `Assoc ["elementId", `String "0-18"; "description", `String "Submit order";
                       "method", `String "click"; "arguments", `List []] in
  let act = `Assoc ["action", action; "twoStep", `Bool false] in
  let require ok = if not ok then reject "validation_self_test_failed" in
  require (List.length fixtures = 3);
  List.iter (fun (fixture, value) ->
    require (validate fixture value = Ok ());
    require (validate fixture (`Assoc []) = Error Shape_invalid))
    [Extract, extract; Progress, progress; Act, act];
  require (validate Extract (`Assoc ["heading", `String "wrong"; "price", `String "42 USD"]) = Error Semantics_invalid);
  require (validate Progress (`Assoc ["progress", `String "read"; "completed", `Bool false]) = Error Semantics_invalid);
  require (validate Act (`Assoc ["action", `Null; "twoStep", `Bool false]) = Error Semantics_invalid);
  let action_with key value = match action with
    | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
    | _ -> reject "validation_self_test_failed"
  in
  let act_with_action value = `Assoc ["action", value; "twoStep", `Bool false] in
  require (validate Act (act_with_action (action_with "elementId" (`String "not-an-id"))) = Error Shape_invalid);
  require (validate Act (act_with_action (action_with "elementId" (`String "0-3"))) = Error Semantics_invalid);
  require (validate Act (act_with_action (action_with "arguments" (`List [`Int 1]))) = Error Shape_invalid);
  require (validate Progress (`Assoc ["progress", `String "read"; "completed", `Bool true; "extra", `Null]) = Error Shape_invalid);
  let envelope text = `Assoc ["role", `String "assistant"; "output_format", `String "json_schema";
    "content", `Assoc ["type", `String "text"; "text", `String text]; "structured_content", extract] in
  require (answer_value (envelope (Yojson.Safe.to_string extract)) = Ok extract);
  require (answer_value (envelope "{}") = Error Envelope_invalid);
  require (answer_value (`Assoc []) = Error Envelope_invalid)

let () =
  let config = ref "" and base_path = ref "" and fixture_path = ref "" and output = ref "" in
  let repetitions = ref 0 and injection_timeout_s = ref 0. and check_only = ref false in
  let publication_only = ref false in
  Arg.parse
    ["--config", Arg.Set_string config, "isolated runtime.toml";
     "--base-path", Arg.Set_string base_path, "isolated workspace base path";
     "--fixtures", Arg.Set_string fixture_path, "recorded llm-generate-params.json";
     "--output", Arg.Set_string output, "new secret-free JSONL file (must not exist)";
     "--repetitions", Arg.Set_int repetitions, "positive invocation count per fixture per route";
     "--injection-timeout-s", Arg.Set_float injection_timeout_s, "positive loopback test transport deadline";
     "--self-test", Arg.Set check_only, "validate fixtures and offline validator controls only";
     "--config-publication-self-test", Arg.Set publication_only,
       "load isolated config and publish/admit its two-slot lane without model calls"]
    (fun _ -> reject "unexpected_cli_argument") "stagehand_model_probe";
  try
    if !publication_only then begin
      if !config = "" || !check_only then reject "publication_test_requires_config_only";
      Eio_main.run (fun env ->
        let primary, fallback = initialize_runtime ~env ~config:!config in
        if primary.slot_id = fallback.slot_id then reject "publication_test_slots_not_distinct");
      print_endline "runtime configuration and Exact lane publication: passed (no model callbacks)"
    end else begin
    if !fixture_path = "" then reject "fixtures_required";
    let fixtures = load_fixtures !fixture_path in
    if !check_only then (self_test fixtures; print_endline "fixture validators: passed")
    else begin
      if !config = "" || !base_path = "" || !output = "" || !repetitions <= 0
         || not (Float.is_finite !injection_timeout_s) || !injection_timeout_s <= 0.
      then reject "explicit_config_base_output_repetitions_and_injection_deadline_required";
      let fd = Unix.openfile !output [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL] 0o600 in
      let channel = Unix.out_channel_of_descr fd in
      let ok = Fun.protect ~finally:(fun () -> close_out channel) (fun () ->
        Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
          run ~env ~sw ~config:!config ~base_path:!base_path ~fixtures
            ~repetitions:!repetitions ~injection_timeout_s:!injection_timeout_s channel))) in
      if not ok then exit 1
    end
    end
  with
  | Setup category -> prerr_endline category; exit 2
  | Sys_error _ | Unix.Unix_error _ | Yojson.Json_error _ ->
      prerr_endline "probe_input_or_output_unavailable"; exit 2
