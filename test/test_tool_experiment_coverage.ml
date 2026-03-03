(** Tool_experiment coverage tests — P3 Phase 6
    Covers: types, serialization, statistics, handlers (via dispatch), schemas *)

open Masc_mcp

(** {1 Test Helpers} *)

let temp_dir () =
  let dir = Filename.temp_file "test_tool_experiment_" "" in
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

let make_ctx () =
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "experimenter"));
  let ctx : Tool_experiment.context = { config; agent_name = "experimenter" } in
  (ctx, base_dir)

let parse_json s =
  try Yojson.Safe.from_string s
  with Yojson.Json_error e -> failwith ("invalid json: " ^ e)

let dispatch ctx ~name ~args =
  match Tool_experiment.dispatch ctx ~name ~args with
  | Some r -> r
  | None -> failwith ("dispatch returned None for " ^ name)

let mem = Yojson.Safe.Util.member
let to_string_exn = Yojson.Safe.Util.to_string
let to_float_exn = Yojson.Safe.Util.to_float
let to_int_exn = Yojson.Safe.Util.to_int

(** {1 Group 1: Type Converters} *)

let test_group_to_string () =
  Alcotest.(check string) "treatment" "treatment"
    (Tool_experiment.group_to_string Tool_experiment.Treatment);
  Alcotest.(check string) "control" "control"
    (Tool_experiment.group_to_string Tool_experiment.Control)

let test_group_of_string () =
  Alcotest.(check bool) "treatment" true
    (Tool_experiment.group_of_string "treatment" = Tool_experiment.Treatment);
  Alcotest.(check bool) "control" true
    (Tool_experiment.group_of_string "control" = Tool_experiment.Control)

let test_group_of_string_invalid () =
  try
    ignore (Tool_experiment.group_of_string "unknown");
    Alcotest.fail "expected invalid_arg"
  with Invalid_argument msg ->
    Alcotest.(check bool) "mentions unknown" true
      (String.length msg > 0)

let test_status_to_string () =
  Alcotest.(check string) "running" "running"
    (Tool_experiment.status_to_string Tool_experiment.Running);
  Alcotest.(check string) "concluded" "concluded"
    (Tool_experiment.status_to_string Tool_experiment.Concluded)

let test_status_of_string () =
  Alcotest.(check bool) "running" true
    (Tool_experiment.status_of_string "running" = Tool_experiment.Running);
  Alcotest.(check bool) "concluded" true
    (Tool_experiment.status_of_string "concluded" = Tool_experiment.Concluded)

let test_status_of_string_invalid () =
  try
    ignore (Tool_experiment.status_of_string "paused");
    Alcotest.fail "expected invalid_arg"
  with Invalid_argument msg ->
    Alcotest.(check bool) "mentions unknown" true
      (String.length msg > 0)

(** {1 Group 2: Statistics — Pure Functions} *)

let epsilon = Alcotest.testable
  (fun fmt f -> Format.fprintf fmt "%.10f" f)
  (fun a b -> Float.abs (a -. b) < 1e-6)

let test_mean_empty () =
  Alcotest.(check (float 1e-10)) "empty" 0.0 (Tool_experiment.mean [])

let test_mean_single () =
  Alcotest.(check (float 1e-10)) "single" 5.0 (Tool_experiment.mean [5.0])

let test_mean_multiple () =
  Alcotest.check epsilon "multi" 3.0 (Tool_experiment.mean [1.0; 2.0; 3.0; 4.0; 5.0])

let test_variance_empty () =
  Alcotest.(check (float 1e-10)) "empty" 0.0 (Tool_experiment.variance [])

let test_variance_single () =
  Alcotest.(check (float 1e-10)) "single" 0.0 (Tool_experiment.variance [42.0])

let test_variance_multiple () =
  (* [1;2;3;4;5] sample variance = 2.5 *)
  Alcotest.check epsilon "multi" 2.5
    (Tool_experiment.variance [1.0; 2.0; 3.0; 4.0; 5.0])

let test_welch_t_insufficient_samples () =
  let t_stat, p = Tool_experiment.welch_t_test [1.0] [2.0] in
  Alcotest.(check (float 1e-10)) "t_stat" 0.0 t_stat;
  Alcotest.(check (float 1e-10)) "p" 1.0 p

let test_welch_t_identical_groups () =
  let t_stat, p = Tool_experiment.welch_t_test [1.0; 1.0; 1.0] [1.0; 1.0; 1.0] in
  Alcotest.(check (float 1e-10)) "t_stat zero" 0.0 t_stat;
  Alcotest.(check (float 1e-10)) "p is 1" 1.0 p

