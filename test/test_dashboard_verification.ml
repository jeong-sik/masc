(** Tests for {!Dashboard_verification} — Mission detail projection of
    verification requests.

    The projection reads [Verification.list_requests] against
    [Env_config_core.base_path ()], so these tests override
    [MASC_BASE_PATH] with a throwaway temp dir before invoking the
    projection. That keeps the tests independent from whatever is sitting
    in the user's real [.masc/verifications/] directory. *)

(* Mirage_crypto_rng is consumed by Verification.generate_id. *)
let () = Mirage_crypto_rng_unix.use_default ()

module V = Masc_mcp.Verification
module D = Masc_mcp.Dashboard_verification

(* ── Fixture helpers ────────────────────────────────── *)

(** Create an isolated MASC base_path for the duration of [f].
    Restores [MASC_BASE_PATH] afterwards so subsequent tests in the same
    binary see the original value. *)
let with_temp_base_path f =
  let dir = Filename.temp_dir "masc_dashboard_verify_test" "" in
  let prior =
    try Some (Unix.getenv "MASC_BASE_PATH") with Not_found -> None
  in
  Unix.putenv "MASC_BASE_PATH" dir;
  let cleanup () =
    (match prior with
     | Some v -> Unix.putenv "MASC_BASE_PATH" v
     | None -> Unix.putenv "MASC_BASE_PATH" "");
    let vdir = Filename.concat dir "verifications" in
    (try
       Array.iter (fun file ->
         try Sys.remove (Filename.concat vdir file) with _ -> ()
       ) (Sys.readdir vdir);
       Sys.rmdir vdir
     with _ -> ());
    (try Sys.rmdir dir with _ -> ())
  in
  Fun.protect ~finally:cleanup (fun () -> f dir)

let create_pending_request ~base_path ~task_id ~worker ~criteria ~evidence =
  let output = `Assoc [
    ("evidence_refs", `List (List.map (fun s -> `String s) evidence));
    ("task_title", `String (Printf.sprintf "title for %s" task_id));
  ] in
  match V.create_request ~base_path ~task_id ~output ~criteria ~worker () with
  | Ok req -> req
  | Error e -> Alcotest.fail (Printf.sprintf "create_request failed: %s" e)

let member key j = Yojson.Safe.Util.member key j

(* ── Tests ──────────────────────────────────────────── *)

let test_requests_json_shape () =
  with_temp_base_path (fun base_path ->
    let _req = create_pending_request ~base_path
        ~task_id:"task-shape"
        ~worker:"keeper-alpha"
        ~criteria:[
          V.Custom "Must reduce FD leak";
          V.Custom "Must pass integration tests";
        ]
        ~evidence:["artifacts/lsof.before"; "artifacts/lsof.after"] in
    let j = D.requests_json () in
    (* Envelope: updated_at, total, requests *)
    (match member "updated_at" j with
     | `String _ -> ()
     | _ -> Alcotest.fail "updated_at should be string");
    (match member "total" j with
     | `Int n ->
         Alcotest.(check int) "total = 1" 1 n
     | _ -> Alcotest.fail "total should be int");
    let reqs = match member "requests" j with
      | `List xs -> xs
      | _ -> Alcotest.fail "requests should be list"
    in
    Alcotest.(check int) "one request" 1 (List.length reqs);
    let r = List.hd reqs in
    (* Required per-request fields *)
    let required_string_fields = [
      "request_id"; "task_id"; "task_title"; "status"; "created_at";
      "submitted_by"; "verdict_reason";
    ] in
    List.iter (fun key ->
      match member key r with
      | `String _ -> ()
      | _ ->
          Alcotest.fail
            (Printf.sprintf "%s should be string, got %s"
               key (Yojson.Safe.to_string (member key r)))
    ) required_string_fields;
    (* Nullable fields *)
    let nullable_string_fields = ["keeper"; "approved_by"; "verdict"] in
    List.iter (fun key ->
      match member key r with
      | `String _ | `Null -> ()
      | _ ->
          Alcotest.fail
            (Printf.sprintf "%s should be string or null" key)
    ) nullable_string_fields;
    (* List fields *)
    (match member "completion_contract" r with
     | `List items ->
         Alcotest.(check int) "completion_contract len"
           2 (List.length items);
         List.iter (function
           | `String _ -> ()
           | _ -> Alcotest.fail "contract entry must be string"
         ) items
     | _ -> Alcotest.fail "completion_contract should be list");
    (match member "required_evidence" r with
     | `List items ->
         Alcotest.(check int) "required_evidence len"
           2 (List.length items);
         List.iter (function
           | `String _ -> ()
           | _ -> Alcotest.fail "evidence entry must be string"
         ) items
     | _ -> Alcotest.fail "required_evidence should be list");
    (* Pending status (no verifier yet) *)
    (match member "status" r with
     | `String "pending" -> ()
     | `String s -> Alcotest.fail (Printf.sprintf "expected pending, got %s" s)
     | _ -> Alcotest.fail "status should be string");
    (match member "submitted_by" r with
     | `String "keeper-alpha" -> ()
     | _ -> Alcotest.fail "submitted_by mismatch");
    (* task_title is pulled from the submit envelope so the UI detail cell
       has a fallback when contract/evidence/verdict_reason are all empty. *)
    (match member "task_title" r with
     | `String "title for task-shape" -> ()
     | `String s ->
         Alcotest.fail (Printf.sprintf "task_title mismatch: got %S" s)
     | _ -> Alcotest.fail "task_title should be string"))

let test_task_id_filter () =
  with_temp_base_path (fun base_path ->
    let _ = create_pending_request ~base_path
        ~task_id:"task-A" ~worker:"alpha"
        ~criteria:[V.Custom "A criterion"] ~evidence:["ref-A"] in
    let _ = create_pending_request ~base_path
        ~task_id:"task-A" ~worker:"alpha"
        ~criteria:[V.Custom "A criterion 2"] ~evidence:["ref-A2"] in
    let _ = create_pending_request ~base_path
        ~task_id:"task-B" ~worker:"beta"
        ~criteria:[V.Custom "B criterion"] ~evidence:["ref-B"] in

    (* Unfiltered: all 3 requests *)
    let j_all = D.requests_json () in
    (match member "total" j_all with
     | `Int 3 -> ()
     | `Int n ->
         Alcotest.fail (Printf.sprintf "expected 3 total, got %d" n)
     | _ -> Alcotest.fail "total not int");

    (* Filter task_id="task-A": exactly 2 requests, all with task_id = task-A *)
    let j_a = D.requests_json ~task_id:"task-A" () in
    (match member "total" j_a with
     | `Int 2 -> ()
     | `Int n ->
         Alcotest.fail (Printf.sprintf "expected 2 for task-A, got %d" n)
     | _ -> Alcotest.fail "total not int");
    (match member "requests" j_a with
     | `List reqs ->
         List.iter (fun r ->
           match member "task_id" r with
           | `String "task-A" -> ()
           | `String s ->
               Alcotest.fail
                 (Printf.sprintf "expected task-A, got %s" s)
           | _ -> Alcotest.fail "task_id not string"
         ) reqs
     | _ -> Alcotest.fail "requests not list");

    (* Filter task_id="nonexistent": 0 entries *)
    let j_none = D.requests_json ~task_id:"task-missing" () in
    (match member "total" j_none with
     | `Int 0 -> ()
     | `Int n ->
         Alcotest.fail (Printf.sprintf "expected 0, got %d" n)
     | _ -> Alcotest.fail "total not int");
    (match member "requests" j_none with
     | `List [] -> ()
     | `List _ -> Alcotest.fail "expected empty list"
     | _ -> Alcotest.fail "requests not list"))

