(** Gate's HTTP projection must describe CLI-only and mixed judge routes. *)
module Registry = Runtime_exact_output_registry
module Exact = Agent_core.Exact_output
open Alcotest

let catalog = {|[[providers]]
id = "fixture"
kind = "openai_compat"
base_url = "http://127.0.0.1:1"
request_path = "/v1/chat/completions"
api_key_env = ""
capabilities_base = "openai_chat_extended"

[[models]]
id_prefix = "fixture-model"
provider_name = "fixture"
max_context_tokens = 8192
max_output_tokens = 1024
supports_response_format_json = true
supports_structured_output = false
input_per_million = 1.0

[[targets]]
id = "fixture-http"
provider_ref = "fixture"
model_id = "fixture-model"
|}

let snapshot () =
  match Exact.load_resolver_snapshot
    ~io:{ getenv = (fun _ -> Ok None) }
    ~catalog:(Exact.Full_replacement { source = "<gate-projection-test>"; contents = catalog }) () with
  | Ok snapshot -> snapshot
  | Error _ -> fail "fixture exact catalog did not load"

let project lanes =
  (match Registry.publish ~required_lane_ids:[] ~lanes (snapshot ()) with
   | Ok _ -> ()
   | Error error -> fail (Registry.publication_error_to_string error));
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let root = Filename.temp_file "gate-cli-projection" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) @@ fun () ->
  let json = Dashboard_gate.dashboard_json ~base_path:root ~limit:10 ~window_minutes:60 in
  Yojson.Safe.Util.(json |> member "hitl" |> member "judge_lane")

let lane slot_ids cli_slot_ids : Runtime_schema.exact_output_lane_decl =
  { id = Masc.Hitl_summary_worker.lane_id; slot_ids; cli_slot_ids }

let assert_slots expected json =
  let open Yojson.Safe.Util in
  check string "configured lane is available" "available" (json |> member "status" |> to_string);
  check (list string) "route order includes official clients" expected
    (json |> member "slots" |> to_list |> List.map to_string)

let () =
  run "Dashboard Gate CLI lane"
    [ "projection",
      [ test_case "CLI-only lane keeps its route identities" `Quick (fun () ->
          project [lane [] ["codex.primary"; "claude.backup"]]
          |> assert_slots ["codex.primary"; "claude.backup"])
      ; test_case "HTTP precedes CLI fallbacks" `Quick (fun () ->
          project [lane ["fixture-http"] ["codex.primary"]]
          |> assert_slots ["fixture-http"; "codex.primary"])
      ; test_case "unconfigured lane remains unavailable" `Quick (fun () ->
          let json = project [] in
          check string "no false ready state" "unavailable"
            Yojson.Safe.Util.(json |> member "status" |> to_string))
      ] ]