let test_welch_t_different_groups () =
  (* Large difference should yield p < 0.05 *)
  let treatment = [10.0; 11.0; 12.0; 13.0; 14.0] in
  let control = [1.0; 2.0; 3.0; 4.0; 5.0] in
  let t_stat, p = Tool_experiment.welch_t_test treatment control in
  Alcotest.(check bool) "t positive" true (t_stat > 0.0);
  Alcotest.(check bool) "p significant" true (p <= 0.05)

let test_cohens_d_identical () =
  let d = Tool_experiment.cohens_d [5.0; 5.0; 5.0] [5.0; 5.0; 5.0] in
  Alcotest.(check (float 1e-10)) "d zero" 0.0 d

let test_cohens_d_large_effect () =
  let treatment = [10.0; 11.0; 12.0; 13.0; 14.0] in
  let control = [1.0; 2.0; 3.0; 4.0; 5.0] in
  let d = Tool_experiment.cohens_d treatment control in
  (* 9 / ~1.58 ≈ 5.7, large effect *)
  Alcotest.(check bool) "d large" true (d > 2.0)

(** {1 Group 3: Serialization Round-Trip} *)

let test_assignment_roundtrip () =
  let a : Tool_experiment.assignment =
    { subject_id = "user-1"; group = Tool_experiment.Treatment; timestamp = 1000.0 }
  in
  let json = Tool_experiment.assignment_to_yojson a in
  let a2 = Tool_experiment.assignment_of_yojson json in
  Alcotest.(check string) "subject_id" "user-1" a2.subject_id;
  Alcotest.(check (float 1e-10)) "timestamp" 1000.0 a2.timestamp;
  Alcotest.(check bool) "group" true
    (a2.group = Tool_experiment.Treatment)

let test_observation_roundtrip () =
  let o : Tool_experiment.observation =
    { subject_id = "user-2"; metric_name = "latency"; value = 42.5; timestamp = 2000.0 }
  in
  let json = Tool_experiment.observation_to_yojson o in
  let o2 = Tool_experiment.observation_of_yojson json in
  Alcotest.(check string) "subject" "user-2" o2.subject_id;
  Alcotest.(check string) "metric" "latency" o2.metric_name;
  Alcotest.(check (float 1e-10)) "value" 42.5 o2.value;
  Alcotest.(check (float 1e-10)) "ts" 2000.0 o2.timestamp

let test_experiment_roundtrip () =
  let exp : Tool_experiment.experiment =
    { id = "exp-test-001"; hypothesis = "H0"; treatment_desc = "new UI";
      control_desc = "old UI"; metrics = ["ctr"; "bounce"];
      window_seconds = 3600.0; status = Tool_experiment.Running;
      assignments = []; observations = []; created_at = 1234.0 }
  in
  let json = Tool_experiment.experiment_to_yojson exp in
  let exp2 = Tool_experiment.experiment_of_yojson json in
  Alcotest.(check string) "id" "exp-test-001" exp2.id;
  Alcotest.(check string) "hypothesis" "H0" exp2.hypothesis;
  Alcotest.(check string) "treatment" "new UI" exp2.treatment_desc;
  Alcotest.(check string) "control" "old UI" exp2.control_desc;
  Alcotest.(check int) "metrics count" 2 (List.length exp2.metrics);
  Alcotest.(check (float 1e-10)) "window" 3600.0 exp2.window_seconds;
  Alcotest.(check bool) "running" true
    (exp2.status = Tool_experiment.Running);
  Alcotest.(check (float 1e-10)) "created_at" 1234.0 exp2.created_at

(** {1 Group 4: Dispatch Routing} *)

let test_dispatch_unknown_tool () =
  let ctx, base_dir = make_ctx () in
  let result = Tool_experiment.dispatch ctx ~name:"nonexistent" ~args:(`Assoc []) in
  Alcotest.(check bool) "returns None" true (result = None);
  cleanup_dir base_dir

let test_dispatch_routes_all_seven () =
  let ctx, base_dir = make_ctx () in
  let names = [
    "experiment_start"; "experiment_assign"; "experiment_observe";
    "experiment_checkpoint"; "experiment_conclude"; "experiment_list";
    "experiment_status"
  ] in
  List.iter (fun name ->
    let result = Tool_experiment.dispatch ctx ~name ~args:(`Assoc []) in
    Alcotest.(check bool) (name ^ " routed") true (result <> None)
  ) names;
  cleanup_dir base_dir

(** {1 Group 5: Handler — experiment_start} *)