let test_requests_json_surfaces_conflict_triage_fields () =
  with_temp_base_path (fun base_path ->
    let output =
      `Assoc [
        ("evidence_refs", `List [`String "ref-A"]);
        ("task_title", `String "conflict task");
        ("request_kind", `String "conflict_triage");
        ( "request_summary",
          `String "Conflict verification required: board / planning / mutation path disagree." );
        ( "next_action",
          `String "Reconcile board / planning / mutation surfaces before ordinary approval." );
      ]
    in
    let req =
      match V.create_request ~base_path ~task_id:"task-conflict" ~output
              ~criteria:[V.Custom "tests pass"] ~worker:"keeper-alpha" () with
      | Ok req -> req
      | Error e -> Alcotest.fail (Printf.sprintf "create_request failed: %s" e)
    in
    let j = D.requests_json ~task_id:"task-conflict" () in
    let reqs =
      match member "requests" j with
      | `List xs -> xs
      | _ -> Alcotest.fail "requests should be list"
    in
    let row =
      match reqs with
      | [row] -> row
      | _ -> Alcotest.fail "expected one request row"
    in
    (match member "request_id" row with
     | `String id when id = req.id -> ()
     | _ -> Alcotest.fail "request_id mismatch");
    (match member "request_kind" row with
     | `String "conflict_triage" -> ()
     | _ -> Alcotest.fail "request_kind mismatch");
    (match member "request_summary" row with
     | `String "Conflict verification required: board / planning / mutation path disagree." -> ()
     | _ -> Alcotest.fail "request_summary mismatch");
    (match member "next_action" row with
     | `String "Reconcile board / planning / mutation surfaces before ordinary approval." -> ()
     | _ -> Alcotest.fail "next_action mismatch"))

(* ── summary_json ───────────────────────────────────── *)

let int_field name j =
  match member name j with
  | `Int n -> n
  | _ -> Alcotest.fail (Printf.sprintf "%s not int" name)

let test_summary_empty () =
  with_temp_base_path (fun _base_path ->
    let j = D.summary_json () in
    Alcotest.(check int) "total" 0 (int_field "total" j);
    let by = member "by_status" j in
    Alcotest.(check int) "pending" 0 (int_field "pending" by);
    Alcotest.(check int) "approved" 0 (int_field "approved" by);
    Alcotest.(check int) "rejected" 0 (int_field "rejected" by);
    Alcotest.(check int) "timed_out" 0 (int_field "timed_out" by);
    match member "recent_rejections" j with
    | `List [] -> ()
    | _ -> Alcotest.fail "recent_rejections not empty list")

