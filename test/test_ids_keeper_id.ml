(** Tests for Keeper_id structural type — RFC-0232 P3 *)

(* ===== Keeper_id ===== *)

let test_keeper_id_make () =
  let id = Keeper_id.make ~uid:"u-abc123" ~name:"issue_king" ~path:"/keepers/issue_king" in
  Alcotest.(check string) "uid" "u-abc123" (Keeper_id.uid id);
  Alcotest.(check string) "name" "issue_king" (Keeper_id.name id);
  Alcotest.(check string) "path" "/keepers/issue_king" (Keeper_id.path id)

let test_keeper_id_equal_by_uid () =
  let a = Keeper_id.make ~uid:"u-abc" ~name:"king" ~path:"/k1" in
  let b = Keeper_id.make ~uid:"u-abc" ~name:"queen" ~path:"/k2" in
  let c = Keeper_id.make ~uid:"u-xyz" ~name:"king" ~path:"/k1" in
  Alcotest.(check bool) "same uid -> true" true (Keeper_id.equal a b);
  Alcotest.(check bool) "diff uid -> false" false (Keeper_id.equal a c)

let test_keeper_id_generate_deterministic () =
  let a = Keeper_id.generate ~name:"fix-bot" ~path:"/keepers/fix-bot" in
  let b = Keeper_id.generate ~name:"fix-bot" ~path:"/keepers/fix-bot" in
  Alcotest.(check bool) "same name+path same uid" true (Keeper_id.equal a b);
  Alcotest.(check string) "uid matches" (Keeper_id.uid a) (Keeper_id.uid b);
  Alcotest.(check string) "name matches" (Keeper_id.name a) (Keeper_id.name b);
  Alcotest.(check string) "path matches" (Keeper_id.path a) (Keeper_id.path b)

let test_keeper_id_to_string_returns_uid () =
  let id = Keeper_id.make ~uid:"u-abc" ~name:"test" ~path:"/t" in
  Alcotest.(check string) "to_string = uid" "u-abc" (Keeper_id.to_string id)

let test_keeper_id_of_string_roundtrip () =
  let id = Keeper_id.make ~uid:"u-roundtrip" ~name:"rt" ~path:"/rt" in
  let s = Keeper_id.to_string id in
  let id' = Keeper_id.of_string s in
  Alcotest.(check bool) "roundtrip equal" true (Keeper_id.equal id id');
  Alcotest.(check string) "roundtrip uid" "u-roundtrip" (Keeper_id.uid id')

let test_keeper_id_yojson_roundtrip () =
  let id = Keeper_id.make ~uid:"u-yojson" ~name:"yj" ~path:"/yj" in
  let json = Keeper_id.to_yojson id in
  match Keeper_id.of_yojson json with
  | Ok id' -> Alcotest.(check bool) "yojson roundtrip" true (Keeper_id.equal id id')
  | Error e -> Alcotest.fail ("yojson roundtrip failed: " ^ e)

let test_keeper_id_uid_of_yojson () =
  let json = `String "u-uidonly" in
  match Keeper_id.uid_of_yojson json with
  | Ok id -> Alcotest.(check string) "uid_of_yojson uid" "u-uidonly" (Keeper_id.uid id)
  | Error e -> Alcotest.fail ("uid_of_yojson failed: " ^ e)

(* ===== Keeper_id.Trace_id ===== *)

let test_keeper_trace_id_parse_good () =
  match Keeper_id.Trace_id.of_string "trace-1234567890-99999" with
  | Ok _ -> ()
  | Error e -> Alcotest.fail ("trace_id parse failed: " ^ e)

let test_keeper_trace_id_parse_bad () =
  match Keeper_id.Trace_id.of_string "not-a-trace" with
  | Ok _ -> Alcotest.fail "expected error for bad trace_id"
  | Error _ -> ()

let test_keeper_trace_id_roundtrip () =
  let s = "trace-1234567890-99999" in
  match Keeper_id.Trace_id.of_string s with
  | Ok id -> Alcotest.(check string) "trace_id roundtrip" s (Keeper_id.Trace_id.to_string id)
  | Error e -> Alcotest.fail ("trace_id roundtrip failed: " ^ e)

let test_keeper_trace_id_equal () =
  match Keeper_id.Trace_id.of_string "trace-1-1", Keeper_id.Trace_id.of_string "trace-1-1" with
  | Ok a, Ok b -> Alcotest.(check bool) "same trace_id equal" true (Keeper_id.Trace_id.equal a b)
  | _ -> Alcotest.fail "trace_id equal setup failed"

(* ===== Keeper_id.Task_id ===== *)

let test_keeper_task_id_parse_good () =
  match Keeper_id.Task_id.of_string "task-12345-0001" with
  | Ok _ -> ()
  | Error e -> Alcotest.fail ("task_id parse failed: " ^ e)

let test_keeper_task_id_parse_bad () =
  match Keeper_id.Task_id.of_string "invalid" with
  | Ok _ -> Alcotest.fail "expected error for bad task_id"
  | Error _ -> ()

let test_keeper_task_id_roundtrip () =
  let s = "task-98765-abcd" in
  match Keeper_id.Task_id.of_string s with
  | Ok id -> Alcotest.(check string) "task_id roundtrip" s (Keeper_id.Task_id.to_string id)
  | Error e -> Alcotest.fail ("task_id roundtrip failed: " ^ e)

(* ===== Suite ===== *)

let suite = [
  "keeper_id_make", `Quick, test_keeper_id_make;
  "keeper_id_equal_by_uid", `Quick, test_keeper_id_equal_by_uid;
  "keeper_id_generate_deterministic", `Quick, test_keeper_id_generate_deterministic;
  "keeper_id_to_string_returns_uid", `Quick, test_keeper_id_to_string_returns_uid;
  "keeper_id_of_string_roundtrip", `Quick, test_keeper_id_of_string_roundtrip;
  "keeper_id_yojson_roundtrip", `Quick, test_keeper_id_yojson_roundtrip;
  "keeper_id_uid_of_yojson", `Quick, test_keeper_id_uid_of_yojson;
  "keeper_trace_id_parse_good", `Quick, test_keeper_trace_id_parse_good;
  "keeper_trace_id_parse_bad", `Quick, test_keeper_trace_id_parse_bad;
  "keeper_trace_id_roundtrip", `Quick, test_keeper_trace_id_roundtrip;
  "keeper_trace_id_equal", `Quick, test_keeper_trace_id_equal;
  "keeper_task_id_parse_good", `Quick, test_keeper_task_id_parse_good;
  "keeper_task_id_parse_bad", `Quick, test_keeper_task_id_parse_bad;
  "keeper_task_id_roundtrip", `Quick, test_keeper_task_id_roundtrip;
]