let test_start_minimal () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [
    ("hypothesis", `String "New feature increases engagement");
    ("treatment_description", `String "Feature enabled");
    ("control_description", `String "Feature disabled");
  ] in
  let ok, body = dispatch ctx ~name:"experiment_start" ~args in
  Alcotest.(check bool) "ok" true ok;
  let json = parse_json body in
  (* Response is flat: {"id","hypothesis","status"} *)
  let exp_id = json |> mem "id" |> to_string_exn in
  Alcotest.(check bool) "id starts with exp-" true
    (String.length exp_id > 4 && String.sub exp_id 0 4 = "exp-");
  Alcotest.(check string) "status" "running"
    (json |> mem "status" |> to_string_exn);
  cleanup_dir base_dir

let test_start_with_metrics_and_window () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [
    ("hypothesis", `String "H1");
    ("treatment_description", `String "A");
    ("control_description", `String "B");
    ("metrics", `List [`String "ctr"; `String "revenue"]);
    ("window_seconds", `Float 7200.0);
  ] in
  let ok, body = dispatch ctx ~name:"experiment_start" ~args in
  Alcotest.(check bool) "ok" true ok;
  (* Response only contains id, hypothesis, status — metrics not echoed *)
  let json = parse_json body in
  Alcotest.(check string) "has id" "H1"
    (json |> mem "hypothesis" |> to_string_exn);
  cleanup_dir base_dir

let test_start_missing_hypothesis () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [
    ("treatment_description", `String "A");
    ("control_description", `String "B");
  ] in
  let ok, body = dispatch ctx ~name:"experiment_start" ~args in
  Alcotest.(check bool) "not ok" false ok;
  Alcotest.(check bool) "mentions hypothesis" true
    (String.lowercase_ascii body |> fun s ->
     try ignore (Str.search_forward (Str.regexp_string "hypothesis") s 0); true
     with Not_found -> false);
  cleanup_dir base_dir

let test_start_missing_treatment () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [
    ("hypothesis", `String "H");
    ("control_description", `String "B");
  ] in
  let ok, body = dispatch ctx ~name:"experiment_start" ~args in
  Alcotest.(check bool) "not ok" false ok;
  Alcotest.(check bool) "mentions treatment" true
    (String.lowercase_ascii body |> fun s ->
     try ignore (Str.search_forward (Str.regexp_string "treatment") s 0); true
     with Not_found -> false);
  cleanup_dir base_dir

let test_start_missing_control () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [
    ("hypothesis", `String "H");
    ("treatment_description", `String "A");
  ] in
  let ok, body = dispatch ctx ~name:"experiment_start" ~args in
  Alcotest.(check bool) "not ok" false ok;
  Alcotest.(check bool) "mentions control" true
    (String.lowercase_ascii body |> fun s ->
     try ignore (Str.search_forward (Str.regexp_string "control") s 0); true
     with Not_found -> false);
  cleanup_dir base_dir

(** {1 Group 6: Handler — experiment_assign} *)

let start_experiment ctx =
  let args = `Assoc [
    ("hypothesis", `String "Test hypo");
    ("treatment_description", `String "T");
    ("control_description", `String "C");
  ] in
  let ok, body = dispatch ctx ~name:"experiment_start" ~args in
  assert ok;
  let json = parse_json body in
  (* Response is flat: {"id","hypothesis","status"} *)
  json |> mem "id" |> to_string_exn

let test_assign_treatment () =
  let ctx, base_dir = make_ctx () in
  let exp_id = start_experiment ctx in
  let args = `Assoc [
    ("experiment_id", `String exp_id);
    ("subject_id", `String "user-001");
    ("group", `String "treatment");
  ] in
  let ok, body = dispatch ctx ~name:"experiment_assign" ~args in
  Alcotest.(check bool) "ok" true ok;
  (* Response is plain text: "Assigned user-001 to treatment group" *)
  Alcotest.(check bool) "mentions treatment" true
    (try ignore (Str.search_forward (Str.regexp_string "treatment") body 0); true
     with Not_found -> false);
  cleanup_dir base_dir

let test_assign_control () =
  let ctx, base_dir = make_ctx () in
  let exp_id = start_experiment ctx in
  let args = `Assoc [
    ("experiment_id", `String exp_id);
    ("subject_id", `String "user-002");
    ("group", `String "control");
  ] in
  let ok, body = dispatch ctx ~name:"experiment_assign" ~args in
  Alcotest.(check bool) "ok" true ok;
  (* Response is plain text: "Assigned user-002 to control group" *)
  Alcotest.(check bool) "mentions control" true
    (try ignore (Str.search_forward (Str.regexp_string "control") body 0); true
     with Not_found -> false);
  cleanup_dir base_dir

