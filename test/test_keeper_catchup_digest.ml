(* Unit tests for Masc.Keeper_catchup_digest.build over fixture stores on a
   temporary base_dir. Covers: since-boundary exclusivity, per-category
   counts, keeper-identity 3-form matching, fail-visible read_errors on a
   corrupt line, items cap, missing-store-as-zero, and to_json shape. *)

module D = Masc.Keeper_catchup_digest

let keeper = "garnet"

(* Chosen so the whole [since .. now] window sits mid-UTC-day: no fixture row
   lands on a midnight boundary that could split a day-file unexpectedly. *)
let now_unix = 1783000000.
let day = 86400.
let since_unix = now_unix -. (2. *. day)

(* ── filesystem helpers ──────────────────────────────────────────── *)

let rec mkdir_p dir =
  if not (Sys.file_exists dir)
  then (
    mkdir_p (Filename.dirname dir);
    try Unix.mkdir dir 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

let append_line path line =
  mkdir_p (Filename.dirname path);
  let oc = open_out_gen [ Open_wronly; Open_append; Open_creat ] 0o644 path in
  output_string oc (line ^ "\n");
  close_out oc
;;

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  output_string oc contents;
  close_out oc
;;

(* Day-partitioned path for a timestamp, mirroring the reader in the module
   under test (UTC YYYY-MM/DD.jsonl). *)
let day_file ~dir ts =
  let tm = Unix.gmtime ts in
  Filename.concat
    dir
    (Printf.sprintf
       "%04d-%02d/%02d.jsonl"
       (tm.Unix.tm_year + 1900)
       (tm.Unix.tm_mon + 1)
       tm.Unix.tm_mday)
;;

let str_contains ~needle haystack =
  let nl = String.length needle
  and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0
;;

let has_cause cause coverage = List.exists (( = ) cause) coverage.D.causes

let json_assoc_fields = function
  | `Assoc fields -> fields
  | _ -> []
;;

let json_string_field key fields =
  match List.assoc_opt key fields with
  | Some (`String value) -> Some value
  | Some `Null | None -> None
  | Some _ -> None
;;

let json_list_field key fields =
  match List.assoc_opt key fields with
  | Some (`List items) -> items
  | _ -> []
;;

(* ── store paths (mirror Common.*_from_base_path) ────────────────── *)

let masc base = Filename.concat base ".masc"
let keepers base = Filename.concat (masc base) "keepers"
let keeper_local base store = Filename.concat (Filename.concat (keepers base) keeper) store
let turn_dir base = keeper_local base "turn-records"
let crash_dir base = keeper_local base "crash-events"
let audit_dir base = Filename.concat (masc base) "audit"
let activity_dir base = Filename.concat (masc base) "activity-events"
let transition_dir base = Filename.concat (masc base) "transition-audit"
let chat_file base = Filename.concat (Filename.concat (masc base) "keeper_chat") (keeper ^ ".jsonl")
let meta_file base = Filename.concat (keepers base) (keeper ^ ".json")
let backlog_file base = Filename.concat (Filename.concat (masc base) "tasks") "backlog.json"

(* ── fixture row builders ────────────────────────────────────────── *)

let json_line j = Yojson.Safe.to_string j

let handoff_context ?next_step ?(evidence_refs = []) summary
  : Masc_domain.task_handoff_context
  =
  { summary
  ; reason = None
  ; next_step
  ; failure_mode = None
  ; reclaim_policy = None
  ; evidence_refs
  ; updated_at = Some "2026-07-02T00:00:00Z"
  ; updated_by = Some "digest-test"
  }
;;

let task ?handoff_context ~id ~title ~status () : Masc_domain.task =
  { id
  ; title
  ; description = "fixture task"
  ; task_status = status
  ; priority = 2
  ; files = []
  ; created_at = "2026-07-02T00:00:00Z"
  ; created_by = Some "digest-test"
  ; predecessor_task_id = None
  ; contract = None
  ; handoff_context
  ; cycle_count = 0
  ; reclaim_policy = None
  ; do_not_reclaim_reason = None
  }
;;

