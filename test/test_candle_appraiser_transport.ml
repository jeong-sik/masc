(** Exercise the production Candle consumer over its Add-on port. The port is
    scripted here; the separate package contract fixture starts the real worker. *)
open Alcotest
open Masc
module A = Candle_appraisal
module Runs = Exact_lane_run_registry
module Json = Yojson.Safe.Util
let () = Prompt_defaults.init (); Prompt_registry.set_markdown_dir "../config/prompts"
let identity : A.identity = {goal_id="original-goal";request_id="original-payout";verification_run_id="original-proof"}
let goal : A.goal = {title="Ship the connected feature";metric=Some "tests";target_value=Some "10"}
let grade = A.Grade {goal;grades=[Option.get (Candle_grade.of_string "medium"),"Connected feature"]}
let unwrap = function Ok value -> value | Error error -> fail (A.error_to_string error)
let reply id state extra =
  Ok {(Mcp_protocol.Mcp_types.tool_result_of_text "scripted Add-on reply") with
    structured_content=Some (`Assoc (["request_id",`String id;"state",`String state] @ extra))}
let operation arguments = Json.(to_string (member "kind" arguments))
let request_id arguments =
  match operation arguments with
  | "submit" -> Json.(to_string (member "request_id" (member "request" arguments)))
  | "read" -> Json.(to_string (member "request_id" arguments))
  | _ -> fail "unexpected Add-on operation"
let finished id output = reply id "finished" ["result", `Assoc [
  "status",`String "answered";"slot",`String "original-slot";"output",output;
  "usage",`Assoc ["input_tokens",`Int 12;"output_tokens",`Int 3]]]
let with_workspace f =
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "candle-addon-consumer-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path; Fs_compat.clear_fs ())
    (fun () -> f base_path)
let runner ?(installation_id="original-installation") ~registry ~base_path ~call request =
  let store = Lane_addon_store.create ~root:(Filename.concat base_path "request-ownership") in
  let retain ~request_id ~request = Lane_addon_tool_request_owner.retain ~store
    ~scope:"candle-appraisals" ~request_id ~installation_id ~package_id:"candle-appraiser" ~tool:"candle_appraise" ~request
    |> Result.map_error (function
      | Lane_addon_tool_request_owner.Store_unavailable detail -> Lane_addon_runtime.Unavailable detail
      | (Binding_conflict | Invalid_identity _ | Invalid_request _) as error -> Lane_addon_runtime.Host_refusal
        (Lane_addon_call_context.Rejected (Lane_addon_tool_request_owner.error_to_string error))) in
  Server_candle_appraiser.For_testing.run ~registry ~base_path ~retain ~call ~identity request

let test_lost_submit_reply_reads_the_retained_original_after_restart () =
  with_workspace @@ fun base_path ->
  let path = Filename.concat base_path "runs.jsonl" in
  let registry = Runs.create ~path () in
  let retained = ref None and submitted = ref 0 and ids = ref [] in
  let call ~arguments =
    let id = request_id arguments in
    ids := id :: !ids;
    let registered = match Runs.get registry ~run_id:id with
      | Some run -> run | None -> fail "the original request must be recorded before the worker RPC" in
    check bool "registration precedes RPC" true (registered.status = Runs.Running);
    let rows = In_channel.with_open_text path In_channel.input_lines |> List.map Yojson.Safe.from_string in
    check bool "registration is durable before RPC" true
      (List.exists (fun row -> Json.(member "event" row = `String "register" && member "id" row = `String id)) rows);
    match operation arguments, !retained with
    | "read", None -> reply id "absent" []
    | "submit", None ->
      incr submitted;
      retained := Some (Json.member "request" arguments);
      Error (Lane_addon_runtime.Outcome_unknown "worker reply was lost after retaining intent")
    | "read", Some _ -> finished id (`Assoc ["grade",`String "medium"])
    | _ -> fail "a retained intent must not be submitted again" in
  (match runner ~registry ~base_path ~call grade with
   | Error (A.Transport_unavailable _) -> ()
   | Ok _ | Error (A.Invalid_response _ | A.Execution_rejected _) -> fail "lost RPC must await an authoritative read");
  (* Reconstruct the consumer after a host restart. The worker's state is an
     external durable source; the observer's restarted outcome is not authority. *)
  let replayed = Runs.replay path in
  let call ~arguments =
    let id = request_id arguments in
    ids := id :: !ids;
    check string "recovery only reads the original" "read" (operation arguments);
    finished id (`Assoc ["grade",`String "medium"]) in
  let answer = runner ~registry:replayed ~base_path ~call grade |> unwrap in
  check int "the original was submitted once" 1 !submitted;
  check int "reconstruction retains one original ID" 1 (List.length (List.sort_uniq String.compare !ids));
  check string "actual answering slot becomes trace" "original-slot" answer.trace.slot_id;
  let stored = match Runs.get (Runs.replay path) ~run_id:answer.trace.run_id with
    | Some run -> run | None -> fail "completed receipt vanished" in
  let Runs.Exact_input input = stored.input in
  check string "audit metadata retains the original proof" identity.verification_run_id
    Json.(to_string (member "verification_run_id" (member "identity" input)));
  check bool "model evidence remains the original input" true
    (Yojson.Safe.equal (Json.member "input" input) (A.input grade));
  match stored.status with
  | Runs.Completed {outcome=Runs.Succeeded;selected_slot=Some "original-slot";usage=Some usage;_} ->
    check int "original input usage is retained" 12 usage.input_tokens;
    check int "original output usage is retained" 3 usage.output_tokens
  | _ -> fail "the accepted original result was not durably observed"

let test_unknown_judgment_is_terminal_even_after_an_event () =
  with_workspace @@ fun base_path ->
  let registry = Runs.create () in
  let reads = ref 0 in
  let call ~arguments =
    incr reads;
    check string "a terminal original is only read" "read" (operation arguments);
    reply (request_id arguments) "finished" ["result", `Assoc ["status",`String "outcome_unknown"]] in
  List.iter (fun () -> match runner ~registry ~base_path ~call grade with
    | Error (A.Execution_rejected _) -> ()
    | Ok _ | Error (A.Transport_unavailable _ | A.Invalid_response _) -> fail "unknown judgment became retryable or accepted") [();();()];
  check int "events re-read without new submission" 3 !reads;
  match Runs.list_runs registry with
  | [run] -> (match run.status with
      | Runs.Completed {outcome=Runs.Failed {code="candle_appraisal_outcome_unknown";_};_} -> ()
      | _ -> fail "uncertainty lost its observer status")
  | _ -> fail "one original judgment must retain one observer identity"

let stored_run registry run_id =
  match Runs.get registry ~run_id with
  | Some run -> run
  | None -> fail "the original observer run disappeared"

let test_terminal_reread_and_restart_preserve_the_first_receipt () =
  with_workspace @@ fun base_path ->
  let path = Filename.concat base_path "runs.jsonl" in
  let registry = Runs.create ~path () in
  let call ~arguments =
    check string "retained completion is only read" "read" (operation arguments);
    finished (request_id arguments) (`Assoc ["grade",`String "medium"]) in
  let answer = runner ~registry ~base_path ~call grade |> unwrap in
  let original = stored_run registry answer.trace.run_id |> Runs.run_to_yojson in
  let verify registry =
    let before = Fs_compat.load_file path in
    ignore (runner ~registry ~base_path ~call grade |> unwrap);
    check string "reread does not append another completion" before (Fs_compat.load_file path);
    check bool "first elapsed, output, slot and usage survive" true
      (Yojson.Safe.equal original (stored_run registry answer.trace.run_id |> Runs.run_to_yojson)) in
  verify registry;
  verify (Runs.replay path)

let test_failed_receipt_append_retries_the_first_terminal_time () =
  with_workspace @@ fun base_path ->
  let path = Filename.concat base_path "runs.jsonl" in
  let registry = Runs.create ~path () in
  let registration = ref None and original_id = ref None in
  let break_append ~arguments =
    check string "failure does not submit a new model request" "read" (operation arguments);
    let id = request_id arguments in
    original_id := Some id;
    registration := Some (Fs_compat.load_file path);
    Sys.remove path;
    Unix.mkdir path 0o700;
    finished id (`Assoc ["grade",`String "medium"]) in
  (match runner ~registry ~base_path ~call:break_append grade with
   | Error (A.Transport_unavailable _) -> ()
   | Ok _ | Error (A.Invalid_response _ | A.Execution_rejected _) ->
     fail "a failed receipt append was not reported");
  let id = match !original_id with Some id -> id | None -> fail "worker was not read" in
  let first_elapsed = match (stored_run registry id).status with
    | Runs.Completion_persistence_failed {elapsed_s;_} -> elapsed_s
    | Runs.Running | Runs.Completed _ -> fail "failed receipt was not retained" in
  Unix.rmdir path;
  let registration = match !registration with
    | Some bytes -> bytes | None -> fail "registration was not captured" in
  Fs_compat.save_file path registration;
  let call ~arguments =
    check string "receipt recovery only reads" "read" (operation arguments);
    finished (request_id arguments) (`Assoc ["grade",`String "medium"]) in
  ignore (runner ~registry ~base_path ~call grade |> unwrap);
  match (stored_run (Runs.replay path) id).status with
  | Runs.Completed {elapsed_s;outcome=Runs.Succeeded;_} ->
    check (float 0.) "append recovery retains first terminal time" first_elapsed elapsed_s
  | Runs.Running | Runs.Completion_persistence_failed _
  | Runs.Completed {outcome=(Runs.Cancelled | Runs.Failed _);_} ->
    fail "the original successful result was not durably recovered"

let test_missing_terminal_payload_is_not_silently_repaired_by_reread () =
  with_workspace @@ fun base_path ->
  let path = Filename.concat base_path "runs.jsonl" in
  let registry = Runs.create ~path () in
  let call ~arguments = finished (request_id arguments) (`Assoc ["grade",`String "medium"]) in
  let answer = runner ~registry ~base_path ~call grade |> unwrap in
  let original = stored_run registry answer.trace.run_id in
  let output = match original.status with
    | Runs.Completed {output;_} -> output
    | Runs.Running | Runs.Completion_persistence_failed _ -> fail "original did not complete" in
  let text = Yojson.Safe.to_string output in
  let digest = Digestif.SHA256.(digest_string text |> to_hex) in
  let payload = Filename.concat
      (Filename.concat (Filename.concat base_path Runs.payload_dirname) answer.trace.run_id)
      ("output-" ^ digest ^ ".json") in
  Sys.remove payload;
  let before = Fs_compat.load_file path in
  (match runner ~registry ~base_path ~call grade with
   | Error (A.Transport_unavailable _) -> ()
   | Ok _ | Error (A.Invalid_response _ | A.Execution_rejected _) ->
     fail "an unreadable terminal receipt was accepted or overwritten");
  check string "missing output does not append a replacement receipt" before (Fs_compat.load_file path);
  check bool "missing evidence is still explicit" true
    ((stored_run registry answer.trace.run_id).output_availability =
      Some (Runs.Unavailable Runs.Missing_completion));
  Fs_compat.save_file payload text;
  ignore (runner ~registry ~base_path ~call grade |> unwrap);
  check bool "restored original evidence preserves the first receipt" true
    (Yojson.Safe.equal (Runs.run_to_yojson original)
      (stored_run registry answer.trace.run_id |> Runs.run_to_yojson))

let test_a_replacement_cannot_replay_an_unknown_original () =
  with_workspace @@ fun base_path ->
  let unknown ~arguments =
    reply (request_id arguments) "finished" ["result", `Assoc ["status",`String "outcome_unknown"]] in
  (match runner ~installation_id:"installation-a" ~registry:(Runs.create ()) ~base_path ~call:unknown grade with
   | Error (A.Execution_rejected _) -> ()
   | Ok _ | Error (A.Transport_unavailable _ | A.Invalid_response _) -> fail "original unknown must be terminal");
  (* Drop all observer state and reconstruct the adapter. Durable original
     ownership, not the old observer's terminal row, still fences dispatch. *)
  let contacted_replacement = ref false in
  let absent ~arguments = contacted_replacement := true; reply (request_id arguments) "absent" [] in
  (match runner ~installation_id:"installation-b" ~registry:(Runs.create ()) ~base_path ~call:absent grade with
   | Error (A.Execution_rejected _) -> ()
   | Ok _ | Error (A.Transport_unavailable _ | A.Invalid_response _) -> fail "a fresh replacement claimed the original");
  check bool "replacement is refused before any RPC" false !contacted_replacement;
  (match runner ~installation_id:"installation-a" ~registry:(Runs.create ()) ~base_path ~call:unknown grade with
   | Error (A.Execution_rejected _) -> ()
   | Ok _ | Error (A.Transport_unavailable _ | A.Invalid_response _) -> fail "original installation lost its retained terminal")

let test_domain_decode_rejects_incomplete_recipient_weights () =
  with_workspace @@ fun base_path ->
  let registry = Runs.create () in
  let request = A.Weights {goal;tasks=[];keepers=["keeper-a";"keeper-b"];weight_max=10} in
  let call ~arguments = finished (request_id arguments)
      (`Assoc ["weights",`Assoc ["keeper-a",`Int 1]]) in
  match runner ~registry ~base_path ~call request with
  | Error (A.Invalid_response _) -> ()
  | Ok _ | Error (A.Transport_unavailable _ | A.Execution_rejected _) -> fail "partial weights escaped full Candle decoding"

let test_capacity_wait_does_not_invent_a_retained_intent () =
  with_workspace @@ fun base_path ->
  let registry = Runs.create () in
  let operations = ref [] in
  let call ~arguments =
    let kind = operation arguments in
    operations := !operations @ [kind];
    match kind with
    | "read" -> reply (request_id arguments) "absent" []
    | "submit" -> reply (request_id arguments) "capacity_wait" []
    | _ -> fail "unexpected operation" in
  List.iter (fun () -> match runner ~registry ~base_path ~call grade with
    | Error (A.Transport_unavailable _) -> ()
    | Ok _ | Error (A.Invalid_response _ | A.Execution_rejected _) -> fail "capacity must await admission") [();()];
  check (list string) "every retry reads first" ["read";"submit";"read";"submit"] !operations

let test_malformed_worker_state_cannot_authorize_submission () =
  with_workspace @@ fun base_path ->
  let registry = Runs.create () in
  List.iter (fun malformed ->
    let calls = ref 0 in
    let call ~arguments =
      incr calls;
      check string "malformed read cannot cause submit" "read" (operation arguments);
      let id = request_id arguments in
      let json = malformed id in
      Ok {(Mcp_protocol.Mcp_types.tool_result_of_text "malformed") with structured_content=Some json} in
    (match runner ~registry ~base_path ~call grade with
     | Error (A.Invalid_response _) -> ()
     | Ok _ | Error (A.Transport_unavailable _ | A.Execution_rejected _) -> fail "malformed state was accepted");
    check int "exactly one read" 1 !calls)
    [(fun _ -> `Assoc ["request_id",`String "other";"state",`String "absent"]);
     (fun id -> `Assoc ["request_id",`String id;"state",`String "absent";"result",`Null]);
     (fun id -> `Assoc ["request_id",`String id;"state",`String "absent";"state",`String "finished"]);
     (fun id -> `Assoc ["request_id",`String id;"state",`String "future_state"])]

let test_missing_prompt_never_calls_the_worker () =
  with_workspace @@ fun base_path ->
  let empty = Filename.concat base_path "prompts" in
  Fs_compat.mkdir_p empty;
  let called = ref false in
  let call ~arguments:_ = called := true; fail "missing prompt reached worker" in
  Fun.protect ~finally:(fun () -> Prompt_registry.set_markdown_dir "../config/prompts") (fun () ->
    Prompt_registry.set_markdown_dir empty;
    match runner ~registry:(Runs.create ()) ~base_path ~call grade with
    | Error (A.Transport_unavailable _) -> check bool "no worker RPC" false !called
    | Ok _ | Error (A.Invalid_response _ | A.Execution_rejected _) -> fail "missing prompt is a source failure")

let () = run "Candle Add-on consumer"
  ["original judgment", [
    test_case "lost submit reply resumes original after restart" `Quick test_lost_submit_reply_reads_the_retained_original_after_restart;
    test_case "unknown judgment stays terminal" `Quick test_unknown_judgment_is_terminal_even_after_an_event;
    test_case "terminal reread and restart preserve first receipt" `Quick test_terminal_reread_and_restart_preserve_the_first_receipt;
    test_case "failed receipt append retains first terminal time" `Quick test_failed_receipt_append_retries_the_first_terminal_time;
    test_case "missing terminal payload stays unavailable" `Quick test_missing_terminal_payload_is_not_silently_repaired_by_reread;
    test_case "replacement cannot replay an unknown original" `Quick test_a_replacement_cannot_replay_an_unknown_original;
    test_case "full Candle decoding checks every recipient" `Quick test_domain_decode_rejects_incomplete_recipient_weights;
    test_case "capacity admission always reads first" `Quick test_capacity_wait_does_not_invent_a_retained_intent;
    test_case "malformed state cannot authorize submit" `Quick test_malformed_worker_state_cannot_authorize_submission;
    test_case "missing prompt never reaches worker" `Quick test_missing_prompt_never_calls_the_worker]]