let test_assign_missing_experiment_id () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [
    ("subject_id", `String "user-001");
    ("group", `String "treatment");
  ] in
  let ok, _body = dispatch ctx ~name:"experiment_assign" ~args in
  Alcotest.(check bool) "not ok" false ok;
  cleanup_dir base_dir

let test_assign_nonexistent_experiment () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [
    ("experiment_id", `String "exp-nonexistent");
    ("subject_id", `String "user-001");
    ("group", `String "treatment");
  ] in
  let ok, body = dispatch ctx ~name:"experiment_assign" ~args in
  Alcotest.(check bool) "not ok" false ok;
  Alcotest.(check bool) "mentions not found" true
    (String.lowercase_ascii body |> fun s ->
     try ignore (Str.search_forward (Str.regexp_string "not found") s 0); true
     with Not_found -> false);
  cleanup_dir base_dir

(** {1 Group 7: Handler — experiment_observe} *)

let test_observe_valid () =
  let ctx, base_dir = make_ctx () in
  let exp_id = start_experiment ctx in
  let args = `Assoc [
    ("experiment_id", `String exp_id);
    ("subject_id", `String "user-001");
    ("metric_name", `String "ctr");
    ("value", `Float 0.15);
  ] in
  let ok, body = dispatch ctx ~name:"experiment_observe" ~args in
  Alcotest.(check bool) "ok" true ok;
  (* Response is plain text: "Recorded ctr=0.15 for user-001" *)
  Alcotest.(check bool) "mentions Recorded" true
    (try ignore (Str.search_forward (Str.regexp_string "Recorded") body 0); true
     with Not_found -> false);
  Alcotest.(check bool) "mentions metric" true
    (try ignore (Str.search_forward (Str.regexp_string "ctr") body 0); true
     with Not_found -> false);
  cleanup_dir base_dir

let test_observe_missing_metric () =
  let ctx, base_dir = make_ctx () in
  let exp_id = start_experiment ctx in
  let args = `Assoc [
    ("experiment_id", `String exp_id);
    ("subject_id", `String "user-001");
    ("value", `Float 1.0);
  ] in
  let ok, _body = dispatch ctx ~name:"experiment_observe" ~args in
  Alcotest.(check bool) "not ok" false ok;
  cleanup_dir base_dir

let test_observe_nonexistent_experiment () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [
    ("experiment_id", `String "exp-fake");
    ("subject_id", `String "u1");
    ("metric_name", `String "ctr");
    ("value", `Float 1.0);
  ] in
  let ok, _body = dispatch ctx ~name:"experiment_observe" ~args in
  Alcotest.(check bool) "not ok" false ok;
  cleanup_dir base_dir

(** {1 Group 8: Handler — experiment_checkpoint} *)