let write_backlog base tasks =
  let backlog : Masc_domain.backlog =
    { tasks; last_updated = "2026-07-02T00:00:00Z"; version = 1 }
  in
  write_file (backlog_file base) (json_line (Masc_domain.backlog_to_yojson backlog))
;;

let chat_row ?id ?kind ?(content = "x") ~role ~ts () =
  let base = [ "role", `String role; "content", `String content; "ts", `Float ts ] in
  let base = match id with Some i -> ("id", `String i) :: base | None -> base in
  let base = match kind with Some k -> ("kind", `String k) :: base | None -> base in
  json_line (`Assoc base)
;;

let audit_row ~ts ~agent_id ~action ~transition ~task_id =
  json_line
    (`Assoc
        [ "timestamp", `Float ts
        ; "agent_id", `String agent_id
        ; "action", `String action
        ; "workspace_id", `String "default"
        ; ( "details"
          , `Assoc
              [ "event_family", `String "task_transition"
              ; "transition", `String transition
              ; "task_id", `String task_id
              ; "agent_id", `String agent_id
              ; "from_status", `String "todo"
              ; "to_status", `String "claimed"
              ; "forced", `Bool false
              ] )
        ; "outcome", `Assoc [ "status", `String "success" ]
        ])
;;

let audit_row_without_task_id ~ts ~agent_id ~action ~transition =
  json_line
    (`Assoc
       [ "timestamp", `Float ts
       ; "agent_id", `String agent_id
       ; "action", `String action
       ; "workspace_id", `String "default"
       ; ( "details"
         , `Assoc
             [ "event_family", `String "task_transition"
             ; "transition", `String transition
             ; "agent_id", `String agent_id
             ; "from_status", `String "todo"
             ; "to_status", `String "claimed"
             ; "forced", `Bool false
             ] )
       ; "outcome", `Assoc [ "status", `String "success" ]
       ])
;;

let activity_row ~seq ~ts ~kind ~actor_id =
  json_line
    (`Assoc
        [ "seq", `Int seq
        ; "ts_ms", `Int (int_of_float (ts *. 1000.))
        ; "ts_iso", `String "2026-07-02T00:00:00Z"
        ; "workspace_id", `String "default"
        ; "kind", `String kind
        ; "actor", `Assoc [ "kind", `String "agent"; "id", `String actor_id ]
        ; "subject", `Null
        ; "payload", `Assoc []
        ; "tags", `List []
        ])
;;

let transition_row ~keeper_name ~event_type ~ts =
  json_line
    (`Assoc
        [ "keeper", `String keeper_name
        ; ( "record"
          , `Assoc
              [ "event_type", `String event_type
              ; "wall_clock_at_decision", `Float ts
              ] )
        ])
;;

let crash_row ~ts = json_line (`Assoc [ "ts", `Float ts; "reason", `String "boom"; "restart_count", `Int 1 ])

(* ── rich fixture used by the primary assertions ─────────────────── *)

let write_rich_fixture base =
  (* chat: one legacy row before since (excluded), two utterances after,
     one transport-failure and one agent-failure after (masc#24314 /
     oas#2585: the two Row_kind failure variants are counted separately,
     not merged). *)
  let cf = chat_file base in
  append_line cf (chat_row ~role:"user" ~ts:(since_unix -. 10.) ());
  append_line cf (chat_row ~id:"m1" ~role:"user" ~ts:(since_unix +. 10.) ());
  append_line cf (chat_row ~id:"m2" ~role:"assistant" ~ts:(since_unix +. 11.) ());
  append_line
    cf
    (chat_row ~id:"m3" ~role:"assistant" ~kind:"transport_failure" ~ts:(since_unix +. 12.) ());
  append_line
    cf
    (chat_row ~id:"m4" ~role:"assistant" ~kind:"agent_failure" ~ts:(since_unix +. 13.) ());
  (* turn-records across two day-files straddling since; day-file B carries a
     deliberately corrupt line that must surface in read_errors. *)
  let td = turn_dir base in
  append_line (day_file ~dir:td (since_unix -. 100.)) (json_line (`Assoc [ "ts", `Float (since_unix -. 100.) ]));
  append_line (day_file ~dir:td since_unix) (json_line (`Assoc [ "ts", `Float since_unix ]));
  append_line (day_file ~dir:td (since_unix +. 100.)) (json_line (`Assoc [ "ts", `Float (since_unix +. 100.) ]));
  append_line (day_file ~dir:td (since_unix +. day)) (json_line (`Assoc [ "ts", `Float (since_unix +. day) ]));
  append_line (day_file ~dir:td (since_unix +. day)) "{ this is not valid json";
  (* crash-events *)
  let cd = crash_dir base in
  append_line (day_file ~dir:cd (since_unix +. 500.)) (crash_row ~ts:(since_unix +. 500.));
  append_line (day_file ~dir:cd (since_unix -. 500.)) (crash_row ~ts:(since_unix -. 500.));
  (* audit task transitions — keeper identity in all three persisted forms,
     plus a foreign agent and a pre-since row that must be excluded. *)
  let ad = audit_dir base in
  let af ts = day_file ~dir:ad ts in
  append_line (af (since_unix +. 200.)) (audit_row ~ts:(since_unix +. 200.) ~agent_id:keeper ~action:"claim_task" ~transition:"claim" ~task_id:"task-1");
  append_line (af (since_unix +. 300.)) (audit_row ~ts:(since_unix +. 300.) ~agent_id:("keeper-" ^ keeper ^ "-agent") ~action:"done_task" ~transition:"done" ~task_id:"task-2");
  append_line (af (since_unix +. 400.)) (audit_row ~ts:(since_unix +. 400.) ~agent_id:("keeper:" ^ keeper) ~action:"release_task" ~transition:"release" ~task_id:"task-3");
  append_line (af (since_unix +. 500.)) (audit_row ~ts:(since_unix +. 500.) ~agent_id:"other" ~action:"claim_task" ~transition:"claim" ~task_id:"task-4");
  append_line (af (since_unix -. 200.)) (audit_row ~ts:(since_unix -. 200.) ~agent_id:keeper ~action:"claim_task" ~transition:"claim" ~task_id:"task-5");
  write_backlog
    base
    [ task
        ~id:"task-1"
        ~title:"Implement visible-text feedback guard"
        ~status:
          (Masc_domain.AwaitingVerification
             { assignee = keeper
             ; submitted_at = "2026-07-02T00:10:00Z"
             ; verification_id = "vrf-task-1"
             ; phase = Masc_domain.Awaiting_verifier
             })
        ~handoff_context:
          (handoff_context
             ~next_step:"cross-agent review"
             ~evidence_refs:[ "PR#23399"; "commit:f2678ed43" ]
             "PR is open and waiting for verification")
        ()
    ; task
        ~id:"task-2"
        ~title:"Complete dashboard follow-up"
        ~status:
          (Masc_domain.Done
             { assignee = "keeper-" ^ keeper ^ "-agent"
             ; completed_at = "2026-07-02T00:20:00Z"
             ; notes = Some "done"
             })
        ()
    ];
  (* activity-events board.* + keeper.turn_failed for the keeper; a foreign
     board row and a pre-since board row that must be excluded. *)
  let acd = activity_dir base in
  let acf ts = day_file ~dir:acd ts in
  append_line (acf (since_unix +. 600.)) (activity_row ~seq:1 ~ts:(since_unix +. 600.) ~kind:"board.posted" ~actor_id:("keeper-" ^ keeper ^ "-agent"));
  append_line (acf (since_unix +. 700.)) (activity_row ~seq:2 ~ts:(since_unix +. 700.) ~kind:"board.commented" ~actor_id:keeper);
  append_line (acf (since_unix +. 800.)) (activity_row ~seq:3 ~ts:(since_unix +. 800.) ~kind:"board.voted" ~actor_id:keeper);
  append_line (acf (since_unix +. 900.)) (activity_row ~seq:4 ~ts:(since_unix +. 900.) ~kind:"keeper.turn_failed" ~actor_id:keeper);
  append_line (acf (since_unix +. 950.)) (activity_row ~seq:5 ~ts:(since_unix +. 950.) ~kind:"board.posted" ~actor_id:"other");
  append_line (acf (since_unix -. 100.)) (activity_row ~seq:6 ~ts:(since_unix -. 100.) ~kind:"board.posted" ~actor_id:keeper);
  (* transition-audit operator pause/resume for the keeper; pre-since and
     foreign-keeper rows excluded. *)
  let ttd = transition_dir base in
  let ttf ts = day_file ~dir:ttd ts in
  append_line (ttf (since_unix +. 1000.)) (transition_row ~keeper_name:keeper ~event_type:"operator_pause" ~ts:(since_unix +. 1000.));
  append_line (ttf (since_unix +. 1100.)) (transition_row ~keeper_name:keeper ~event_type:"operator_resume" ~ts:(since_unix +. 1100.));
  append_line (ttf (since_unix -. 100.)) (transition_row ~keeper_name:keeper ~event_type:"operator_pause" ~ts:(since_unix -. 100.));
  append_line (ttf (since_unix +. 1200.)) (transition_row ~keeper_name:"other" ~event_type:"operator_pause" ~ts:(since_unix +. 1200.));
  (* meta with paused = true *)
  write_file
    (meta_file base)
    (json_line
       (`Assoc
           [ "name", `String keeper
           ; "agent_name", `String keeper
           ; "trace_id", `String "digest-test"
           ; "tool_access", `List []
           ; "paused", `Bool true
           ]))