let test_summary_bucket_counts () =
  with_temp_base_path (fun base_path ->
    (* 2 pending + 1 approved + 2 rejected *)
    let _p1 = create_pending_request ~base_path ~task_id:"t-p1"
        ~worker:"w" ~criteria:[V.Custom "c"] ~evidence:[] in
    let _p2 = create_pending_request ~base_path ~task_id:"t-p2"
        ~worker:"w" ~criteria:[V.Custom "c"] ~evidence:[] in
    let a1 = create_pending_request ~base_path ~task_id:"t-a1"
        ~worker:"w" ~criteria:[V.Custom "c"] ~evidence:[] in
    let r1 = create_pending_request ~base_path ~task_id:"t-r1"
        ~worker:"w" ~criteria:[V.Custom "c"] ~evidence:[] in
    let r2 = create_pending_request ~base_path ~task_id:"t-r2"
        ~worker:"w" ~criteria:[V.Custom "c"] ~evidence:[] in
    let verdict_of req ~verdict =
      match V.submit_verdict ~base_path ~req_id:req.V.id
              ~verifier:"v" ~verdict with
      | Ok _ -> ()
      | Error e -> Alcotest.fail e
    in
    verdict_of a1 ~verdict:V.Pass;
    verdict_of r1 ~verdict:(V.Fail "r1 reason");
    verdict_of r2 ~verdict:(V.Fail "r2 reason");

    let j = D.summary_json () in
    Alcotest.(check int) "total" 5 (int_field "total" j);
    let by = member "by_status" j in
    Alcotest.(check int) "pending" 2 (int_field "pending" by);
    Alcotest.(check int) "approved" 1 (int_field "approved" by);
    Alcotest.(check int) "rejected" 2 (int_field "rejected" by);

    match member "recent_rejections" j with
    | `List rows ->
        Alcotest.(check int) "rejection rows" 2 (List.length rows);
        List.iter (fun row ->
          match member "verdict_reason" row with
          | `String s when s <> "" -> ()
          | _ -> Alcotest.fail "verdict_reason missing/empty"
        ) rows
    | _ -> Alcotest.fail "recent_rejections not list")

let test_summary_recent_clamp () =
  with_temp_base_path (fun base_path ->
    (* recent=0 returns empty list even when rejections exist *)
    let r = create_pending_request ~base_path ~task_id:"t"
        ~worker:"w" ~criteria:[V.Custom "c"] ~evidence:[] in
    (match V.submit_verdict ~base_path ~req_id:r.V.id
             ~verifier:"v" ~verdict:(V.Fail "x") with
     | Ok _ -> () | Error e -> Alcotest.fail e);
    let j = D.summary_json ~recent:0 () in
    (match member "recent_rejections" j with
     | `List [] -> ()
     | _ -> Alcotest.fail "expected empty list at recent=0");
    (* recent > 20 clamps to 20 (smoke: ensures no crash) *)
    let _ = D.summary_json ~recent:999 () in ())

(* ── Registration ───────────────────────────────────── *)

let () =
  Alcotest.run "dashboard_verification" [
    "requests_json", [
      Alcotest.test_case "shape" `Quick test_requests_json_shape;
      Alcotest.test_case "task_id filter" `Quick test_task_id_filter;
      Alcotest.test_case "conflict triage fields" `Quick
        test_requests_json_surfaces_conflict_triage_fields;
    ];
    "summary_json", [
      Alcotest.test_case "empty base_path" `Quick test_summary_empty;
      Alcotest.test_case "bucket counts + recent rejections"
        `Quick test_summary_bucket_counts;
      Alcotest.test_case "recent clamp" `Quick test_summary_recent_clamp;
    ];
  ]