let test_checkpoint_with_data () =
  let ctx, base_dir = make_ctx () in
  let exp_id = start_experiment ctx in
  (* Add assignments and observations *)
  List.iter (fun (subj, grp) ->
    let args = `Assoc [
      ("experiment_id", `String exp_id);
      ("subject_id", `String subj);
      ("group", `String grp);
    ] in
    let ok, _ = dispatch ctx ~name:"experiment_assign" ~args in
    assert ok
  ) [("u1","treatment"); ("u2","treatment"); ("u3","control"); ("u4","control")];
  List.iter (fun (subj, value) ->
    let args = `Assoc [
      ("experiment_id", `String exp_id);
      ("subject_id", `String subj);
      ("metric_name", `String "score");
      ("value", `Float value);
    ] in
    let ok, _ = dispatch ctx ~name:"experiment_observe" ~args in
    assert ok
  ) [("u1", 10.0); ("u2", 12.0); ("u3", 3.0); ("u4", 5.0)];
  let args = `Assoc [
    ("experiment_id", `String exp_id);
    ("metric_name", `String "score");
  ] in
  let ok, body = dispatch ctx ~name:"experiment_checkpoint" ~args in
  Alcotest.(check bool) "ok" true ok;
  let json = parse_json body in
  (* Response is flat: {"experiment_id","treatment_mean","control_mean","p_value","effect_size","elapsed_pct"} *)
  Alcotest.(check bool) "has treatment_mean" true
    (json |> mem "treatment_mean" |> to_float_exn > 0.0);
  Alcotest.(check bool) "has control_mean" true
    (json |> mem "control_mean" |> to_float_exn > 0.0);
  Alcotest.(check bool) "has p_value" true
    (json |> mem "p_value" |> to_float_exn >= 0.0);
  cleanup_dir base_dir

let test_checkpoint_no_data () =
  let ctx, base_dir = make_ctx () in
  let exp_id = start_experiment ctx in
  let args = `Assoc [
    ("experiment_id", `String exp_id);
    ("metric_name", `String "score");
  ] in
  let ok, body = dispatch ctx ~name:"experiment_checkpoint" ~args in
  Alcotest.(check bool) "ok" true ok;
  (* With no observations, means should be 0 — response is flat *)
  let json = parse_json body in
  Alcotest.(check (float 1e-10)) "treatment_mean 0" 0.0
    (json |> mem "treatment_mean" |> to_float_exn);
  cleanup_dir base_dir

let test_checkpoint_nonexistent () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [
    ("experiment_id", `String "exp-nope");
    ("metric_name", `String "score");
  ] in
  let ok, _body = dispatch ctx ~name:"experiment_checkpoint" ~args in
  Alcotest.(check bool) "not ok" false ok;
  cleanup_dir base_dir

(** {1 Group 9: Handler — experiment_conclude} *)

let test_conclude_running_experiment () =
  let ctx, base_dir = make_ctx () in
  let exp_id = start_experiment ctx in
  (* Add some data *)
  List.iter (fun (subj, grp) ->
    let args = `Assoc [
      ("experiment_id", `String exp_id);
      ("subject_id", `String subj);
      ("group", `String grp);
    ] in
    let ok, _ = dispatch ctx ~name:"experiment_assign" ~args in assert ok
  ) [("a","treatment"); ("b","treatment"); ("c","control"); ("d","control")];
  List.iter (fun (subj, v) ->
    let args = `Assoc [
      ("experiment_id", `String exp_id);
      ("subject_id", `String subj);
      ("metric_name", `String "m1");
      ("value", `Float v);
    ] in
    let ok, _ = dispatch ctx ~name:"experiment_observe" ~args in assert ok
  ) [("a", 100.0); ("b", 110.0); ("c", 50.0); ("d", 55.0)];
  let args = `Assoc [("experiment_id", `String exp_id)] in
  let ok, body = dispatch ctx ~name:"experiment_conclude" ~args in
  Alcotest.(check bool) "ok" true ok;
  let json = parse_json body in
  (* Response is flat: {"experiment_id","result","effect_size","confidence_interval","sample_sizes"} *)
  Alcotest.(check bool) "has result" true
    (String.length (json |> mem "result" |> to_string_exn) > 0);
  Alcotest.(check bool) "has effect_size" true
    (match json |> mem "effect_size" with `Float _ -> true | _ -> false);
  cleanup_dir base_dir

let test_conclude_already_concluded () =
  let ctx, base_dir = make_ctx () in
  let exp_id = start_experiment ctx in
  let args = `Assoc [("experiment_id", `String exp_id)] in
  let ok, _body = dispatch ctx ~name:"experiment_conclude" ~args in
  Alcotest.(check bool) "first conclude ok" true ok;
  let ok2, body2 = dispatch ctx ~name:"experiment_conclude" ~args in
  Alcotest.(check bool) "second conclude fails" false ok2;
  Alcotest.(check bool) "mentions concluded" true
    (String.lowercase_ascii body2 |> fun s ->
     try ignore (Str.search_forward (Str.regexp_string "concluded") s 0); true
     with Not_found -> false);
  cleanup_dir base_dir

let test_conclude_nonexistent () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("experiment_id", `String "exp-ghost")] in
  let ok, _body = dispatch ctx ~name:"experiment_conclude" ~args in
  Alcotest.(check bool) "not ok" false ok;
  cleanup_dir base_dir

(** {1 Group 10: Handler — experiment_list} *)

let test_list_empty () =
  let ctx, base_dir = make_ctx () in
  let ok, body = dispatch ctx ~name:"experiment_list" ~args:(`Assoc []) in
  Alcotest.(check bool) "ok" true ok;
  let json = parse_json body in
  Alcotest.(check int) "total 0" 0
    (json |> mem "total" |> to_int_exn);
  cleanup_dir base_dir

let test_list_after_creation () =
  let ctx, base_dir = make_ctx () in
  ignore (start_experiment ctx);
  ignore (start_experiment ctx);
  let ok, body = dispatch ctx ~name:"experiment_list" ~args:(`Assoc []) in
  Alcotest.(check bool) "ok" true ok;
  let json = parse_json body in
  Alcotest.(check int) "total 2" 2 (json |> mem "total" |> to_int_exn);
  cleanup_dir base_dir

let test_list_with_status_filter () =
  let ctx, base_dir = make_ctx () in
  let exp_id = start_experiment ctx in
  ignore (start_experiment ctx);
  (* Conclude one *)
  let args = `Assoc [("experiment_id", `String exp_id)] in
  let ok, _ = dispatch ctx ~name:"experiment_conclude" ~args in
  assert ok;
  (* List only running *)
  let ok, body =
    dispatch ctx ~name:"experiment_list"
      ~args:(`Assoc [("status", `String "running")])
  in
  Alcotest.(check bool) "ok" true ok;
  let json = parse_json body in
  Alcotest.(check int) "only running" 1 (json |> mem "total" |> to_int_exn);
  cleanup_dir base_dir