;;

let with_workspace f =
  let base = Masc_test_deps.setup_test_workspace () in
  Fun.protect ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace base) (fun () -> f base)
;;

(* ── tests ───────────────────────────────────────────────────────── *)

let test_counts_and_boundary () =
  with_workspace (fun base ->
    write_rich_fixture base;
    let digest = D.build ~base_path:base ~keeper_name:keeper ~since_unix ~now_unix in
    let { D.chat = { new_messages; first_new_ts; transport_failures; agent_failures }
        ; turns = { completed; failed; crashes }
        ; tasks = { claimed; done_; released; cancelled; items = task_items }
        ; board = { posted; commented; voted }
        ; lifecycle = { paused_now; pause_events; resume_events; items = life_items }
        ; coverage
        ; read_errors
        ; keeper = keeper_out
        ; since_unix = since_out
        ; generated_at_unix
        }
      =
      digest
    in
    Alcotest.(check bool) "coverage.chat lower_bound false" false coverage.D.chat.lower_bound;
    Alcotest.(check bool) "coverage.turns lower_bound false" false coverage.D.turns.lower_bound;
    Alcotest.(check bool) "coverage.tasks lower_bound false" false coverage.D.tasks.lower_bound;
    Alcotest.(check bool) "coverage.board lower_bound false" false coverage.D.board.lower_bound;
    Alcotest.(check bool) "coverage.lifecycle lower_bound false" false coverage.D.lifecycle.lower_bound;
    Alcotest.(check string) "keeper echoed" keeper keeper_out;
    Alcotest.(check (float 0.0001)) "since echoed" since_unix since_out;
    Alcotest.(check (float 0.0001)) "now echoed" now_unix generated_at_unix;
    (* chat *)
    Alcotest.(check int) "new_messages (2 utterances after since)" 2 new_messages;
    Alcotest.(check int) "transport_failures" 1 transport_failures;
    Alcotest.(check int) "agent_failures" 1 agent_failures;
    Alcotest.(check (option (float 0.0001)))
      "first_new_ts is the earliest new utterance"
      (Some (since_unix +. 10.))
      first_new_ts;
    (* turns: completed excludes ts == since and ts < since *)
    Alcotest.(check int) "turns.completed" 2 completed;
    Alcotest.(check int) "turns.failed" 1 failed;
    Alcotest.(check int) "turns.crashes" 1 crashes;
    (* tasks: identity 3-form all matched (claim/done/release each = 1) *)
    Alcotest.(check int) "tasks.claimed (short-form id)" 1 claimed;
    Alcotest.(check int) "tasks.done (full agent-id form)" 1 done_;
    Alcotest.(check int) "tasks.released (keeper: prefix form)" 1 released;
    Alcotest.(check int) "tasks.cancelled" 0 cancelled;
    Alcotest.(check int) "task items (foreign + pre-since excluded)" 3 (List.length task_items);
    (match List.find_opt (fun item -> String.equal item.D.task_id "task-1") task_items with
     | Some { D.current_task = Some current; _ } ->
       Alcotest.(check string)
         "task-1 current status"
         "awaiting_verification"
         current.D.status;
       Alcotest.(check (option string))
         "task-1 submitted_at"
         (Some "2026-07-02T00:10:00Z")
         current.D.submitted_at;
       Alcotest.(check (option string))
         "task-1 handoff summary"
         (Some "PR is open and waiting for verification")
         current.D.handoff_summary;
       Alcotest.(check (list string))
         "task-1 evidence refs"
         [ "PR#23399"; "commit:f2678ed43" ]
         current.D.handoff_evidence_refs
     | Some { D.current_task = None; _ } -> Alcotest.fail "task-1 must include current_task"
     | None -> Alcotest.fail "expected task-1 item");
    (match List.find_opt (fun item -> String.equal item.D.task_id "task-3") task_items with
     | Some { D.current_task = None; _ } -> ()
     | Some { D.current_task = Some _; _ } -> Alcotest.fail "task-3 should not have a current_task"
     | None -> Alcotest.fail "expected task-3 item");
    (* board *)
    Alcotest.(check int) "board.posted" 1 posted;
    Alcotest.(check int) "board.commented" 1 commented;
    Alcotest.(check int) "board.voted" 1 voted;
    (* lifecycle *)
    Alcotest.(check bool) "paused_now" true paused_now;
    Alcotest.(check int) "pause_events" 1 pause_events;
    Alcotest.(check int) "resume_events" 1 resume_events;
    Alcotest.(check int) "lifecycle items" 2 (List.length life_items);
    (* fail-visible read error from the corrupt turn-records line *)
    Alcotest.(check bool) "read_errors non-empty" true (read_errors <> []);
    Alcotest.(check bool)
      "corrupt turn-records line surfaced"
      true
      (List.exists
         (fun s -> str_contains ~needle:"turn-records" s && str_contains ~needle:"unparseable" s)
         read_errors))
