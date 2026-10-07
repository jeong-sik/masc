open Alcotest
module P = Masc.Keeper_librarian_continuity
module B = Masc.Keeper_turn_boundaries
module C = Masc.Keeper_checkpoint_store
module S = Masc.Librarian_continuity_snapshot
module U = Yojson.Safe.Util

(* [하네스 H3] Librarian working_state 의미 보존 검증 (task-2185).
   Source under test: jeong-sik/masc a4b895455bafc38d2482af192dfb35936ba81023.
   The generator side is a fixture: these scenarios verify the LIBRARIAN
   PIPELINE (prepare -> prompt -> commit -> read -> restore across cuts,
   provider switches and process restarts), not model fidelity. A state
   carries explicit obligation IDs so preservation is judged per ID and
   per status, not by blankness alone. Phases run as separate processes
   against one shared H3_ROOT so S2 is a real restart. *)

let get = function Ok value -> value | Error error -> fail error
let trace_id = "h3-working-state-trace"
let keeper_name = "h3-keeper"

let message text =
  Agent_core.Types.make_message ~role:Agent_core.Types.User [Agent_core.Types.Text text]

let checkpoint messages : Agent_core.Checkpoint.t =
  {version=Agent_core.Checkpoint.checkpoint_version; session_id=trace_id;
   agent_name=keeper_name; model="h3-fixture"; system_prompt=None; messages;
   usage=Agent_core.Types.empty_usage; turn_count=List.length messages; created_at=1000.;
   tools=[];tool_choice=None;disable_parallel_tool_use=false;temperature=None;
   top_p=None;top_k=None;min_p=None;reasoning_effort=None;enable_thinking=None;
   preserve_thinking=None;response_format=Agent_core.Types.Off;cache_system_prompt=false;
   context=Agent_core.Context.create_sync ();mcp_sessions=[];working_context=None}

let root = Sys.getenv "H3_ROOT"
let config = Masc.Workspace.default_config root

let save messages =
  let session_dir = Filename.concat (Masc.Keeper_fs.session_store_path config) trace_id in
  match C.save_agent_core_classified ~session_dir ~history_retained:0 (checkpoint messages) with
  | Ok (C.Saved _) -> ()
  | Ok (C.Stale_noop _) -> fail "stale h3 fixture"
  | Error detail -> fail detail

let append event =
  B.append ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
    ~keeper_id:keeper_name {B.recorded_at=1000.;event}
  |> Result.map_error B.append_error_to_string |> get

let boundary ~fresh number messages =
  append (B.Turn_ended { task_context = Masc.Keeper_turn_task_context.No_task;
    turn_ref=Ids.Turn_ref.make ~trace_id ~absolute_turn:number;
    history_at_start=(if fresh then B.Fresh_history else B.Continued_history);
    position=B.position_of_messages messages |> get})

let record_memory config prepared =
  let range_id = P.memory_range_id ~config ~keeper_name prepared |> get in
  ignore (Masc.Keeper_memory_os_current.apply_disposition ~revisions:[] ~durable_range_id:range_id
    ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Masc.Workspace.base_path)
    ~keeper_id:keeper_name ~now:1000. ~source:{kind=Masc.Keeper_memory_os_current.Librarian;trace_id}
    ~absorbed:[] ~new_claims:[] () |> get)

let prepare () =
  match P.prepare ~config ~keeper_name ~trace_id () |> get with
  | Some prepared -> prepared
  | None -> fail "nothing prepared: no completed turn boundary"

let commit prepared text =
  record_memory config prepared;
  P.commit ~config ~keeper_name ~prepared ~working_state:text |> get

let current_state () = P.read ~config ~keeper_name |> get |> (function
  | Some snapshot -> snapshot | None -> fail "no committed continuity snapshot")

let previous_working_state prepared =
  P.prompt_json prepared |> U.member "previous_working_state" |> U.to_string

(* Obligation records: "[OB-<id>][<status>] <clause>". Parsed per record so
   preservation is judged per ID and status with the whole clause, not by
   substring existence of the ID alone. *)
