(** Integration tests for Procedure_tool_materializer.

    These tests create a temporary directory structure with real procedure
    JSONL files, set ME_ROOT to point at it, and exercise the full
    materialize_mature_procedures pipeline (filesystem discovery, threshold
    filtering, dispatch registration, duplicate prevention).

    Note: The handler calls Oas_worker.run_named which requires Eio context
    (net, switch). We do NOT invoke the handler here — only verify that
    the dispatch registration and threshold filtering work correctly. *)

module Materializer = Masc_mcp.Procedure_tool_materializer
module Proc_mem = Masc_mcp.Procedural_memory
module Tool_dispatch = Masc_mcp.Tool_dispatch

(* ================================================================ *)
(* Temp dir helpers                                                 *)
(* ================================================================ *)

let tmp_base = Filename.get_temp_dir_name ()

let make_temp_root () =
  let name = Printf.sprintf "masc-test-%d-%06x"
    (int_of_float (Unix.gettimeofday ()))
    (Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFFFF) in
  let root = Filename.concat tmp_base name in
  Unix.mkdir root 0o755;
  root

let ensure_dir path =
  let parts = String.split_on_char '/' path in
  let _built = List.fold_left (fun acc part ->
    if part = "" then acc  (* skip empty parts from leading slash *)
    else begin
      let next = if acc = "" then "/" ^ part else Filename.concat acc part in
      (try Unix.mkdir next 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      next
    end
  ) "" parts in
  ()

let write_procedure_jsonl ~root ~agent_name (procs : Proc_mem.procedure list) =
  let dir = Printf.sprintf "%s/.masc/procedures/%s" root agent_name in
  ensure_dir dir;
  let path = Filename.concat dir "procedures.jsonl" in
  let lines = List.map (fun p ->
    Yojson.Safe.to_string (Proc_mem.to_json p)
  ) procs in
  let content = String.concat "\n" lines ^ "\n" in
  let oc = open_out path in
  output_string oc content;
  close_out oc

let rec rm_rf path =
  if Sys.is_directory path then begin
    Array.iter (fun name ->
      rm_rf (Filename.concat path name)
    ) (Sys.readdir path);
    Unix.rmdir path
  end else
    Sys.remove path

(* ================================================================ *)
(* Procedure factories                                              *)
(* ================================================================ *)

let mature_procedure ?(id = "proc-mature-001") () : Proc_mem.procedure =
  { id;
    agent_name = "keeper-alpha";
    pattern = "When build fails, check dune-project version first";
    evidence = ["ev1"; "ev2"; "ev3"; "ev4"; "ev5"; "ev6"];
    success_count = 6;
    failure_count = 0;
    confidence = 1.0;
    created_at = 1000.0;
    last_applied = 2000.0;
  }

let immature_low_confidence () : Proc_mem.procedure =
  { id = "proc-immature-low-conf";
    agent_name = "keeper-alpha";
    pattern = "Try restarting the server";
    evidence = ["ev1"; "ev2"; "ev3"; "ev4"; "ev5"];
    success_count = 3;
    failure_count = 2;
    confidence = 0.6;
    created_at = 1000.0;
    last_applied = 2000.0;
  }

let immature_low_evidence () : Proc_mem.procedure =
  { id = "proc-immature-low-ev";
    agent_name = "keeper-alpha";
    pattern = "Use strict mode for type checking";
    evidence = ["ev1"; "ev2"];
    success_count = 2;
    failure_count = 0;
    confidence = 1.0;
    created_at = 1000.0;
    last_applied = 2000.0;
  }

(* ================================================================ *)
(* Test: mature procedure gets materialized                         *)
(* ================================================================ *)

let test_materialize_mature () =
  let root = make_temp_root () in
  let old_me_root = Sys.getenv_opt "ME_ROOT" in
  Unix.putenv "ME_ROOT" root;
  Fun.protect ~finally:(fun () ->
    (match old_me_root with
     | Some v -> Unix.putenv "ME_ROOT" v
     | None -> (* Cannot truly unsetenv in OCaml, set to empty *)
       Unix.putenv "ME_ROOT" "");
    (try rm_rf root with _ -> ())
  ) (fun () ->
    let proc = mature_procedure () in
    write_procedure_jsonl ~root ~agent_name:"keeper-alpha" [proc];

    let newly = Materializer.materialize_mature_procedures () in
    Alcotest.(check bool) "at least one materialized"
      true (List.length newly >= 1);

    let found = List.find_opt (fun (mt : Materializer.materialized_tool) ->
      mt.procedure_id = "proc-mature-001"
    ) newly in
    Alcotest.(check bool) "mature procedure found" true (Option.is_some found);

    let mt = Option.get found in
    Alcotest.(check bool) "tool name has proc_ prefix"
      true (String.length mt.tool_name >= 5
            && String.sub mt.tool_name 0 5 = "proc_");
    Alcotest.(check bool) "registered in dispatch"
      true (Tool_dispatch.is_registered mt.tool_name)
  )

(* ================================================================ *)
(* Test: immature procedures are NOT materialized                   *)
(* ================================================================ *)

let test_skip_immature () =
  let root = make_temp_root () in
  let old_me_root = Sys.getenv_opt "ME_ROOT" in
  Unix.putenv "ME_ROOT" root;
  Fun.protect ~finally:(fun () ->
    (match old_me_root with
     | Some v -> Unix.putenv "ME_ROOT" v
     | None -> Unix.putenv "ME_ROOT" "");
    (try rm_rf root with _ -> ())
  ) (fun () ->
    let low_conf = immature_low_confidence () in
    let low_ev = immature_low_evidence () in
    write_procedure_jsonl ~root ~agent_name:"keeper-alpha" [low_conf; low_ev];

    let newly = Materializer.materialize_mature_procedures () in
    let found_low_conf = List.exists (fun (mt : Materializer.materialized_tool) ->
      mt.procedure_id = "proc-immature-low-conf"
    ) newly in
    let found_low_ev = List.exists (fun (mt : Materializer.materialized_tool) ->
      mt.procedure_id = "proc-immature-low-ev"
    ) newly in
    Alcotest.(check bool) "low confidence not materialized" false found_low_conf;
    Alcotest.(check bool) "low evidence not materialized" false found_low_ev
  )

(* ================================================================ *)
(* Test: duplicate prevention                                       *)
(* ================================================================ *)

let test_no_duplicate () =
  let root = make_temp_root () in
  let old_me_root = Sys.getenv_opt "ME_ROOT" in
  Unix.putenv "ME_ROOT" root;
  Fun.protect ~finally:(fun () ->
    (match old_me_root with
     | Some v -> Unix.putenv "ME_ROOT" v
     | None -> Unix.putenv "ME_ROOT" "");
    (try rm_rf root with _ -> ())
  ) (fun () ->
    let proc = { (mature_procedure ~id:"proc-dedup-test" ()) with
      pattern = "Dedup test unique procedure for preventing duplicates"
    } in
    write_procedure_jsonl ~root ~agent_name:"keeper-alpha" [proc];

    let first = Materializer.materialize_mature_procedures () in
    let count_first = List.length (List.filter (fun (mt : Materializer.materialized_tool) ->
      mt.procedure_id = "proc-dedup-test"
    ) first) in

    (* Call again — should not duplicate *)
    let second = Materializer.materialize_mature_procedures () in
    let count_second = List.length (List.filter (fun (mt : Materializer.materialized_tool) ->
      mt.procedure_id = "proc-dedup-test"
    ) second) in

    Alcotest.(check int) "first call materializes once" 1 count_first;
    Alcotest.(check int) "second call skips duplicate" 0 count_second
  )

(* ================================================================ *)
(* Test: multi-agent discovery                                      *)
(* ================================================================ *)

let test_multi_agent () =
  let root = make_temp_root () in
  let old_me_root = Sys.getenv_opt "ME_ROOT" in
  Unix.putenv "ME_ROOT" root;
  Fun.protect ~finally:(fun () ->
    (match old_me_root with
     | Some v -> Unix.putenv "ME_ROOT" v
     | None -> Unix.putenv "ME_ROOT" "");
    (try rm_rf root with _ -> ())
  ) (fun () ->
    let proc_a = { (mature_procedure ~id:"proc-agent-a" ()) with
      agent_name = "agent-a";
      pattern = "Agent A unique procedure for review"
    } in
    let proc_b = { (mature_procedure ~id:"proc-agent-b" ()) with
      agent_name = "agent-b";
      pattern = "Agent B unique procedure for deploy"
    } in
    write_procedure_jsonl ~root ~agent_name:"agent-a" [proc_a];
    write_procedure_jsonl ~root ~agent_name:"agent-b" [proc_b];

    let agents = Materializer.discover_agent_names () in
    Alcotest.(check bool) "discovers multiple agents"
      true (List.length agents >= 2);
    Alcotest.(check bool) "agent-a found"
      true (List.mem "agent-a" agents);
    Alcotest.(check bool) "agent-b found"
      true (List.mem "agent-b" agents);

    let newly = Materializer.materialize_mature_procedures () in
    let has_a = List.exists (fun (mt : Materializer.materialized_tool) ->
      mt.procedure_id = "proc-agent-a") newly in
    let has_b = List.exists (fun (mt : Materializer.materialized_tool) ->
      mt.procedure_id = "proc-agent-b") newly in
    Alcotest.(check bool) "agent-a procedure materialized" true has_a;
    Alcotest.(check bool) "agent-b procedure materialized" true has_b
  )

(* ================================================================ *)
(* Test: dematerialize removes from listing                         *)
(* ================================================================ *)

let test_dematerialize_removes () =
  let root = make_temp_root () in
  let old_me_root = Sys.getenv_opt "ME_ROOT" in
  Unix.putenv "ME_ROOT" root;
  Fun.protect ~finally:(fun () ->
    (match old_me_root with
     | Some v -> Unix.putenv "ME_ROOT" v
     | None -> Unix.putenv "ME_ROOT" "");
    (try rm_rf root with _ -> ())
  ) (fun () ->
    let proc = { (mature_procedure ~id:"proc-dematerialize-test" ()) with
      pattern = "Dematerialization target procedure unique"
    } in
    write_procedure_jsonl ~root ~agent_name:"keeper-alpha" [proc];

    let newly = Materializer.materialize_mature_procedures () in
    let mt = List.find (fun (mt : Materializer.materialized_tool) ->
      mt.procedure_id = "proc-dematerialize-test"
    ) newly in

    let count_before = Materializer.materialized_count () in
    Materializer.dematerialize ~tool_name:mt.tool_name;
    let count_after = Materializer.materialized_count () in

    Alcotest.(check bool) "count decreased by 1"
      true (count_after = count_before - 1);

    let still_listed = List.exists (fun (mt2 : Materializer.materialized_tool) ->
      mt2.procedure_id = "proc-dematerialize-test"
    ) (Materializer.materialized_tools ()) in
    Alcotest.(check bool) "no longer in listing" false still_listed
  )

(* ================================================================ *)
(* Test runner                                                      *)
(* ================================================================ *)

let () =
  let open Alcotest in
  run "Procedure_materializer_integration"
    [
      ( "materialize",
        [
          test_case "mature procedure gets materialized" `Quick test_materialize_mature;
          test_case "immature procedures skipped" `Quick test_skip_immature;
          test_case "no duplicate materialization" `Quick test_no_duplicate;
          test_case "multi-agent discovery" `Quick test_multi_agent;
        ] );
      ( "dematerialize",
        [
          test_case "removes from listing" `Quick test_dematerialize_removes;
        ] );
    ]