;;

let test_missing_stores_are_zero () =
  with_workspace (fun base ->
    (* No fixtures written at all: every category is zero and, crucially, no
       read_errors (a missing directory is not a failure). *)
    let digest = D.build ~base_path:base ~keeper_name:keeper ~since_unix ~now_unix in
    let { D.chat = { new_messages; transport_failures; _ }
        ; turns = { completed; failed; crashes }
        ; tasks = { claimed; done_; released; cancelled; items }
        ; board = { posted; commented; voted }
        ; lifecycle = { paused_now; pause_events; resume_events; items = life_items }
        ; read_errors
        ; _
        }
      =
      digest
    in
    Alcotest.(check int) "chat zero" 0 (new_messages + transport_failures);
    Alcotest.(check int) "turns zero" 0 (completed + failed + crashes);
    Alcotest.(check int) "tasks zero" 0 (claimed + done_ + released + cancelled);
    Alcotest.(check int) "task items empty" 0 (List.length items);
    Alcotest.(check int) "board zero" 0 (posted + commented + voted);
    Alcotest.(check bool) "not paused when no meta" false paused_now;
    Alcotest.(check int) "lifecycle zero" 0 (pause_events + resume_events);
    Alcotest.(check int) "lifecycle items empty" 0 (List.length life_items);
    Alcotest.(check bool) "no read_errors for missing stores" true (read_errors = []))
