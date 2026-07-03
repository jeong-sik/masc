(* RFC-0266 §7 Phase 3 — masc_fusion_status tool.

   Two failure modes a stub could introduce while still compiling:

   1. the JSON projection [fusion_status_json] leaks another keeper's run or
      mislabels a run status (e.g.
      reports a denied/sink-failed run as "completed"), or returns the wrong
      shape for list vs single-run vs unknown-run_id; and
   2. the tool is wired but NOT visible to the keeper LLM (Pass B requires
      visibility=Default; read_only_in_process_policy defaults to Hidden, so a
      missing override would silently hide the tool while compiling fine).

   [fusion_status_json] is pure over a registry instance, so it is exercised on
   isolated [Fusion_run_registry.create ()] tables (no global-state coupling). *)

open Alcotest
open Masc
module R = Fusion_run_registry
module H = Keeper_tool_in_process_runtime

let parse s = Yojson.Safe.from_string s

let field j k =
  match j with
  | `Assoc l -> List.assoc_opt k l
  | _ -> None
;;

let str j k =
  match field j k with
  | Some (`String s) -> s
  | _ -> failwith (Printf.sprintf "missing string field %s" k)
;;

let bool_ j k =
  match field j k with
  | Some (`Bool b) -> b
  | _ -> failwith (Printf.sprintf "missing bool field %s" k)
;;

let int_ j k =
  match field j k with
  | Some (`Int i) -> i
  | _ -> failwith (Printf.sprintf "missing int field %s" k)
;;

let runs_of j =
  match field j "runs" with
  | Some (`List l) -> l
  | _ -> failwith "missing runs list"
;;

let find_run runs id =
  match List.find_opt (fun r -> String.equal (str r "run_id") id) runs with
  | Some r -> r
  | None -> failwith (Printf.sprintf "run %s not present in list" id)
;;

(* a registry carrying one of each terminal/active status *)
let seeded () =
  let t = R.create () in
  R.register_running t ~run_id:"r-run" ~keeper:"k1" ~preset:"balanced" ~started_at:300.0;
  R.register_running t ~run_id:"r-done" ~keeper:"k1" ~preset:"deep" ~started_at:100.0;
  R.mark_completed t ~run_id:"r-done" ~ok:true ();
  R.register_running t ~run_id:"r-fail" ~keeper:"k1" ~preset:"deep" ~started_at:200.0;
  R.mark_completed t ~run_id:"r-fail"
    ~failure:"judge failed: timeout" ~failure_code:"timeout" ~ok:false ();
  R.register_running
    t
    ~run_id:"r-foreign"
    ~keeper:"k2"
    ~preset:"balanced"
    ~started_at:400.0;
  t
;;

(* (1a) list mode: only the calling keeper's tracked runs, newest-first, with
   the right status label. The label mapping is the mutation-sensitive core —
   ok=false must read "failed", not "completed". *)
let test_list_scoped_to_keeper () =
  let json = H.fusion_status_json ~registry:(seeded ()) ~keeper:"k1" ~run_id:"" |> parse in
  check bool "ok" true (bool_ json "ok");
  check int "count" 3 (int_ json "count");
  let runs = runs_of json in
  check int "only caller keeper runs" 3 (List.length runs);
  check string "newest started_at first" "r-run" (str (List.hd runs) "run_id");
  check string "running label" "running" (str (find_run runs "r-run") "status");
  check string "completed label" "completed" (str (find_run runs "r-done") "status");
  check string "failed label (ok=false)" "failed" (str (find_run runs "r-fail") "status");
  (* run carries its identifying metadata for the operator/keeper *)
  let r = find_run runs "r-run" in
  check string "keeper field" "k1" (str r "keeper");
  check string "preset field" "balanced" (str r "preset")
;;

(* (1b) single-run lookup: found -> {found=true; run}. *)
let test_single_found () =
  let json =
    H.fusion_status_json ~registry:(seeded ()) ~keeper:"k1" ~run_id:"r-fail" |> parse
  in
  check bool "ok" true (bool_ json "ok");
  check bool "found" true (bool_ json "found");
  let run =
    match field json "run" with
    | Some r -> r
    | None -> failwith "missing run object"
  in
  check string "single run id" "r-fail" (str run "run_id");
  check string "single run status" "failed" (str run "status")
;;

(* (1c) a keeper cannot fetch another keeper's run_id even when the run exists
   in the process-wide registry. *)
let test_single_foreign_run_not_found () =
  let json =
    H.fusion_status_json ~registry:(seeded ()) ~keeper:"k1" ~run_id:"r-foreign" |> parse
  in
  check bool "ok" true (bool_ json "ok");
  check bool "found is false" false (bool_ json "found");
  check string "echoes the queried run_id" "r-foreign" (str json "run_id");
  check string "status not_found" "not_found" (str json "status")
;;

(* (1d) unknown run_id -> a deterministic not_found envelope, not an empty/ok
   silent drop. *)
let test_single_not_found () =
  let json =
    H.fusion_status_json ~registry:(seeded ()) ~keeper:"k1" ~run_id:"ghost" |> parse
  in
  check bool "ok" true (bool_ json "ok");
  check bool "found is false" false (bool_ json "found");
  check string "echoes the queried run_id" "ghost" (str json "run_id");
  check string "status not_found" "not_found" (str json "status")
;;

(* empty registry lists nothing but still returns the ok/count/runs shape *)
let test_empty_registry () =
  let json = H.fusion_status_json ~registry:(R.create ()) ~keeper:"k1" ~run_id:"" |> parse in
  check int "empty count" 0 (int_ json "count");
  check int "empty runs list" 0 (List.length (runs_of json))
;;

(* (2) keeper-LLM visibility: masc_fusion_status must be in the Pass-B set
   (model_visible_descriptors filters visibility=Default). Hidden would compile
   but silently strip it from the keeper's tool list. Also runs the unified
   registry boot invariant (enforce_visible_tag_coverage) so a Default-visible
   tool without a dispatch tag would fail loudly here. *)
let test_tool_is_keeper_visible () =
  Masc_test_deps.init_keeper_tool_registry ();
  let visible_names =
    Keeper_tool_descriptor.model_visible_descriptors ()
    |> List.map (fun (d : Keeper_tool_descriptor.t) -> d.public_name)
  in
  check
    bool
    "masc_fusion_status is keeper-LLM-visible (Pass B Default gate)"
    true
    (List.mem "masc_fusion_status" visible_names)
;;

let () =
  run
    "fusion_status_tool"
    [ ( "rfc-0266-phase3"
      , [ test_case "list caller runs only (newest-first)" `Quick test_list_scoped_to_keeper
        ; test_case "single run found" `Quick test_single_found
        ; test_case "foreign run_id -> not_found" `Quick test_single_foreign_run_not_found
        ; test_case "unknown run_id -> not_found" `Quick test_single_not_found
        ; test_case "empty registry shape" `Quick test_empty_registry
        ; test_case "tool is visible to the keeper LLM" `Quick test_tool_is_keeper_visible
        ] )
    ]
;;