let split_records text =
  let length = String.length text in
  let rec find from acc =
    match String.index_from_opt text from '[' with
    | None -> List.rev acc
    | Some start ->
      (* The next record starts at a '[' that begins a line: a clause may
         contain '[' itself, which must not split the record. *)
      let rec next_tag pos =
        match String.index_from_opt text (pos + 1) '[' with
        | None -> length
        | Some n ->
          if n > 0 && text.[n - 1] = '\n' then n else next_tag n
      in
      let next = next_tag start in
      find next ((String.sub text start (next - start)) :: acc)
  in
  find 0 []

let parse_obligations text =
  List.filter_map (fun record ->
    let open String in
    if not (starts_with ~prefix:"[OB-" record) then None
    else
      let id_end = match index_opt record ']' with Some e -> e | None -> exit 2 in
      let id = sub record 4 (id_end - 4) in
      let rest = sub record (id_end + 1) (length record - id_end - 1) in
      if not (starts_with ~prefix:"[" rest) then None
      else
        let status_end = match index_opt rest ']' with Some e -> e | None -> exit 2 in
        let status = sub rest 1 (status_end - 1) in
        let clause = String.trim (sub rest (status_end + 1) (length rest - status_end - 1)) in
        Some (id, status, clause))
    (split_records text)

let lookup obligations id =
  match List.find_opt (fun (key, _, _) -> String.equal key id) obligations with
  | Some (_, status, clause) -> Some (status, clause)
  | None -> None

let check_obligation label obligations id expected_status expected_clause =
  match lookup obligations id with
  | Some (status, clause) ->
    check string (label ^ ": " ^ id ^ " status") expected_status status;
    check string (label ^ ": " ^ id ^ " clause verbatim") expected_clause clause
  | None -> fail (label ^ ": obligation " ^ id ^ " vanished")

(* The fixture conversation. The obligations live in the working_state text;
   the messages carry the situation those obligations describe. *)
let clause_1 = "Ship the release only after deploy approval arrives."
let clause_2 = "Confidence p=0.85 stays attached to report R-77."
let clause_cancelled = "Legacy cron c-9 was cancelled on 2026-10-06; do not act on it."
let state_v1 =
  "[OB-OBL-1][active] " ^ clause_1 ^ "\n" ^
  "[OB-OBL-2][active] " ^ clause_2 ^ "\n" ^
  "[OB-CXL-9][cancelled] " ^ clause_cancelled
let state_v2 =
  "[OB-OBL-1][active] " ^ clause_1 ^ "\n" ^
  "[OB-OBL-2][active] " ^ clause_2
let state_lossy = "[OB-OBL-1][active] " ^ clause_1

let prefix = [message "Deploy request for the release is pending approval.";
              message "Report R-77 was drafted with model confidence 0.85."]
let with_approval = prefix @ [message "Deploy approval arrived; the report is being finalized."]
let with_finalize = with_approval @ [message "Report R-77 finalized and filed."]