;;

let test_items_cap () =
  with_workspace (fun base ->
    let ad = audit_dir base in
    let total = D.digest_items_cap + 5 in
    for i = 1 to total do
      let ts = since_unix +. float_of_int i in
      append_line
        (day_file ~dir:ad ts)
        (audit_row ~ts ~agent_id:keeper ~action:"claim_task" ~transition:"claim"
           ~task_id:(Printf.sprintf "task-%d" i))
    done;
    let digest = D.build ~base_path:base ~keeper_name:keeper ~since_unix ~now_unix in
    let { D.tasks = { claimed; items; _ }; _ } = digest in
    Alcotest.(check int) "count is full, independent of cap" total claimed;
    Alcotest.(check int) "items capped at digest_items_cap" D.digest_items_cap (List.length items);
    (* newest-first: the first item is the most recent transition *)
    match items with
    | first :: _ ->
      Alcotest.(check (float 0.0001))
        "items newest-first"
        (since_unix +. float_of_int total)
        first.D.ts
    | [] -> Alcotest.fail "expected capped items")
;;

let test_chat_page_cap_is_fail_visible () =
  with_workspace (fun base ->
    let total = 20_001 in
    (* Pad each row so the chat file exceeds the store's tail-read window;
       otherwise a small file may return has_more=false before the page cap. *)
    let padding = String.make 400 'x' in
    let cf = chat_file base in
    for i = 1 to total do
      append_line
        cf
        (chat_row
           ~id:(Printf.sprintf "chat-%05d" i)
           ~role:"user"
           ~content:padding
           ~ts:(since_unix +. float_of_int i)
           ())
    done;
    let digest = D.build ~base_path:base ~keeper_name:keeper ~since_unix ~now_unix in
    let { D.chat = { new_messages; _ }; coverage; read_errors; _ } = digest in
    Alcotest.(check bool) "chat count is a lower bound" true
      (new_messages > 0 && new_messages < total);
    Alcotest.(check bool)
      "chat page cap is fail-visible in read_errors"
      true
      (List.exists (str_contains ~needle:"keeper-chat: page cap reached") read_errors);
    Alcotest.(check bool)
      "coverage.chat lower_bound true"
      true
      coverage.D.chat.lower_bound;
    Alcotest.(check bool)
      "coverage.chat page-cap cause present"
      true
      (has_cause D.Chat_page_cap coverage.D.chat))
