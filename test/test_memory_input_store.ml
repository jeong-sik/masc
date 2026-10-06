open Alcotest
open Turn_record

let turn_ref trace turn = Ids.Turn_ref.make ~trace_id:trace ~absolute_turn:turn

let record ?(blocks = []) ?input_components ?(usage_scope = Runtime_usage_scope.Per_request)
    ~trace ~turn () : Turn_record.t =
  { execution_ids = []
  ; keeper = "omega"
  ; agent_name = "keeper-omega"
  ; turn_kind = Direct
  ; trace_id = trace
  ; absolute_turn = turn
  ; turn_ref = turn_ref trace turn
  ; blocks
  ; input_components
  ; tool_surface_ref = None
  ; runtime_profile = "glm-coding"
  ; selected_model = Some "glm-5.3"
  ; finish_reason = Some "stop"
  ; context_window = Some 200_000
  ; provider_context_window = None
  ; price_input_per_million = None
  ; price_output_per_million = None
  ; request_latency_ms = Some 1200
  ; ttfrc_ms = Some 80.
  ; request_wire_observation =
      Some { runtime_profile = "glm-coding"; body_bytes = 4096 }
  ; model_input_window =
      Some
        { transmitted_atoms = 3
        ; total_atoms = 4
        ; measurement = Wire_shape
        ; model_input_front = Model_input_front.At_atom (String.make 64 'c')
        }
  ; response_observed_model_input = None
  ; raw_trace_run_ref = None
  ; sampling =
      { temperature = Some 0.2
      ; top_p = None
      ; max_tokens = None
      ; enable_thinking = Some true
      }
  ; usage =
      { input_tokens = Some 1000
      ; output_tokens = Some 200
      ; cache_creation_input_tokens = None
      ; cache_read_input_tokens = Some 500
      ; scope = usage_scope
      }
  ; turn_output_tokens = None
  ; ts = 1_787_600_000.
  }

let with_store fn =
  let root = Filename.temp_dir "memory-input-store-" "" in
  let month = Filename.concat root "2026-10" in
  Unix.mkdir month 0o700;
  let path = Filename.concat month "04.jsonl" in
  let store = Dated_jsonl.create ~base_dir:root () in
  Fun.protect ~finally:(fun () ->
    if Sys.file_exists path then
      if Sys.is_directory path then Unix.rmdir path else Sys.remove path;
    Unix.rmdir month; Unix.rmdir root)
    (fun () -> fn store path)

let write path text =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel text)

(* Use the API's production reader and its existing page fields, then the
   actual TUI decoder. The filesystem failure must survive that boundary. *)
let page store limit =
  match Server_keeper_turn_records.read ~store ~limit with
  | Error error -> Error error
  | Ok (records, skipped) ->
    Ok (`Assoc ["keeper", `String "omega"; "skipped_rows", `Int skipped;
      "entries", `List (List.map (fun r -> `Assoc ["record", Turn_record.to_json r]) records)])

let test_corrupt_latest_is_not_an_older_input () =
  with_store (fun store path ->
    let valid = Turn_record.to_json (record ~trace:"trace-store" ~turn:1 ())
      |> Yojson.Safe.to_string in
    write path (valid ^ "\n{\"absolute_turn\":2,\"input_tokens\":");
    check int "old permissive route silently substitutes a valid row" 1
      (List.length (Dated_jsonl.read_recent store 50));
    List.iter (fun limit ->
      match page store limit with
      | Error e -> fail (Dated_jsonl.read_error_to_string e)
      | Ok json ->
        match Masc_tui_memory_usage.decode ~keeper:"omega" json with
        | Error _ -> ()
        | Ok _ -> fail "truncated latest row became apparently current statistics") [1; 50])

let test_storage_failure_is_not_empty_memory () =
  with_store (fun store path ->
    Unix.mkdir path 0o700;
    match page store 50 with
    | Error _ -> ()
    | Ok _ -> fail "unreadable turn store became a successful empty page")

let test_valid_store_reaches_input_summary () =
  with_store (fun store path ->
    let first = record ~trace:"trace-store" ~turn:1 () in
    let last = { first with absolute_turn = 2; turn_ref = turn_ref "trace-store" 2;
      usage = { first.usage with input_tokens = Some 3000 } } in
    write path (String.concat "\n" (List.map (fun r -> Yojson.Safe.to_string (Turn_record.to_json r)) [first; last]) ^ "\n");
    match page store 50 with
    | Error e -> fail (Dated_jsonl.read_error_to_string e)
    | Ok json ->
      match Masc_tui_memory_usage.decode ~keeper:"omega" json with
      | Error e -> fail e
      | Ok summary ->
        check (option int) "latest physical request" (Some 3000) summary.tokens.last;
        let distribution = Option.get summary.tokens.distribution in
        check (float 0.001) "whole recent input mean" 2000. distribution.mean;
        check int "all valid requests counted" 2 distribution.samples)

let () =
  Eio_main.run (fun _ ->
    run "Memory input storage boundary"
      ["recorded input", [
        test_case "corrupt latest cannot become older input" `Quick test_corrupt_latest_is_not_an_older_input;
        test_case "storage failure is not empty" `Quick test_storage_failure_is_not_empty_memory;
        test_case "valid store reaches input summary" `Quick test_valid_store_reaches_input_summary]])
