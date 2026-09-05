(** Coverage tests for Tool_agent — Agent metrics, fitness, and card

    Tests dispatch routing, handler execution, helper functions for:
    masc_get_metrics, masc_agent_fitness, masc_agent_card
*)
module Tool_args = Tool_args
module Tool_result = Tool_result
module Tool_agent = Masc.Tool_agent
module Metrics_store_eio = Masc.Metrics_store_eio
module Workspace = Masc.Workspace

(* The tool-result guidance this suite asserts (the "no metrics found"
   message) moved out of the .ml sources into config/prompts/*.md group
   files, rendered through the prompt registry at result-construction time. *)
let () =
  Masc.Prompt_defaults.init ()
;;

let test_counter = ref 0

let temp_dir () =
  incr test_counter;
  let dir = Filename.temp_file
    (Printf.sprintf "test_agent_%d_" !test_counter) "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with _ -> ()

let with_ctx f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  let config = Workspace.default_config base_dir in
  ignore (Workspace.init config ~agent_name:(Some "test-agent"));
  let ctx : Tool_agent.context = { config; agent_name = "test-agent" } in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () -> f ctx)

let dispatch_exn ctx ~name ~args =
  match Tool_agent.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("dispatch returned None for " ^ name)

(* ============================================================
   Dispatch routing tests
   ============================================================ *)

let test_dispatch_unknown () =
  with_ctx (fun ctx ->
  let result = Tool_agent.dispatch ctx ~name:"unknown_tool" ~args:(`Assoc []) in
  Alcotest.(check bool) "unknown returns None" true (result = None);
  )

let test_dispatch_agent_card () =
  with_ctx (fun ctx ->
  let result = Tool_agent.dispatch ctx ~name:"masc_agent_card" ~args:(`Assoc []) in
  Alcotest.(check bool) "agent_card dispatches" true (result <> None);
  )


let test_handle_agent_card () =
  with_ctx (fun ctx ->
  let result = Tool_agent.handle_agent_card ctx (`Assoc []) in
  Alcotest.(check bool) "agent card succeeds" true (Tool_result.is_success result);
  let json = Yojson.Safe.from_string (Tool_result.message result) in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "card name" "MASC"
    (json |> member "name" |> to_string);
  Alcotest.(check string) "card schema" "masc.agent_card.v1"
    (json |> member "schema" |> to_string);
  )

let test_handle_agent_card_rejects_unknown_action () =
  with_ctx (fun ctx ->
  let result =
    Tool_agent.handle_agent_card ctx (`Assoc [("action", `String "bogus")])
  in
  Alcotest.(check bool) "agent card rejects" false (Tool_result.is_success result);
  Alcotest.(check bool) "mentions invalid action" true
    (String.contains (Tool_result.message result) 'b');
  )

(* ============================================================
   Handler tests — get_metrics
   ============================================================ *)

let test_get_metrics_no_data () =
  with_ctx (fun ctx ->
  let args = `Assoc [("agent_name", `String "nonexistent"); ("days", `Int 7)] in
  let result = dispatch_exn ctx ~name:"masc_get_metrics" ~args in
  Alcotest.(check bool) "no data fails" false (Tool_result.is_success result);
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string (Tool_result.message result) in
  Alcotest.(check string) "error_code" "not_found"
    (json |> member "error_code" |> to_string);
  Alcotest.(check string) "message" "no metrics found for agent: nonexistent"
    (json |> member "message" |> to_string);
  )

let test_get_metrics_missing_agent_name () =
  with_ctx (fun ctx ->
  let result = dispatch_exn ctx ~name:"masc_get_metrics" ~args:(`Assoc []) in
  Alcotest.(check bool) "missing agent_name fails" false (Tool_result.is_success result);
  let open Yojson.Safe.Util in
  let json = Yojson.Safe.from_string (Tool_result.message result) in
  Alcotest.(check string) "status" "error"
    (json |> member "status" |> to_string);
  Alcotest.(check string) "message" "agent_name is required"
    (json |> member "message" |> to_string);
  )

(* ============================================================
   Handler tests — agent_fitness
   ============================================================ *)

let test_agent_fitness_no_agents () =
  with_ctx (fun ctx ->
  let result = Tool_agent.handle_agent_fitness ctx (`Assoc []) in
  Alcotest.(check bool) "fitness succeeds" true (Tool_result.is_success result);
  Alcotest.(check bool) "has response" true (String.length (Tool_result.message result) > 0);
  )

let test_agent_fitness_specific () =
  with_ctx (fun ctx ->
  let args = `Assoc [("agent_name", `String "test-agent"); ("days", `Int 7)] in
  let result = Tool_agent.handle_agent_fitness ctx args in
  Alcotest.(check bool) "fitness with agent" true (Tool_result.is_success result);
  Alcotest.(check bool) "has response" true (String.length (Tool_result.message result) > 0);
  )

(* ============================================================
   Helper function tests
   ============================================================ *)

let test_get_string_present () =
  let args = `Assoc [("key", `String "value")] in
  Alcotest.(check string) "extracts string" "value"
    (Tool_args.get_string args "key" "default")

let test_get_string_missing () =
  let args = `Assoc [] in
  Alcotest.(check string) "uses default" "default"
    (Tool_args.get_string args "key" "default")

let test_get_string_opt_present () =
  let args = `Assoc [("key", `String "value")] in
  Alcotest.(check (option string)) "extracts Some" (Some "value")
    (Tool_args.get_string_opt args "key")

let test_get_string_opt_missing () =
  let args = `Assoc [] in
  Alcotest.(check (option string)) "returns None" None
    (Tool_args.get_string_opt args "key")

let test_get_int_present () =
  let args = `Assoc [("key", `Int 42)] in
  Alcotest.(check int) "extracts int" 42
    (Tool_args.get_int args "key" 0)

let test_get_int_missing () =
  let args = `Assoc [] in
  Alcotest.(check int) "uses default" 99
    (Tool_args.get_int args "key" 99)

let test_get_string_list_present () =
  let args = `Assoc [("key", `List [`String "a"; `String "b"])] in
  Alcotest.(check (list string)) "extracts list" ["a"; "b"]
    (Tool_args.get_string_list args "key")

let test_get_string_list_missing () =
  let args = `Assoc [] in
  Alcotest.(check (list string)) "empty list" []
    (Tool_args.get_string_list args "key")

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Alcotest.run "Tool_agent" [
    ("dispatch", [
      Alcotest.test_case "unknown returns None" `Quick test_dispatch_unknown;
      Alcotest.test_case "agent_card dispatches" `Quick test_dispatch_agent_card;
    ]);
    ("agents", [
      Alcotest.test_case "handle_agent_card" `Quick test_handle_agent_card;
      Alcotest.test_case "handle_agent_card rejects unknown action" `Quick
        test_handle_agent_card_rejects_unknown_action;
    ]);
    ("agent_update", [
      Alcotest.test_case "no agents" `Quick test_agent_fitness_no_agents;
      Alcotest.test_case "specific agent" `Quick test_agent_fitness_specific;
    ]);
    ("get_metrics", [
      Alcotest.test_case "no data returns not_found" `Quick test_get_metrics_no_data;
      Alcotest.test_case "missing agent_name fails" `Quick test_get_metrics_missing_agent_name;
    ]);
    ("helpers", [
      Alcotest.test_case "get_string present" `Quick test_get_string_present;
      Alcotest.test_case "get_string missing" `Quick test_get_string_missing;
      Alcotest.test_case "get_string_opt present" `Quick test_get_string_opt_present;
      Alcotest.test_case "get_string_opt missing" `Quick test_get_string_opt_missing;
      Alcotest.test_case "get_int present" `Quick test_get_int_present;
      Alcotest.test_case "get_int missing" `Quick test_get_int_missing;
      Alcotest.test_case "get_string_list present" `Quick test_get_string_list_present;
      Alcotest.test_case "get_string_list missing" `Quick test_get_string_list_missing;
    ]);
  ]