;;

let test_scan_window_clamp_is_coverage_visible () =
  with_workspace (fun base ->
    (* since_unix is beyond the retention scan window, so every source is
       clamped even though the stores are missing (missing = zero activity). The
       coverage flags, not read_errors, carry the truncation signal. *)
    let since_old = now_unix -. (50. *. day) in
    let digest = D.build ~base_path:base ~keeper_name:keeper ~since_unix:since_old ~now_unix in
    let { D.coverage; read_errors; _ } = digest in
    Alcotest.(check bool) "coverage.turns lower_bound true" true coverage.D.turns.lower_bound;
    Alcotest.(check bool) "coverage.tasks lower_bound true" true coverage.D.tasks.lower_bound;
    Alcotest.(check bool) "coverage.board lower_bound true" true coverage.D.board.lower_bound;
    Alcotest.(check bool) "coverage.lifecycle lower_bound true" true coverage.D.lifecycle.lower_bound;
    Alcotest.(check bool) "coverage.chat lower_bound true" true coverage.D.chat.lower_bound;
    Alcotest.(check bool)
      "coverage.chat carries retention-window cause"
      true
      (has_cause D.Chat_retention_window coverage.D.chat);
    Alcotest.(check bool)
      "coverage.turns carries retention-window cause"
      true
      (has_cause D.Jsonl_retention_window coverage.D.turns);
    Alcotest.(check bool) "no read_errors for missing stores" true (read_errors = []))
;;

let test_task_items_are_sound_partial () =
  with_workspace (fun base ->
    let ad = audit_dir base in
    let ts_missing = since_unix +. 200. in
    let ts_invalid = since_unix +. 300. in
    append_line
      (day_file ~dir:ad ts_missing)
      (audit_row_without_task_id
         ~ts:ts_missing
         ~agent_id:keeper
         ~action:"claim_task"
         ~transition:"claim");
    append_line
      (day_file ~dir:ad ts_invalid)
      (audit_row
         ~ts:ts_invalid
         ~agent_id:keeper
         ~action:"done_task"
         ~transition:"done"
         ~task_id:"../bad");
    let digest = D.build ~base_path:base ~keeper_name:keeper ~since_unix ~now_unix in
    let { D.tasks = { claimed; done_; items; _ }; read_errors; _ } = digest in
    Alcotest.(check int) "missing-id task action still counted" 1 claimed;
    Alcotest.(check int) "invalid-id task action still counted" 1 done_;
    Alcotest.(check int) "invalid task ids do not create items" 0 (List.length items);
    Alcotest.(check bool)
      "missing task_id is fail-visible"
      true
      (List.exists (str_contains ~needle:"missing task_id") read_errors);
    Alcotest.(check bool)
      "invalid task_id is fail-visible"
      true
      (List.exists (str_contains ~needle:"invalid task_id") read_errors))