let test_list_with_limit () =
  let ctx, base_dir = make_ctx () in
  ignore (start_experiment ctx);
  ignore (start_experiment ctx);
  ignore (start_experiment ctx);
  let ok, body =
    dispatch ctx ~name:"experiment_list"
      ~args:(`Assoc [("limit", `Int 2)])
  in
  Alcotest.(check bool) "ok" true ok;
  let json = parse_json body in
  (* "total" is the full filtered count (3), but "experiments" list is limited *)
  let exps = json |> mem "experiments" |> Yojson.Safe.Util.to_list in
  Alcotest.(check int) "limited to 2" 2 (List.length exps);
  cleanup_dir base_dir

(** {1 Group 11: Handler — experiment_status} *)

let test_status_running () =
  let ctx, base_dir = make_ctx () in
  let exp_id = start_experiment ctx in
  let args = `Assoc [("experiment_id", `String exp_id)] in
  let ok, body = dispatch ctx ~name:"experiment_status" ~args in
  Alcotest.(check bool) "ok" true ok;
  let json = parse_json body in
  Alcotest.(check string) "status running" "running"
    (json |> mem "status" |> to_string_exn);
  Alcotest.(check bool) "has elapsed" true
    (json |> mem "elapsed_seconds" |> to_float_exn >= 0.0);
  cleanup_dir base_dir

let test_status_with_assignments () =
  let ctx, base_dir = make_ctx () in
  let exp_id = start_experiment ctx in
  let assign_args = `Assoc [
    ("experiment_id", `String exp_id);
    ("subject_id", `String "u1");
    ("group", `String "treatment");
  ] in
  let ok, _ = dispatch ctx ~name:"experiment_assign" ~args:assign_args in
  assert ok;
  let args = `Assoc [("experiment_id", `String exp_id)] in
  let ok, body = dispatch ctx ~name:"experiment_status" ~args in
  Alcotest.(check bool) "ok" true ok;
  let json = parse_json body in
  (* Response has nested sample_sizes: {"treatment":N, "control":N} *)
  let sizes = json |> mem "sample_sizes" in
  Alcotest.(check int) "treatment count" 1
    (sizes |> mem "treatment" |> to_int_exn);
  Alcotest.(check int) "control count" 0
    (sizes |> mem "control" |> to_int_exn);
  cleanup_dir base_dir