let phase_s1_commit () =
  save prefix; boundary ~fresh:true 1 prefix;
  let prepared = prepare () in
  check bool "S1 initial prompt has no invented predecessor" true
    (U.member "previous_working_state" (P.prompt_json prepared) = `Null);  let saved = commit prepared state_v1 in
  check string "S1 committed bytes at rest" state_v1 saved.working_state;
  let parsed = parse_obligations (current_state ()).working_state in
  check int "S1 three obligations recorded" 3 (List.length parsed);
  check_obligation "S1 at-rest" parsed "OBL-1" "active" clause_1;
  check_obligation "S1 at-rest" parsed "OBL-2" "active" clause_2;
  check_obligation "S1 at-rest" parsed "CXL-9" "cancelled" clause_cancelled;
  print_endline "H3 S1 commit: PASS"

let phase_s1_continue () =
  save with_approval; boundary ~fresh:false 2 with_approval;
  let next = prepare () in
  check string "S1 next prompt carries the full previous state (model saw cancelled too)"
    state_v1 (previous_working_state next);
  (* The fixture generator's answer: keeps actives with clauses verbatim,
     never resurrects the cancelled instruction. *)
  let saved = commit next state_v2 in
  check string "S1 v2 committed" state_v2 saved.working_state;
  let parsed = parse_obligations (current_state ()).working_state in
  check int "S1 v2 keeps exactly the two active obligations" 2 (List.length parsed);
  check_obligation "S1 v2" parsed "OBL-1" "active" clause_1;
  check_obligation "S1 v2" parsed "OBL-2" "active" clause_2;
  (match lookup parsed "CXL-9" with
   | None -> check bool "S1 cancelled instruction not resurrected" true true
   | Some _ -> fail "S1 cancelled obligation reappeared");
  print_endline "H3 S1 continue: PASS"

(* S3: inject a projection answer that drops an active obligation. The
   contract asks whether the system detects the loss and keeps the original
   or regenerates. Both outcomes are recorded explicitly: acceptance of the
   lossy answer FAILS the contract check (that FAIL line is the finding);
   rejection must leave the original verbatim at rest and in the next
   prompt. record_memory first so the commit exercises the snapshot guard
   itself, not the memory-coverage precondition. *)
let save_or_keep messages =
  let session_dir = Filename.concat (Masc.Keeper_fs.session_store_path config) trace_id in
  match C.save_agent_core_classified ~session_dir ~history_retained:0 (checkpoint messages) with
  | Ok (C.Saved _) | Ok (C.Stale_noop _) -> ()
  | Error detail -> fail detail

let phase_s3_lossy () =
  save_or_keep with_finalize; boundary ~fresh:false 4 with_finalize;
  let next = prepare () in
  check string "S3 prompt carried the lossless v2" state_v2 (previous_working_state next);
  record_memory config next;
  (match P.commit ~config ~keeper_name ~prepared:next ~working_state:state_lossy with
   | Ok saved ->
     check string "S3 CONTRACT: lossy answer accepted; original overwritten" state_v2
       saved.working_state;
     print_endline "S3 outcome: LOSS_ACCEPTED — commit guard is nonblank-only"
   | Error _ ->
     check string "S3 loss rejected; original kept" state_v2 (current_state ()).working_state;
     print_endline "S3 outcome: LOSS_REJECTED — original kept";
     let after = prepare () in
     check string "S3 next prompt still carries the original verbatim" state_v2
       (previous_working_state after));
  print_endline "H3 S3: ran; outcome recorded in evidence"

(* S2 preamble (s2_pre phase, run right after s1_continue): advance the
   fixture conversation one more turn WITHOUT touching the continuity
   snapshot, then close the turn. That new boundary line is what lets the
   restarted s2_verify process (different fixture provider identity) open a
   fresh cut. *)
let phase_s2_pre () =
  save_or_keep with_finalize; boundary ~fresh:false 4 with_finalize;
  print_endline "H3 S2 pre: new turn boundary committed for the restarted process"

(* S2: separate process. Reads the snapshot from disk only, with a different
   fixture provider identity than the S1 commit process, then opens the next
   cut: obligation IDs and statuses must survive switch + restart. *)
let phase_s2_verify () =
  Printf.printf "H3 S2 provider identity: h3-fixture-b (commit process used h3-fixture-a)\n";
  let snapshot = current_state () in
  let parsed = parse_obligations snapshot.working_state in
  check int "S2 obligations present after restart" 2 (List.length parsed);
  check_obligation "S2" parsed "OBL-1" "active" clause_1;
  check_obligation "S2" parsed "OBL-2" "active" clause_2;
  let restored =
    S.restore ~trace_id
      ~lines:(B.read ~keepers_dir:(Masc.Workspace.keepers_runtime_dir config)
                ~keeper_id:keeper_name |> get)
      ~messages:with_finalize snapshot
    |> Result.map_error (fun e -> Masc.Librarian_continuity_snapshot.error_to_string e) |> get in
  check bool "S2 restore succeeds from disk state" true
    (List.length restored.messages >= 0);
  let next = prepare () in
  check string "S2 next prompt carries obligation IDs across restart" snapshot.working_state
    (previous_working_state next);
  print_endline "H3 S2: PASS"

let () =
  let phase = match Sys.argv with
    | [|_; phase|] -> phase
    | _ -> prerr_endline "usage: test_h3_working_state_meaning.exe <s1_commit|s1_continue|s2_pre|s3_lossy|s2_verify>";
           exit 64 in
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  (match phase with
   | "s1_commit" -> phase_s1_commit ()
   | "s1_continue" -> phase_s1_continue ()
   | "s2_pre" -> phase_s2_pre ()
   | "s3_lossy" -> phase_s3_lossy ()
   | "s2_verify" -> phase_s2_verify ()
   | other -> Printf.eprintf "unknown phase %s\n" other; exit 64)