;;

let test_to_json_shape () =
  with_workspace (fun base ->
    write_rich_fixture base;
    let digest = D.build ~base_path:base ~keeper_name:keeper ~since_unix ~now_unix in
    (* round-trip through a string to prove it serialises, then assert the
       required top-level keys are present. *)
    let round_tripped = Yojson.Safe.from_string (Yojson.Safe.to_string (D.to_json digest)) in
    match round_tripped with
    | `Assoc fields ->
      List.iter
        (fun key ->
          Alcotest.(check bool)
            (Printf.sprintf "top-level key %s present" key)
            true
            (List.mem_assoc key fields))
        [ "keeper"
        ; "since_unix"
        ; "generated_at_unix"
        ; "chat"
        ; "turns"
        ; "tasks"
        ; "board"
        ; "lifecycle"
        ; "coverage"
        ; "read_errors"
        ]
      ;
      (match List.assoc_opt "coverage" fields with
       | Some (`Assoc coverage_fields) ->
         (match List.assoc_opt "chat" coverage_fields with
          | Some (`Assoc chat_fields) ->
            Alcotest.(check bool)
              "coverage.chat causes present"
              true
              (List.mem_assoc "causes" chat_fields)
          | _ -> Alcotest.fail "coverage.chat must be an object")
       | _ -> Alcotest.fail "coverage must be an object")
      ;
      (match List.assoc_opt "tasks" fields with
       | Some (`Assoc task_fields) ->
         let item_for_task_1 =
           json_list_field "items" task_fields
           |> List.find_opt (fun item ->
             String.equal
               (Option.value
                  (json_string_field "task_id" (json_assoc_fields item))
                  ~default:"")
               "task-1")
         in
         (match item_for_task_1 with
          | Some item ->
            (match List.assoc_opt "current_task" (json_assoc_fields item) with
             | Some (`Assoc current_fields) ->
               Alcotest.(check (option string))
                 "current_task.status serialised"
                 (Some "awaiting_verification")
                 (json_string_field "status" current_fields);
               Alcotest.(check (option string))
                 "current_task.handoff_next_step serialised"
                 (Some "cross-agent review")
                 (json_string_field "handoff_next_step" current_fields);
               Alcotest.(check int)
                 "current_task.handoff_evidence_refs serialised"
                 2
                 (List.length (json_list_field "handoff_evidence_refs" current_fields))
             | Some `Null -> Alcotest.fail "task-1 current_task must not be null"
             | _ -> Alcotest.fail "task-1 current_task must be an object")
          | None -> Alcotest.fail "expected task-1 JSON item")
       | _ -> Alcotest.fail "tasks must be an object")
    | _ -> Alcotest.fail "to_json must be a JSON object")
;;

let () =
  Alcotest.run
    "keeper_catchup_digest"
    [ ( "build"
      , [ Alcotest.test_case "counts + since boundary + identity + read_errors" `Quick test_counts_and_boundary
        ; Alcotest.test_case "missing stores are zero, not errors" `Quick test_missing_stores_are_zero
        ; Alcotest.test_case "items cap with full counts" `Quick test_items_cap
        ; Alcotest.test_case "chat page cap is fail-visible" `Quick test_chat_page_cap_is_fail_visible
        ; Alcotest.test_case "scan window clamp is coverage-visible" `Quick test_scan_window_clamp_is_coverage_visible
        ; Alcotest.test_case "task items are sound-partial" `Quick test_task_items_are_sound_partial
        ; Alcotest.test_case "to_json shape round-trips" `Quick test_to_json_shape
        ] )
    ]
;;