let test_status_nonexistent () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("experiment_id", `String "exp-missing")] in
  let ok, _body = dispatch ctx ~name:"experiment_status" ~args in
  Alcotest.(check bool) "not ok" false ok;
  cleanup_dir base_dir

(** {1 Group 12: Handler — concluded experiment rejects mutations} *)

let test_assign_to_concluded () =
  let ctx, base_dir = make_ctx () in
  let exp_id = start_experiment ctx in
  let _ = dispatch ctx ~name:"experiment_conclude"
    ~args:(`Assoc [("experiment_id", `String exp_id)]) in
  let ok, body = dispatch ctx ~name:"experiment_assign"
    ~args:(`Assoc [
      ("experiment_id", `String exp_id);
      ("subject_id", `String "u1");
      ("group", `String "treatment");
    ]) in
  Alcotest.(check bool) "assign to concluded fails" false ok;
  Alcotest.(check bool) "mentions not running" true
    (String.lowercase_ascii body |> fun s ->
     try ignore (Str.search_forward (Str.regexp_string "not running") s 0); true
     with Not_found ->
       try ignore (Str.search_forward (Str.regexp_string "concluded") s 0); true
       with Not_found -> false);
  cleanup_dir base_dir

let test_observe_concluded () =
  let ctx, base_dir = make_ctx () in
  let exp_id = start_experiment ctx in
  let _ = dispatch ctx ~name:"experiment_conclude"
    ~args:(`Assoc [("experiment_id", `String exp_id)]) in
  let ok, _body = dispatch ctx ~name:"experiment_observe"
    ~args:(`Assoc [
      ("experiment_id", `String exp_id);
      ("subject_id", `String "u1");
      ("metric_name", `String "ctr");
      ("value", `Float 1.0);
    ]) in
  Alcotest.(check bool) "observe on concluded fails" false ok;
  cleanup_dir base_dir

(** {1 Group 13: Schemas} *)

let test_schemas_count () =
  Alcotest.(check int) "7 schemas" 7 (List.length Tool_experiment.schemas)

let test_schemas_unique_names () =
  let names = List.map (fun (s : Types.tool_schema) -> s.name) Tool_experiment.schemas in
  let unique = List.sort_uniq String.compare names in
  Alcotest.(check int) "all unique" (List.length names) (List.length unique)

let test_schemas_have_descriptions () =
  List.iter (fun (s : Types.tool_schema) ->
    Alcotest.(check bool) (s.name ^ " has desc") true
      (String.length s.description > 0)
  ) Tool_experiment.schemas

(** {1 Group 14: End-to-End Experiment Lifecycle} *)

let test_full_lifecycle () =
  let ctx, base_dir = make_ctx () in
  (* 1. Start *)
  let exp_id = start_experiment ctx in
  (* 2. Assign subjects *)
  List.iter (fun (subj, grp) ->
    let ok, _ = dispatch ctx ~name:"experiment_assign"
      ~args:(`Assoc [
        ("experiment_id", `String exp_id);
        ("subject_id", `String subj);
        ("group", `String grp);
      ]) in
    assert ok
  ) [("u1","treatment"); ("u2","treatment"); ("u3","treatment");
     ("u4","control"); ("u5","control"); ("u6","control")];
  (* 3. Record observations *)
  List.iter (fun (subj, v) ->
    let ok, _ = dispatch ctx ~name:"experiment_observe"
      ~args:(`Assoc [
        ("experiment_id", `String exp_id);
        ("subject_id", `String subj);
        ("metric_name", `String "conversion");
        ("value", `Float v);
      ]) in
    assert ok
  ) [("u1",0.8); ("u2",0.9); ("u3",0.7); ("u4",0.3); ("u5",0.2); ("u6",0.4)];
  (* 4. Checkpoint *)
  let ok, body = dispatch ctx ~name:"experiment_checkpoint"
    ~args:(`Assoc [
      ("experiment_id", `String exp_id);
      ("metric_name", `String "conversion");
    ]) in
  Alcotest.(check bool) "checkpoint ok" true ok;
  let cp_json = parse_json body in
  (* Checkpoint response is flat *)
  let t_mean = cp_json |> mem "treatment_mean" |> to_float_exn in
  let c_mean = cp_json |> mem "control_mean" |> to_float_exn in
  Alcotest.(check bool) "treatment > control" true (t_mean > c_mean);
  (* 5. Status check *)
  let ok, body = dispatch ctx ~name:"experiment_status"
    ~args:(`Assoc [("experiment_id", `String exp_id)]) in
  Alcotest.(check bool) "status ok" true ok;
  let status_json = parse_json body in
  let sizes = status_json |> mem "sample_sizes" in
  Alcotest.(check int) "treatment_count" 3
    (sizes |> mem "treatment" |> to_int_exn);
  Alcotest.(check int) "control_count" 3
    (sizes |> mem "control" |> to_int_exn);
  (* 6. Conclude *)
  let ok, body = dispatch ctx ~name:"experiment_conclude"
    ~args:(`Assoc [("experiment_id", `String exp_id)]) in
  Alcotest.(check bool) "conclude ok" true ok;
  let conclude_json = parse_json body in
  (* Conclude response is flat: {"experiment_id","result","effect_size",...} *)
  Alcotest.(check bool) "has result" true
    (String.length (conclude_json |> mem "result" |> to_string_exn) > 0);
  Alcotest.(check bool) "has effect_size" true
    (match conclude_json |> mem "effect_size" with `Float _ -> true | _ -> false);
  (* 7. List shows concluded *)
  let ok, body = dispatch ctx ~name:"experiment_list"
    ~args:(`Assoc [("status", `String "concluded")]) in
  Alcotest.(check bool) "list ok" true ok;
  let list_json = parse_json body in
  Alcotest.(check int) "1 concluded" 1 (list_json |> mem "total" |> to_int_exn);
  cleanup_dir base_dir

(** {1 Runner} *)

let () =
  Alcotest.run "Tool_experiment coverage" [
    ("type_converters", [
      Alcotest.test_case "group_to_string" `Quick test_group_to_string;
      Alcotest.test_case "group_of_string" `Quick test_group_of_string;
      Alcotest.test_case "group_of_string invalid" `Quick test_group_of_string_invalid;
      Alcotest.test_case "status_to_string" `Quick test_status_to_string;
      Alcotest.test_case "status_of_string" `Quick test_status_of_string;
      Alcotest.test_case "status_of_string invalid" `Quick test_status_of_string_invalid;
    ]);
    ("statistics", [
      Alcotest.test_case "mean empty" `Quick test_mean_empty;
      Alcotest.test_case "mean single" `Quick test_mean_single;
      Alcotest.test_case "mean multiple" `Quick test_mean_multiple;
      Alcotest.test_case "variance empty" `Quick test_variance_empty;
      Alcotest.test_case "variance single" `Quick test_variance_single;
      Alcotest.test_case "variance multiple" `Quick test_variance_multiple;
      Alcotest.test_case "welch_t insufficient" `Quick test_welch_t_insufficient_samples;
      Alcotest.test_case "welch_t identical" `Quick test_welch_t_identical_groups;
      Alcotest.test_case "welch_t different" `Quick test_welch_t_different_groups;
      Alcotest.test_case "cohens_d identical" `Quick test_cohens_d_identical;
      Alcotest.test_case "cohens_d large" `Quick test_cohens_d_large_effect;
    ]);
    ("serialization", [
      Alcotest.test_case "assignment roundtrip" `Quick test_assignment_roundtrip;
      Alcotest.test_case "observation roundtrip" `Quick test_observation_roundtrip;
      Alcotest.test_case "experiment roundtrip" `Quick test_experiment_roundtrip;
    ]);
    ("dispatch", [
      Alcotest.test_case "unknown tool" `Quick test_dispatch_unknown_tool;
      Alcotest.test_case "routes all seven" `Quick test_dispatch_routes_all_seven;
    ]);
    ("experiment_start", [
      Alcotest.test_case "minimal" `Quick test_start_minimal;
      Alcotest.test_case "with metrics+window" `Quick test_start_with_metrics_and_window;
      Alcotest.test_case "missing hypothesis" `Quick test_start_missing_hypothesis;
      Alcotest.test_case "missing treatment" `Quick test_start_missing_treatment;
      Alcotest.test_case "missing control" `Quick test_start_missing_control;
    ]);
    ("experiment_assign", [
      Alcotest.test_case "treatment" `Quick test_assign_treatment;
      Alcotest.test_case "control" `Quick test_assign_control;
      Alcotest.test_case "missing experiment_id" `Quick test_assign_missing_experiment_id;
      Alcotest.test_case "nonexistent experiment" `Quick test_assign_nonexistent_experiment;
    ]);
    ("experiment_observe", [
      Alcotest.test_case "valid" `Quick test_observe_valid;
      Alcotest.test_case "missing metric" `Quick test_observe_missing_metric;
      Alcotest.test_case "nonexistent experiment" `Quick test_observe_nonexistent_experiment;
    ]);
    ("experiment_checkpoint", [
      Alcotest.test_case "with data" `Quick test_checkpoint_with_data;
      Alcotest.test_case "no data" `Quick test_checkpoint_no_data;
      Alcotest.test_case "nonexistent" `Quick test_checkpoint_nonexistent;
    ]);
    ("experiment_conclude", [
      Alcotest.test_case "running experiment" `Quick test_conclude_running_experiment;
      Alcotest.test_case "already concluded" `Quick test_conclude_already_concluded;
      Alcotest.test_case "nonexistent" `Quick test_conclude_nonexistent;
    ]);
    ("experiment_list", [
      Alcotest.test_case "empty" `Quick test_list_empty;
      Alcotest.test_case "after creation" `Quick test_list_after_creation;
      Alcotest.test_case "status filter" `Quick test_list_with_status_filter;
      Alcotest.test_case "limit" `Quick test_list_with_limit;
    ]);
    ("experiment_status", [
      Alcotest.test_case "running" `Quick test_status_running;
      Alcotest.test_case "with assignments" `Quick test_status_with_assignments;
      Alcotest.test_case "nonexistent" `Quick test_status_nonexistent;
    ]);
    ("concluded_rejects_mutations", [
      Alcotest.test_case "assign to concluded" `Quick test_assign_to_concluded;
      Alcotest.test_case "observe concluded" `Quick test_observe_concluded;
    ]);
    ("schemas", [
      Alcotest.test_case "count" `Quick test_schemas_count;
      Alcotest.test_case "unique names" `Quick test_schemas_unique_names;
      Alcotest.test_case "have descriptions" `Quick test_schemas_have_descriptions;
    ]);
    ("lifecycle", [
      Alcotest.test_case "full e2e" `Quick test_full_lifecycle;
    ]);
  ]
