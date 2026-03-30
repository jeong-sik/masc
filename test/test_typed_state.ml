(** test_typed_state — Conformance tests for PoC-3 phantom type + GADT.

    Verifies:
    - Phantom-typed task status transitions (compile-time + runtime)
    - Wire roundtrip compatibility (typed <-> wire <-> JSON)
    - GADT action state (preview -> confirm lifecycle)
    - Rich validation error formatting *)

open Alcotest

module TS = Typed_state

(* ── Phantom-typed task status ────────────────────────── *)

let test_todo_is_active () =
  let status = TS.todo () in
  check string "todo name" "todo" (TS.status_name status);
  let wire = TS.to_wire status in
  match wire with
  | Types_core.Todo -> ()
  | _ -> fail "expected Todo wire status"

let test_claim_transition () =
  let t = TS.todo () in
  let claimed = TS.claim t ~agent:"alice" in
  check string "claimed name" "claimed" (TS.status_name claimed);
  match TS.to_wire claimed with
  | Types_core.Claimed { assignee; _ } ->
    check string "assignee" "alice" assignee
  | _ -> fail "expected Claimed wire status"

let test_start_transition () =
  let t = TS.todo () in
  let claimed = TS.claim t ~agent:"bob" in
  let in_progress = TS.start claimed in
  check string "in_progress name" "in_progress" (TS.status_name in_progress);
  match TS.to_wire in_progress with
  | Types_core.InProgress { assignee; _ } ->
    check string "assignee" "bob" assignee
  | _ -> fail "expected InProgress wire status"

let test_complete_is_terminal () =
  let t = TS.todo () in
  let claimed = TS.claim t ~agent:"charlie" in
  let done_ = TS.complete claimed ~notes:(Some "finished") in
  check string "done name" "done" (TS.status_name done_);
  let any = TS.of_wire (TS.to_wire done_) in
  check bool "terminal" true (TS.is_terminal any)

let test_cancel_is_terminal () =
  let t = TS.todo () in
  let cancelled = TS.cancel t ~by:"dave" ~reason:(Some "no longer needed") in
  check string "cancelled name" "cancelled" (TS.status_name cancelled);
  let any = TS.of_wire (TS.to_wire cancelled) in
  check bool "terminal" true (TS.is_terminal any)

let test_active_is_not_terminal () =
  let t = TS.todo () in
  let any = TS.of_wire (TS.to_wire t) in
  check bool "not terminal" false (TS.is_terminal any)

let test_wire_roundtrip_todo () =
  let t = TS.todo () in
  let wire = TS.to_wire t in
  match TS.of_wire wire with
  | TS.Active a -> check string "roundtrip name" "todo" (TS.status_name a)
  | TS.Terminal _ -> fail "todo should be active"

let test_wire_roundtrip_done () =
  let t = TS.todo () in
  let claimed = TS.claim t ~agent:"eve" in
  let done_ = TS.complete claimed ~notes:None in
  let wire = TS.to_wire done_ in
  match TS.of_wire wire with
  | TS.Terminal d -> check string "roundtrip name" "done" (TS.status_name d)
  | TS.Active _ -> fail "done should be terminal"

let test_wire_json_roundtrip () =
  let t = TS.todo () in
  let claimed = TS.claim t ~agent:"frank" in
  let wire = TS.to_wire claimed in
  let json = Types_core.task_status_to_yojson wire in
  match Types_core.task_status_of_yojson json with
  | Ok wire2 ->
    (match TS.of_wire wire2 with
     | TS.Active a -> check string "json roundtrip" "claimed" (TS.status_name a)
     | TS.Terminal _ -> fail "claimed should be active")
  | Error e -> fail ("json parse error: " ^ e)

(* ── GADT action state ────────────────────────────────── *)

let test_make_preview () =
  let p = TS.make_preview
    ~action_type:"pause_keeper"
    ~target_type:"keeper"
    ~target_id:"alice"
    ~payload:(`Assoc [("reason", `String "maintenance")])
  in
  check string "action_type" "pause_keeper" (TS.action_type_of p)

let test_confirm_action () =
  let p = TS.make_preview
    ~action_type:"scale_up"
    ~target_type:"room"
    ~target_id:"ops"
    ~payload:`Null
  in
  let c = TS.confirm p ~token:"tok-123" in
  check string "confirmed action_type" "scale_up" (TS.action_type_of c);
  check string "token" "tok-123" (TS.token_of c)

(* ── Rich validation errors ───────────────────────────── *)

let test_validation_error_to_string () =
  let e = TS.field_error
    ~path:["params"; "task_id"]
    ~expected:"non-empty string"
    ~actual:"empty string"
    ~protocol_version:"2025-06-18"
    ~hint:"task_id is required for task operations"
    ()
  in
  let s = TS.validation_error_to_string e in
  check bool "contains path" true (String.length s > 0);
  check bool "has field path" true (Astring.String.is_infix ~affix:"params.task_id" s);
  check bool "has expected" true (Astring.String.is_infix ~affix:"non-empty string" s);
  check bool "has actual" true (Astring.String.is_infix ~affix:"empty string" s);
  check bool "has protocol" true (Astring.String.is_infix ~affix:"2025-06-18" s);
  check bool "has hint" true (Astring.String.is_infix ~affix:"task_id is required" s)

let test_validation_error_to_json () =
  let e = TS.field_error
    ~path:["initialize"; "clientInfo"; "name"]
    ~expected:"string"
    ~actual:"null"
    ()
  in
  let json = TS.validation_error_to_json e in
  let open Yojson.Safe.Util in
  let path = json |> member "field_path" |> to_list |> List.map to_string in
  check (list string) "path" ["initialize"; "clientInfo"; "name"] path;
  check string "expected" "string" (json |> member "expected" |> to_string);
  check string "actual" "null" (json |> member "actual" |> to_string);
  check bool "no protocol" true
    (json |> member "protocol_version" = `Null)

let test_validation_error_minimal () =
  let e = TS.field_error
    ~path:["status"]
    ~expected:"todo|claimed|in_progress|done|cancelled"
    ~actual:"unknown_state"
    ()
  in
  let s = TS.validation_error_to_string e in
  check bool "no protocol suffix" false (Astring.String.is_infix ~affix:"(protocol" s);
  check bool "no hint suffix" false (Astring.String.is_infix ~affix:"[hint:" s)

(* ── Test suite ───────────────────────────────────────── *)

let () =
  run "typed_state (PoC-3)" [
    "phantom_task_status", [
      test_case "todo is active" `Quick test_todo_is_active;
      test_case "claim transition" `Quick test_claim_transition;
      test_case "start transition" `Quick test_start_transition;
      test_case "complete is terminal" `Quick test_complete_is_terminal;
      test_case "cancel is terminal" `Quick test_cancel_is_terminal;
      test_case "active is not terminal" `Quick test_active_is_not_terminal;
      test_case "wire roundtrip todo" `Quick test_wire_roundtrip_todo;
      test_case "wire roundtrip done" `Quick test_wire_roundtrip_done;
      test_case "wire+json roundtrip" `Quick test_wire_json_roundtrip;
    ];
    "gadt_action_state", [
      test_case "make preview" `Quick test_make_preview;
      test_case "confirm action" `Quick test_confirm_action;
    ];
    "rich_validation_error", [
      test_case "to_string full" `Quick test_validation_error_to_string;
      test_case "to_json" `Quick test_validation_error_to_json;
      test_case "to_string minimal" `Quick test_validation_error_minimal;
    ];
  ]
