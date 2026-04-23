let show_category = function
  | Masc_exec.Exit_code.Success -> "Success"
  | General_error -> "General_error"
  | Usage_error -> "Usage_error"
  | Data_error -> "Data_error"
  | Permission_error -> "Permission_error"
  | Not_found -> "Not_found"
  | Timeout -> "Timeout"
  | Oom_killed -> "Oom_killed"
  | Segfault -> "Segfault"
  | Signal n -> Printf.sprintf "Signal(%d)" n
  | Unknown n -> Printf.sprintf "Unknown(%d)" n

open Masc_exec.Exit_code

let assert_cat t expected =
  if t.category <> expected then
    Alcotest.fail (Printf.sprintf "expected %s, got %s"
      (show_category expected) (show_category t.category))

let ck_int ctx expected actual = Alcotest.(check int) ctx expected actual
let ck_str ctx expected actual = Alcotest.(check string) ctx expected actual

let () =
  (* success *)
  let t = of_process_status (Unix.WEXITED 0) in
  ck_int "code" 0 t.code;
  assert_cat t Success;
  ck_str "label" "success" t.label;
  if not (is_success t) then Alcotest.fail "should be success";

  (* general error *)
  let t = of_process_status (Unix.WEXITED 1) in
  ck_int "code" 1 t.code;
  assert_cat t General_error;
  if is_success t then Alcotest.fail "should not be success";
  ck_str "label" "general_error" t.label;
  if String.length t.hint = 0 then Alcotest.fail "hint should not be empty";

  (* usage error *)
  let t = of_process_status (Unix.WEXITED 2) in
  assert_cat t Usage_error;
  ck_str "label" "usage_error" t.label;

  (* command not found *)
  let t = of_process_status (Unix.WEXITED 127) in
  assert_cat t Not_found;
  ck_str "label" "command_not_found" t.label;

  (* not executable *)
  let t = of_process_status (Unix.WEXITED 126) in
  assert_cat t Permission_error;
  ck_str "label" "not_executable" t.label;

  (* timeout *)
  let t = of_process_status (Unix.WEXITED 124) in
  assert_cat t Timeout;
  ck_str "label" "timeout" t.label;

  (* OOM killed via 128+9 *)
  let t = of_process_status (Unix.WEXITED 137) in
  assert_cat t Oom_killed;
  ck_str "label" "oom_killed" t.label;
  if is_success t then Alcotest.fail "should not be success";

  (* segfault via 128+11 *)
  let t = of_process_status (Unix.WEXITED 139) in
  assert_cat t Segfault;
  ck_str "label" "segfault" t.label;

  (* generic signal via 128+15 *)
  let t = of_process_status (Unix.WEXITED 143) in
  assert_cat t (Signal 15);
  ck_str "label" "killed_by_SIGTERM" t.label;

  (* WSIGNALED *)
  let t = of_process_status (Unix.WSIGNALED 9) in
  assert_cat t Oom_killed;
  ck_int "code" 137 t.code;

  (* WSTOPPED *)
  let t = of_process_status (Unix.WSTOPPED 19) in
  assert_cat t (Signal 19);
  ck_str "label" "stopped_by_signal 19" t.label;

  (* unknown exit code *)
  let t = of_process_status (Unix.WEXITED 42) in
  assert_cat t (Unknown 42);
  ck_str "label" "exit_42" t.label;

  (* JSON output — command not found *)
  let t = of_process_status (Unix.WEXITED 127) in
  let json = to_json t in
  (match json with
   | `Assoc l ->
     (match List.assoc_opt "exit_code" l with
      | Some (`Int n) -> ck_int "json exit_code" 127 n
      | _ -> Alcotest.fail "exit_code not int");
     (match List.assoc_opt "label" l with
      | Some (`String s) -> ck_str "json label" "command_not_found" s
      | _ -> Alcotest.fail "label not string");
     (match List.assoc_opt "hint" l with
      | Some (`String _) -> ()
      | _ -> Alcotest.fail "hint missing")
   | _ -> Alcotest.fail "not assoc");

  (* success has no hint in JSON *)
  let t = of_process_status (Unix.WEXITED 0) in
  let json = to_json t in
  (match json with
   | `Assoc l ->
     (match List.assoc_opt "hint" l with
      | None -> ()
      | _ -> Alcotest.fail "success should have no hint")
   | _ -> Alcotest.fail "not assoc")
