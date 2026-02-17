(** Mitosis Tool Handlers

    Extracted from mcp_server_eio.ml for testability.
    8 tools: mitosis_status, mitosis_all, mitosis_pool, mitosis_divide,
             mitosis_check, mitosis_record, mitosis_prepare, mitosis_handoff

    Key tool: masc_mitosis_handoff - 2-phase proactive context management
    - 50% threshold: DNA preparation (context summary extracted)
    - 80% threshold: Handoff execution (spawn successor agent)

    Agent Being Protocol Integration:
    - Episode storage on successful handoff (file-based queue)
    - Episodes are flushed to Neo4j/PostgreSQL via masc_episode_flush
*)

(** Tool handler context - extensible for future features *)
type any_clock = Clock : _ Eio.Time.clock -> any_clock

type context = {
  config: Room.config;
  logger: (string -> unit) option;  (** Optional logging callback *)
  sw: Eio.Switch.t option;
  proc_mgr: Eio_unix.Process.mgr_ty Eio.Resource.t option;
  clock: any_clock option;
}

(** Create context with just config (backward compatible) *)
let make_context config : context = { config; logger = None; sw = None; proc_mgr = None; clock = None }

(** Create context with config and logger *)
let make_context_with_logger config logger : context =
  { config; logger = Some logger; sw = None; proc_mgr = None; clock = None }

(** Create context with sw and proc_mgr for non-blocking spawn *)
let make_context_with_eio
    ~config
    ~sw
    ~proc_mgr
    ~(clock : _ Eio.Time.clock) : context =
  { config; logger = None; sw = Some sw; proc_mgr; clock = Some (Clock clock) }

(** Internal logging helper *)
let log ctx msg =
  match ctx.logger with
  | Some f -> f msg
  | None -> ()

(** Last successful handoff timestamp for cooldown enforcement *)
let last_handoff_time : float ref = ref 0.0

(** Reset handoff cooldown timer (for testing) *)
let reset_handoff_cooldown () =
  last_handoff_time := 0.0

(** Convert Spawn_eio result to Spawn result for Mitosis compatibility *)
let spawn_eio_to_spawn (r : Spawn_eio.spawn_result) : Spawn.spawn_result =
  { Spawn.success = r.Spawn_eio.success;
    output = r.Spawn_eio.output;
    exit_code = r.Spawn_eio.exit_code;
    elapsed_ms = r.Spawn_eio.elapsed_ms;
    input_tokens = r.Spawn_eio.input_tokens;
    output_tokens = r.Spawn_eio.output_tokens;
    cache_creation_tokens = r.Spawn_eio.cache_creation_tokens;
    cache_read_tokens = r.Spawn_eio.cache_read_tokens;
    cost_usd = r.Spawn_eio.cost_usd }

(** Create non-blocking spawn_fn when Eio context is available *)
let make_spawn_fn ~ctx ~agent_name ~timeout_seconds : (prompt:string -> Spawn.spawn_result) =
  match ctx.sw, ctx.proc_mgr with
  | Some sw, Some pm ->
      (fun ~prompt ->
        let result = Spawn_eio.spawn ~sw ~proc_mgr:pm ~agent_name ~prompt ~timeout_seconds () in
        spawn_eio_to_spawn result)
  | _ ->
      (* Fallback to blocking spawn when Eio context unavailable *)
      (fun ~prompt ->
        Spawn.spawn ~agent_name ~prompt ~timeout_seconds ())

(** Tool result type *)
type result = bool * string

(** {1 Episode Queue - Agent Being Protocol}

    File-based queue for Episode persistence.
    Episodes are queued here (sync) and flushed to DB later (async via Eio).
    This decouples mitosis execution from DB availability.
*)

let pending_episodes_dir base_path =
  Filename.concat base_path ".masc/pending_episodes"

let generate_episode_id () =
  let ts = Time_compat.now () in
  let rand = Random.int 100000 in
  Printf.sprintf "ep-%d-%05d" (int_of_float (ts *. 1000.0)) rand

let now_iso () =
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

(** Queue an Episode for later DB persistence *)
let queue_episode ~base_path ~session_id ~agent_name ~generation
    ?parent_episode ~event_type ~summary ?dna () =
  let dir = pending_episodes_dir base_path in
  (* Create directory if not exists *)
  let () = try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> () in
  let ep_id = generate_episode_id () in
  let json = `Assoc [
    ("ep_id", `String ep_id);
    ("session_id", `String session_id);
    ("agent_name", `String agent_name);
    ("generation", `Int generation);
    ("parent_episode", match parent_episode with Some p -> `String p | None -> `Null);
    ("event_type", `String event_type);
    ("summary", `String summary);
    ("dna", match dna with Some d -> `String d | None -> `Null);
    ("timestamp", `String (now_iso ()));
  ] in
  let file = Filename.concat dir (ep_id ^ ".json") in
  try
    let oc = open_out file in
    Common.protect ~module_name:"tool_mitosis" ~finally_label:"finalizer" ~finally:(fun () -> close_out_noerr oc) (fun () ->
      output_string oc (Yojson.Safe.pretty_to_string json));
    Printf.printf "[EPISODE/QUEUE] Queued episode %s (gen %d) → %s\n%!" ep_id generation file;
    Some ep_id
  with exn ->
    Printf.eprintf "[EPISODE/ERROR] Failed to queue episode: %s\n%!" (Printexc.to_string exn);
    None

(** Saga status tracking for async handoff *)
let mitosis_saga_dir base_path =
  Filename.concat base_path ".masc/mitosis_sagas"

let generate_saga_id () =
  let ts = Time_compat.now () in
  let rand = Random.int 100000 in
  Printf.sprintf "saga-%d-%05d" (int_of_float (ts *. 1000.0)) rand

let ensure_dir dir =
  try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()

let write_saga_state ~base_path ~saga_id ~status ~payload : string option =
  let dir = mitosis_saga_dir base_path in
  ensure_dir dir;
  let file = Filename.concat dir (saga_id ^ ".json") in
  let json = `Assoc [
    ("saga_id", `String saga_id);
    ("status", `String status);
    ("updated_at", `String (now_iso ()));
    ("payload", payload);
  ] in
  try
    let oc = open_out file in
    Common.protect ~module_name:"tool_mitosis" ~finally_label:"finalizer"
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc (Yojson.Safe.pretty_to_string json));
    Some file
  with exn ->
    Printf.eprintf "[MITOSIS/SAGA] Failed writing %s: %s\n%!" file (Printexc.to_string exn);
    None

(** Get current session ID from environment or generate *)
let get_session_id () =
  match Sys.getenv_opt "TERM_SESSION_ID" with
  | Some sid when sid <> "" -> sid
  | _ ->
    match Sys.getenv_opt "MCP_SESSION_ID" with
    | Some sid when sid <> "" -> sid
    | _ -> Printf.sprintf "session-%d" (int_of_float (Time_compat.now () *. 1000.0) mod 1000000)

(** {1 Argument Helpers} *)

let get_string args key default =
  match args with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`String s) -> s
       | Some _ -> Printf.eprintf "[MITOSIS/WARN] %s: type mismatch\n%!" key; default
       | None -> default)
  | _ -> default

let get_float args key default =
  match args with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Float f) -> f
       | Some (`Int i) -> Float.of_int i
       | Some _ -> Printf.eprintf "[MITOSIS/WARN] %s: type mismatch\n%!" key; default
       | None -> default)
  | _ -> default

let get_bool args key default =
  match args with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`Bool b) -> b
       | Some _ -> Printf.eprintf "[MITOSIS/WARN] %s: type mismatch\n%!" key; default
       | None -> default)
  | _ -> default

(** Clamp context_ratio to valid range with warning - BALTHASAR feedback *)
let validate_context_ratio ratio =
  if ratio < 0.0 then begin
    Printf.eprintf "[MITOSIS/WARN] context_ratio < 0 (%.2f), clamping to 0.0\n%!" ratio;
    0.0
  end else if ratio > 1.0 then begin
    Printf.eprintf "[MITOSIS/WARN] context_ratio > 1 (%.2f), clamping to 1.0\n%!" ratio;
    1.0
  end else
    ratio

let set_bool_arg args key value =
  match args with
  | `Assoc fields ->
      let fields' = List.filter (fun (k, _) -> k <> key) fields in
      `Assoc ((key, `Bool value) :: fields')
  | _ ->
      `Assoc [ (key, `Bool value) ]

let get_string_list args key default =
  match args with
  | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`List xs) ->
           let vals =
             List.filter_map (function
               | `String s ->
                   let v = String.trim s in
                   if v = "" then None else Some v
               | _ -> None
             ) xs
           in
           if vals = [] then default else vals
       | Some _ ->
           Printf.eprintf "[MITOSIS/WARN] %s: type mismatch\n%!" key;
           default
       | None -> default)
  | _ -> default

let default_verifier_models = [
  "ollama:glm-4.7-flash";
  "ollama:glm-4.7-flash";
  "ollama:glm-4.7-flash";
]

let default_verifier_perspectives = [
  "A: continuity archivist (value-neutral)";
  "B: progress assessor (value-neutral)";
  "C: risk observer (value-neutral)";
]

let verifier_profile_name s =
  String.lowercase_ascii (String.trim s)

let perspectives_for_profile profile =
  match verifier_profile_name profile with
  | "abc_neutral" -> [
      "A: continuity archivist (value-neutral)";
      "B: progress assessor (value-neutral)";
      "C: risk observer (value-neutral)";
    ]
  | "abc_strict" -> [
      "A: continuity archivist (strict on memory continuity)";
      "B: progress assessor (strict on goal movement)";
      "C: risk observer (strict on regression risk)";
    ]
  | "abc_lenient" -> [
      "A: continuity archivist (lenient)";
      "B: progress assessor (lenient)";
      "C: risk observer (lenient)";
    ]
  | _ -> default_verifier_perspectives

let resolve_verifier_perspectives args =
  let explicit = get_string_list args "verifier_perspectives" [] in
  if explicit <> [] then
    ("custom", explicit)
  else
    let profile = get_string args "verifier_profile" "abc_neutral" in
    let normalized = verifier_profile_name profile in
    (normalized, perspectives_for_profile normalized)

let perspective_at perspectives idx =
  match List.nth_opt perspectives idx with
  | Some p when String.trim p <> "" -> p
  | _ ->
      (match default_verifier_perspectives with
       | p :: _ -> p
       | [] -> "continuity")

let assoc_get fields key =
  match List.assoc_opt key fields with
  | Some v -> v
  | None -> `Null

let json_value_present = function
  | `Null -> false
  | `String s -> String.trim s <> ""
  | `List xs -> xs <> []
  | `Assoc xs -> xs <> []
  | _ -> true

let evidence_action fields =
  match List.assoc_opt "action" fields with
  | Some (`String s) -> String.lowercase_ascii (String.trim s)
  | _ -> "unknown"

let expected_evidence_keys = function
  | "none" -> [
      "action";
      "context_ratio";
      "message";
      "threshold_prepare";
      "threshold_handoff";
    ]
  | "prepared" -> [
      "action";
      "context_ratio";
      "message";
      "phase";
      "dna_length";
      "dna_quality";
      "continuity_regression";
      "threshold_handoff";
    ]
  | "handoff" -> [
      "action";
      "success";
      "context_ratio";
      "message";
      "target_agent";
      "selected_agent";
      "previous_generation";
      "new_generation";
      "elapsed_ms";
      "continuity_regression";
      "spawn";
    ]
  | "fallback" -> [
      "action";
      "success";
      "context_ratio";
      "message";
      "target_agent";
      "selected_agent";
      "continuity_regression";
      "spawn";
    ]
  | _ -> [
      "action";
      "raw_result";
    ]

let extract_handoff_evidence (parsed_result : Yojson.Safe.t) : Yojson.Safe.t =
  match parsed_result with
  | `Assoc fields ->
      let spawn_evidence =
        match assoc_get fields "spawn_attempts" with
        | `List attempts ->
            let total = List.length attempts in
            let (successes, failures, failed_agents) =
              List.fold_left (fun (s, f, agents) j ->
                match j with
                | `Assoc af ->
                    let ok =
                      match List.assoc_opt "success" af with
                      | Some (`Bool b) -> b
                      | _ -> false
                    in
                    let agent =
                      match List.assoc_opt "agent" af with
                      | Some (`String a) -> a
                      | _ -> "unknown"
                    in
                    if ok then (s + 1, f, agents) else (s, f + 1, agent :: agents)
                | _ -> (s, f, agents)
              ) (0, 0, []) attempts
            in
            `Assoc [
              ("total", `Int total);
              ("successes", `Int successes);
              ("failures", `Int failures);
              ("failed_agents", `List (List.rev_map (fun a -> `String a) failed_agents));
            ]
        | _ -> `Null
      in
      `Assoc [
        ("action", assoc_get fields "action");
        ("success", assoc_get fields "success");
        ("context_ratio", assoc_get fields "context_ratio");
        ("message", assoc_get fields "message");
        ("threshold_prepare", assoc_get fields "threshold_prepare");
        ("threshold_handoff", assoc_get fields "threshold_handoff");
        ("phase", assoc_get fields "phase");
        ("dna_length", assoc_get fields "dna_length");
        ("dna_quality", assoc_get fields "dna_quality");
        ("continuity_regression", assoc_get fields "continuity_regression");
        ("target_agent", assoc_get fields "target_agent");
        ("selected_agent", assoc_get fields "selected_agent");
        ("previous_generation", assoc_get fields "previous_generation");
        ("new_generation", assoc_get fields "new_generation");
        ("elapsed_ms", assoc_get fields "elapsed_ms");
        ("spawn", spawn_evidence);
      ]
  | other ->
      `Assoc [ ("raw_result", other) ]

let evidence_completeness_ratio (evidence : Yojson.Safe.t) : float =
  match evidence with
  | `Assoc fields ->
      let expected = expected_evidence_keys (evidence_action fields) in
      let total = List.length expected in
      if total = 0 then 0.0
      else
        let present =
          List.fold_left (fun acc key ->
            match List.assoc_opt key fields with
            | Some v when json_value_present v -> acc + 1
            | _ -> acc
          ) 0 expected
        in
        Float.of_int present /. Float.of_int total
  | _ -> 0.0

let continuity_retention_from_evidence (evidence : Yojson.Safe.t) : float option =
  match evidence with
  | `Assoc fields ->
      (match List.assoc_opt "continuity_regression" fields with
       | Some (`Assoc cfields) ->
           (match List.assoc_opt "retention_score" cfields with
            | Some (`Float f) -> Some f
            | Some (`Int i) -> Some (Float.of_int i)
            | _ -> None)
       | _ -> None)
  | _ -> None

let max3 a b c = max a (max b c)

let run_handoff_verifier ~ctx ~args ~(parsed_result : Yojson.Safe.t) : (Yojson.Safe.t option * bool) =
  let verify_enabled = get_bool args "verify" true in
  if not verify_enabled then
    (None, true)
  else
    let model_strs = get_string_list args "verifier_models" default_verifier_models in
    let (perspective_profile, perspectives) = resolve_verifier_perspectives args in
    let goal =
      get_string args "verifier_goal"
        "Judge whether handoff outcome preserved continuity and moved work forward."
    in
    let policy =
      String.lowercase_ascii (String.trim (get_string args "verification_policy" "advisory"))
    in
    let judge_timeout_sec = max 0.0 (get_float args "verification_judge_timeout_sec" 60.0) in
    let recheck_count = max 0 (int_of_float (get_float args "verification_recheck_count" 0.0)) in
    let continuity_retention_min =
      max 0.0 (min 1.0 (get_float args "continuity_retention_min" 0.34))
    in
    let pass_ratio_threshold = get_float args "verification_pass_ratio" (2.0 /. 3.0) in
    let min_agreement = get_float args "verification_min_agreement" (2.0 /. 3.0) in
    let min_judges = max 1 (int_of_float (get_float args "verification_min_judges" 3.0)) in
    let full_context = get_string args "full_context" "" in
    let context_summary =
      if full_context = "" then
        "No full_context provided"
      else
        Mitosis.safe_sub full_context 0 600
    in
    let evidence = extract_handoff_evidence parsed_result in
    let evidence_text = Yojson.Safe.pretty_to_string evidence in
    let pass_count = ref 0 in
    let warn_count = ref 0 in
    let fail_count = ref 0 in
    let recheck_stability_samples = ref [] in
    let mean_or_none xs =
      match xs with
      | [] -> None
      | _ ->
          let total = List.fold_left ( +. ) 0.0 xs in
          Some (total /. Float.of_int (List.length xs))
    in
    let majority_ratio statuses =
      match statuses with
      | [] -> 1.0
      | _ ->
          let pass_n =
            List.fold_left (fun acc s -> if s = "pass" then acc + 1 else acc) 0 statuses
          in
          let warn_n =
            List.fold_left (fun acc s -> if s = "warn" then acc + 1 else acc) 0 statuses
          in
          let fail_n =
            List.fold_left (fun acc s -> if s = "fail" then acc + 1 else acc) 0 statuses
          in
          Float.of_int (max3 pass_n warn_n fail_n) /. Float.of_int (List.length statuses)
    in
    let checks =
      List.mapi (fun idx model_str ->
        let perspective = perspective_at perspectives idx in
        match Llm_client.model_spec_of_string model_str with
        | Error err ->
            incr warn_count;
            `Assoc [
              ("model", `String model_str);
              ("perspective", `String perspective);
              ("verdict", `String "WARN: model_parse_error");
              ("status", `String "warn");
              ("reason", `String err);
              ("recheck_count_requested", `Int recheck_count);
              ("recheck_count_completed", `Int 0);
              ("recheck_status_samples", `List [`String "warn"]);
              ("recheck_stability", `Float 1.0);
            ]
        | Ok model ->
            let req = Verifier.{
              action_description =
                Printf.sprintf "masc_mitosis_handoff outcome review (%s)" perspective;
              action_result = evidence_text;
              goal = Printf.sprintf "%s Perspective: %s." goal perspective;
              context_summary;
            } in
            let run_single_verdict () =
              try
                let verdict =
                  match ctx.clock with
                  | Some (Clock clock) when judge_timeout_sec > 0.0 ->
                      Eio.Time.with_timeout_exn clock judge_timeout_sec (fun () ->
                        Verifier.verify ~model req)
                  | _ ->
                      Verifier.verify ~model req
                in
                `Verdict verdict
              with
              | Eio.Time.Timeout ->
                  `Timeout
              | exn ->
                  `Error (Printexc.to_string exn)
            in
            let status_of = function
              | `Verdict Verifier.Pass -> "pass"
              | `Verdict (Verifier.Warn _) -> "warn"
              | `Verdict (Verifier.Fail _) -> "fail"
              | `Timeout -> "warn"
              | `Error _ -> "warn"
            in
            let verdict_text_of = function
              | `Verdict v -> Verifier.verdict_to_string v
              | `Timeout -> "WARN: verifier_timeout"
              | `Error _ -> "WARN: verifier_error"
            in
            let reason_of = function
              | `Timeout ->
                  Some (Printf.sprintf "judge timeout after %.1fs" judge_timeout_sec)
              | `Error err ->
                  Some err
              | _ ->
                  None
            in
            let primary = run_single_verdict () in
            let primary_status = status_of primary in
            (match primary_status with
             | "pass" -> incr pass_count
             | "fail" -> incr fail_count
             | _ -> incr warn_count);
            let rec collect_rechecks n acc =
              if n <= 0 then List.rev acc
              else
                let s = status_of (run_single_verdict ()) in
                collect_rechecks (n - 1) (s :: acc)
            in
            let recheck_statuses = collect_rechecks recheck_count [] in
            let status_samples = primary_status :: recheck_statuses in
            let stability = majority_ratio status_samples in
            if recheck_count > 0 then
              recheck_stability_samples := stability :: !recheck_stability_samples;
            let fields = ref [
              ("model", `String model_str);
              ("perspective", `String perspective);
              ("verdict", `String (verdict_text_of primary));
              ("status", `String primary_status);
            ] in
            (match reason_of primary with
             | Some reason -> fields := !fields @ [("reason", `String reason)]
             | None -> ());
            fields := !fields @ [
              ("recheck_count_requested", `Int recheck_count);
              ("recheck_count_completed", `Int (List.length recheck_statuses));
              ("recheck_status_samples", `List (List.map (fun s -> `String s) status_samples));
              ("recheck_stability", `Float stability);
            ];
            `Assoc !fields
      ) model_strs
    in
    let total = List.length checks in
    let effective_min_judges =
      if total <= 0 then min_judges else min min_judges total
    in
    let pass_ratio =
      if total = 0 then 0.0 else Float.of_int !pass_count /. Float.of_int total
    in
    let agreement_ratio =
      if total = 0 then 0.0
      else
        Float.of_int (max3 !pass_count !warn_count !fail_count)
        /. Float.of_int total
    in
    let evidence_ratio = evidence_completeness_ratio evidence in
    let continuity_retention = continuity_retention_from_evidence evidence in
    let continuity_ok =
      match continuity_retention with
      | Some score -> score >= continuity_retention_min
      | None -> true
    in
    let panel_disagreement = max 0.0 (1.0 -. agreement_ratio) in
    let consensus_pass =
      total >= effective_min_judges
      && !fail_count = 0
      && pass_ratio >= pass_ratio_threshold
      && agreement_ratio >= min_agreement
      && continuity_ok
    in
    let overall =
      if consensus_pass then "pass"
      else if !fail_count > 0 then "fail"
      else "warn"
    in
    let gate_pass =
      match policy with
      | "gate" | "hard_gate" -> consensus_pass
      | _ -> true
    in
    let recheck_stability = mean_or_none !recheck_stability_samples in
    let promotion_evidence_min = 0.8 in
    let promotion_max_disagreement = 0.34 in
    let promote_memory =
      consensus_pass
      && pass_ratio >= pass_ratio_threshold
      && evidence_ratio >= promotion_evidence_min
      && panel_disagreement <= promotion_max_disagreement
      && continuity_ok
    in
    let next_turn_plan =
      if !fail_count > 0 then
        `Assoc [
          ("action", `String "investigate_failures");
          ("priority", `String "high");
          ("reason", `String "At least one judge returned FAIL.");
          ("steps", `List [
            `String "Inspect failing judge reason";
            `String "Add missing evidence to full_context";
            `String "Re-run verifier panel";
          ]);
        ]
      else if not continuity_ok then
        `Assoc [
          ("action", `String "repair_continuity_memory");
          ("priority", `String "high");
          ("reason", `String "Continuity retention score below threshold.");
          ("steps", `List [
            `String "Re-inject goal/current task summary";
            `String "Run compaction with continuity guardrails";
            `String "Re-run verifier after continuity improves";
          ]);
        ]
      else if panel_disagreement > promotion_max_disagreement then
        `Assoc [
          ("action", `String "resolve_panel_disagreement");
          ("priority", `String "medium");
          ("reason", `String "Judge disagreement exceeded threshold.");
          ("steps", `List [
            `String "Collect additional continuity/progress evidence";
            `String "Run one extra verifier pass";
            `String "Proceed only after agreement improves";
          ]);
        ]
      else if pass_ratio < pass_ratio_threshold then
        `Assoc [
          ("action", `String "strengthen_context_before_retry");
          ("priority", `String "medium");
          ("reason", `String "Pass ratio below consensus threshold.");
          ("steps", `List [
            `String "Include concrete work delta and outcomes";
            `String "Retain goal/current task explicitly";
            `String "Retry handoff verification";
          ]);
        ]
      else
        `Assoc [
          ("action", `String "continue_execution");
          ("priority", `String "normal");
          ("reason", `String "Verifier consensus is acceptable.");
          ("steps", `List [
            `String "Promote durable memory if criteria met";
            `String "Proceed to next planned task";
          ]);
        ]
    in
    (Some (`Assoc [
      ("enabled", `Bool true);
      ("policy", `String policy);
      ("profile", `String perspective_profile);
      ("overall", `String overall);
      ("goal", `String goal);
      ("judge_timeout_sec", `Float judge_timeout_sec);
      ("recheck_count", `Int recheck_count);
      ("min_judges", `Int min_judges);
      ("effective_min_judges", `Int effective_min_judges);
      ("pass_ratio", `Float pass_ratio);
      ("pass_ratio_threshold", `Float pass_ratio_threshold);
      ("agreement_ratio", `Float agreement_ratio);
      ("agreement_threshold", `Float min_agreement);
      ("continuity_retention_min", `Float continuity_retention_min);
      ("consensus_pass", `Bool consensus_pass);
      ("counts", `Assoc [
        ("pass", `Int !pass_count);
        ("warn", `Int !warn_count);
        ("fail", `Int !fail_count);
        ("total", `Int total);
      ]);
      ("evidence", evidence);
      ("panel_disagreement", `Float panel_disagreement);
      ("research_metrics", `Assoc [
        ("inter_judge_agreement", `Float agreement_ratio);
        ("panel_disagreement", `Float panel_disagreement);
        ("evidence_completeness", `Float evidence_ratio);
        ("continuity_retention", match continuity_retention with Some x -> `Float x | None -> `Null);
        ("consensus_margin", `Float (pass_ratio -. pass_ratio_threshold));
        ("judge_recheck_stability", match recheck_stability with Some x -> `Float x | None -> `Null);
      ]);
      ("memory_promotion", `Assoc [
        ("from", `String "episodic");
        ("to", `String "semantic");
        ("decision", `String (if promote_memory then "promote" else "hold"));
        ("criteria", `Assoc [
          ("consensus_required", `Bool true);
          ("pass_ratio_threshold", `Float pass_ratio_threshold);
          ("evidence_min", `Float promotion_evidence_min);
          ("max_disagreement", `Float promotion_max_disagreement);
          ("continuity_retention_min", `Float continuity_retention_min);
        ]);
        ("signals", `Assoc [
          ("consensus_pass", `Bool consensus_pass);
          ("pass_ratio", `Float pass_ratio);
          ("evidence_completeness", `Float evidence_ratio);
          ("panel_disagreement", `Float panel_disagreement);
          ("continuity_retention", match continuity_retention with Some x -> `Float x | None -> `Null);
        ]);
      ]);
      ("next_turn_plan", next_turn_plan);
      ("checks", `List checks);
    ]), gate_pass)

(** Normalize agent names for fallback selection *)
let normalize_agent_name agent =
  String.lowercase_ascii (String.trim agent)

let dedup_preserve_order xs =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | x :: rest ->
        if x = "" || List.mem x seen then
          loop seen acc rest
        else
          loop (x :: seen) (x :: acc) rest
  in
  loop [] [] xs

let cascade_agents preferred =
  dedup_preserve_order [
    normalize_agent_name preferred;
    "claude";
    "codex";
    "gemini";
    "ollama";
  ]

let spawn_attempts_to_json attempts =
  `List (List.map (fun (agent, result) ->
    `Assoc [
      ("agent", `String agent);
      ("success", `Bool result.Spawn.success);
      ("exit_code", `Int result.Spawn.exit_code);
      ("elapsed_ms", `Int result.Spawn.elapsed_ms);
      ("output", `String (Mitosis.safe_sub result.Spawn.output 0 300));
    ]) attempts)

let now_s () = Time_compat.now ()

let min_attempt_timeout_s = 5
let max_tool_window_s = 120

let failed_spawn_result ~msg ~exit_code : Spawn.spawn_result =
  {
    Spawn.success = false;
    output = msg;
    exit_code;
    elapsed_ms = 0;
    input_tokens = None;
    output_tokens = None;
    cache_creation_tokens = None;
    cache_read_tokens = None;
    cost_usd = None;
  }

let normalized_spawn_reason (result : Spawn.spawn_result) : string =
  let raw = String.trim result.Spawn.output in
  let base =
    if raw = "" then
      "spawn failed"
    else
      Mitosis.safe_sub raw 0 240
  in
  if result.Spawn.exit_code = 124 then
    "spawn timeout: " ^ base
  else
    base

let should_penalize_failure (result : Spawn.spawn_result) : bool =
  (* Long-running CLI agents may timeout while still producing useful output.
     Treat those as soft failures to avoid breaker-open storms in succession loops. *)
  if result.Spawn.success then
    false
  else if result.Spawn.exit_code = 124 && String.trim result.Spawn.output <> "" then
    false
  else
    true

let command_available cmd =
  Sys.command (Printf.sprintf "command -v %s >/dev/null 2>&1" cmd) = 0

let port_listening port =
  Sys.command (Printf.sprintf "lsof -iTCP:%d -sTCP:LISTEN -t >/dev/null 2>&1" port) = 0

let readiness_check agent =
  match agent with
  | "claude" ->
      if command_available "claude" then Ok () else Error "claude CLI not found"
  | "codex" ->
      if command_available "codex" then Ok () else Error "codex CLI not found"
  | "gemini" ->
      if command_available "gemini" then Ok () else Error "gemini CLI not found"
  | "ollama" ->
      if not (command_available "ollama") then Error "ollama CLI not found"
      else if not (port_listening 11434) then Error "ollama port 11434 not listening"
      else Ok ()
  | _ -> Ok ()

let breaker_agent_id agent = "spawn:" ^ agent

let spawn_with_cascade ~ctx ~preferred_agent ~total_timeout_seconds ~prompt =
  let agents = cascade_agents preferred_agent in
  let start_ts = now_s () in
  let total_budget = max 1 (min max_tool_window_s total_timeout_seconds) in
  let rec loop attempts remaining_agents = function
    | [] ->
        let fallback_result, selected =
          match attempts with
          | (agent, result) :: _ -> (result, agent)
          | [] ->
              ({ Spawn.success = false;
                 output = "No spawn candidates available";
                 exit_code = 1;
                 elapsed_ms = 0;
                 input_tokens = None;
                 output_tokens = None;
                 cache_creation_tokens = None;
                 cache_read_tokens = None;
                 cost_usd = None }, normalize_agent_name preferred_agent)
        in
        (fallback_result, selected, List.rev attempts)
    | agent :: rest ->
        let attempts_agent_left = max 1 remaining_agents in
        let elapsed = int_of_float (now_s () -. start_ts) in
        let remaining = total_budget - elapsed in
        if remaining <= 0 then
          let fallback_result, selected =
            match attempts with
            | (a, r) :: _ -> (r, a)
            | [] ->
                ({ Spawn.success = false;
                   output = "Cascade timeout budget exhausted";
                   exit_code = 124;
                   elapsed_ms = total_budget * 1000;
                   input_tokens = None;
                   output_tokens = None;
                   cache_creation_tokens = None;
                   cache_read_tokens = None;
                   cost_usd = None }, normalize_agent_name preferred_agent)
          in
          (fallback_result, selected, List.rev attempts)
        else begin
          match Circuit_breaker.check_global ~agent_id:(breaker_agent_id agent) with
          | Error reason ->
              let result = failed_spawn_result ~msg:reason ~exit_code:125 in
              let attempts' = (agent, result) :: attempts in
              loop attempts' (attempts_agent_left - 1) rest
          | Ok () ->
              begin match readiness_check agent with
              | Error reason ->
                  ignore (Circuit_breaker.record_failure_global
                    ~agent_id:(breaker_agent_id agent)
                    ~reason);
                  let result = failed_spawn_result ~msg:reason ~exit_code:125 in
                  let attempts' = (agent, result) :: attempts in
                  loop attempts' (attempts_agent_left - 1) rest
              | Ok () ->
                  let base_timeout =
                    max min_attempt_timeout_s (remaining / attempts_agent_left)
                  in
                  let per_attempt_timeout =
                    if attempts = [] && agent = normalize_agent_name preferred_agent then
                      (* Give preferred agent the full initial budget before cascading. *)
                      max min_attempt_timeout_s remaining
                    else
                      base_timeout
                  in
                  let spawn_fn =
                    make_spawn_fn ~ctx ~agent_name:agent ~timeout_seconds:per_attempt_timeout
                  in
                  let result = spawn_fn ~prompt in
                  if result.Spawn.success then
                    ignore (Circuit_breaker.record_success_global
                      ~agent_id:(breaker_agent_id agent))
                  else if should_penalize_failure result then
                    ignore (Circuit_breaker.record_failure_global
                      ~agent_id:(breaker_agent_id agent)
                      ~reason:(normalized_spawn_reason result));
                  let attempts' = (agent, result) :: attempts in
                  if result.Spawn.success then
                    (result, agent, List.rev attempts')
                  else
                    loop attempts' (attempts_agent_left - 1) rest
              end
        end
  in
  loop [] (List.length agents) agents

(** {1 Individual Handlers} *)

let handle_mitosis_status _ctx _args : result =
  let cell = !(Mcp_server.current_cell) in
  let pool = !(Mcp_server.stem_pool) in
  let json = `Assoc [
    ("cell", Mitosis.cell_to_json cell);
    ("pool", Mitosis.pool_to_json pool);
    ("config", Mitosis.config_to_json Mitosis.default_config);
  ] in
  (true, Yojson.Safe.pretty_to_string json)

let handle_mitosis_all ctx _args : result =
  let statuses = Mitosis.get_all_statuses ~room_config:ctx.config in
  let json =
    `List (List.map (fun (node_id, status, ratio) ->
      `Assoc [
        ("node_id", `String node_id);
        ("status", `String status);
        ("estimated_ratio", `Float ratio);
      ]) statuses)
  in
  (true, Yojson.Safe.pretty_to_string json)

let handle_mitosis_pool _ctx _args : result =
  let pool = !(Mcp_server.stem_pool) in
  (true, Yojson.Safe.pretty_to_string (Mitosis.pool_to_json pool))

let handle_mitosis_divide ctx args : result =
  let summary = get_string args "summary" "" in
  let current_task = get_string args "current_task" "" in
  let target_agent = get_string args "target_agent" "claude" in
  let spawn_timeout =
    int_of_float
      (get_float args "spawn_timeout"
         (Float.of_int Mitosis.Defaults.spawn_timeout_seconds))
  in
  let full_context =
    if current_task = "" then summary
    else Printf.sprintf "Summary: %s\n\nCurrent Task: %s" summary current_task
  in
  let cell = !(Mcp_server.current_cell) in
  let config_mitosis = Mitosis.default_config in
  let selected_agent = ref (normalize_agent_name target_agent) in
  let spawn_attempts = ref [] in
  let spawn_fn ~prompt =
    let (result, actual_agent, attempts) =
      spawn_with_cascade
        ~ctx
        ~preferred_agent:target_agent
        ~total_timeout_seconds:spawn_timeout
        ~prompt
    in
    selected_agent := actual_agent;
    spawn_attempts := attempts;
    result
  in
  let (spawn_result, new_cell, new_pool, handoff_dna) =
    Mitosis.execute_mitosis ~config:config_mitosis ~pool:!(Mcp_server.stem_pool)
      ~parent:cell ~full_context ~spawn_fn
  in
  let effective_agent =
    if !selected_agent = "" then normalize_agent_name target_agent else !selected_agent
  in
  let attempts_json = spawn_attempts_to_json !spawn_attempts in
  (* P0 fix: Only update state on successful spawn - no rollback needed on failure *)
  if spawn_result.Spawn.success then begin
    Mcp_server.current_cell := new_cell;
    Mcp_server.stem_pool := new_pool;
    Mitosis.write_status_with_backend ~room_config:ctx.config ~cell:new_cell ~config:config_mitosis;

    (* Agent Being Protocol: Queue Episode for persistence *)
    let base_path = ctx.config.Room_utils.base_path in
    let session_id = get_session_id () in
    let ep_id = queue_episode
      ~base_path
      ~session_id
      ~agent_name:effective_agent
      ~generation:new_cell.Mitosis.generation
      ~event_type:"mitosis_divide"
      ~summary:(Printf.sprintf "Manual mitosis divide: gen %d → gen %d"
        cell.Mitosis.generation new_cell.Mitosis.generation)
      ~dna:handoff_dna
      () in

    let output_preview = Mitosis.safe_sub spawn_result.Spawn.output 0 500 in
    let json = `Assoc [
      ("success", `Bool true);
      ("previous_generation", `Int cell.Mitosis.generation);
      ("new_generation", `Int new_cell.Mitosis.generation);
      ("target_agent", `String target_agent);
      ("selected_agent", `String effective_agent);
      ("spawn_attempts", attempts_json);
      ("successor_output", `String output_preview);
      ("episode_queued", match ep_id with Some id -> `String id | None -> `Null);
    ] in
    (true, Yojson.Safe.pretty_to_string json)
  end else begin
    (* Spawn failed - return error without updating state *)
    Printf.eprintf "[MITOSIS/ERROR] mitosis_divide spawn failed, state unchanged\n%!";
    let json = `Assoc [
      ("success", `Bool false);
      ("error", `String "Spawn failed");
      ("target_agent", `String target_agent);
      ("selected_agent", `String effective_agent);
      ("spawn_attempts", attempts_json);
      ("spawn_output", `String spawn_result.Spawn.output);
      ("suggestion", `String "Check agent availability and try again, or use masc_mitosis_handoff for graceful fallback");
    ] in
    (false, Yojson.Safe.pretty_to_string json)
  end

let handle_mitosis_check _ctx args : result =
  let raw_ratio = get_float args "context_ratio" 0.0 in
  let context_ratio = validate_context_ratio raw_ratio in
  
  (* P0-2: Warn if context_ratio is default 0.0 *)
  if raw_ratio = 0.0 then
    Printf.eprintf "[MITOSIS/WARN] context_ratio is 0.0 - did you forget to estimate it?\n%!";

  (* P0-1: Configurable thresholds *)
  let prepare_threshold = get_float args "prepare_threshold" 0.5 in
  let handoff_threshold = get_float args "handoff_threshold" 0.8 in

  let cell = !(Mcp_server.current_cell) in
  (* Override config with custom thresholds *)
  let config_mitosis = { Mitosis.default_config with
    prepare_threshold;
    handoff_threshold;
  } in
  
  let should_prepare = Mitosis.should_prepare ~config:config_mitosis ~cell ~context_ratio in
  let should_handoff = Mitosis.should_handoff ~config:config_mitosis ~cell ~context_ratio in
  let warning = if raw_ratio = 0.0 then
    [("warning", `String "context_ratio is 0.0 - did you forget to provide it?")]
  else [] in
  let json = `Assoc ([
    ("should_prepare", `Bool should_prepare);
    ("should_handoff", `Bool should_handoff);
    ("context_ratio", `Float context_ratio);
    ("threshold_prepare", `Float config_mitosis.Mitosis.prepare_threshold);
    ("threshold_handoff", `Float config_mitosis.Mitosis.handoff_threshold);
    ("phase", `String (Mitosis.phase_to_string cell.Mitosis.phase));
  ] @ warning) in
  (true, Yojson.Safe.pretty_to_string json)

let handle_mitosis_record ctx args : result =
  let task_done = get_bool args "task_done" false in
  let tool_called = get_bool args "tool_called" false in
  let cell = !(Mcp_server.current_cell) in
  let updated = Mitosis.record_activity ~cell ~task_done ~tool_called in
  Mcp_server.current_cell := updated;
  Mitosis.write_status_with_backend ~room_config:ctx.config ~cell:updated ~config:Mitosis.default_config;
  let json = `Assoc [
    ("task_count", `Int updated.Mitosis.task_count);
    ("tool_call_count", `Int updated.Mitosis.tool_call_count);
    ("last_activity", `Float updated.Mitosis.last_activity);
  ] in
  (true, Yojson.Safe.pretty_to_string json)

let handle_mitosis_prepare ctx args : result =
  let full_context = get_string args "full_context" "" in
  
  (* P0-3: Configurable DNA compression ratio *)
  let dna_compression_ratio = get_float args "dna_compression_ratio" 0.1 in
  let config_mitosis = { Mitosis.default_config with
    dna_compression_ratio;
  } in

  let cell = !(Mcp_server.current_cell) in
  let prepared = Mitosis.prepare_for_division ~config:config_mitosis ~cell ~full_context in
  Mcp_server.current_cell := prepared;
  Mitosis.write_status_with_backend ~room_config:ctx.config ~cell:prepared ~config:config_mitosis;
  (* P2-3: Record prepare metric *)
  Mitosis_metrics.inc_prepare ();
  let json = `Assoc [
    ("status", `String "prepared");
    ("phase", `String (Mitosis.phase_to_string prepared.Mitosis.phase));
    ("dna_length", `Int (String.length (Option.value ~default:"" prepared.Mitosis.prepared_dna)));
    ("compression_ratio", `Float config_mitosis.Mitosis.dna_compression_ratio);
  ] in
  (true, Yojson.Safe.pretty_to_string json)

let contains_substring_ci ~haystack ~needle =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  let lh = String.length h in
  let ln = String.length n in
  if ln = 0 then
    true
  else if ln > lh then
    false
  else
    let rec loop i =
      if i + ln > lh then false
      else if String.sub h i ln = n then true
      else loop (i + 1)
    in
    loop 0

(** DNA quality validation - BALTHASAR feedback (P1-7: enhanced semantic checks)
    Ensures extracted DNA contains meaningful, structured content.
    Checks: length, goal/task markers, whitespace ratio, structural markers. *)
let validate_dna dna =
  let min_length = 50 in
  let len = String.length dna in
  if len < min_length then
    Error (Printf.sprintf "DNA too short: %d chars (min: %d)" len min_length)
  else
    (* Check for goal/task markers (case-insensitive) *)
    let has_marker =
      List.exists (fun needle -> contains_substring_ci ~haystack:dna ~needle)
        ["goal"; "task"; "objective"; "context"]
    in
    if not has_marker then
      Error "DNA lacks goal/task markers (expected: goal, task, objective, or context)"
    else
      (* Check whitespace ratio < 0.5 *)
      let ws_count = String.fold_left (fun acc c ->
        if c = ' ' || c = '\t' || c = '\n' || c = '\r' then acc + 1 else acc
      ) 0 dna in
      let ws_ratio = Float.of_int ws_count /. Float.of_int len in
      if ws_ratio >= 0.5 then
        Error (Printf.sprintf "DNA is mostly whitespace: %.0f%% (max: 50%%)" (ws_ratio *. 100.0))
      else
        (* Check for structural markers: newline, bullet, colon, dash *)
        let has_structure =
          String.contains dna '\n' ||
          contains_substring_ci ~haystack:dna ~needle:"- " ||
          contains_substring_ci ~haystack:dna ~needle:": " ||
          contains_substring_ci ~haystack:dna ~needle:"* "
        in
        if not has_structure then
          Error "DNA lacks structure (expected: newlines, bullets, colons, or dashes)"
        else
          Ok dna

let normalize_for_overlap s =
  let b = Buffer.create (String.length s) in
  String.iter (fun c ->
    let lc = Char.lowercase_ascii c in
    if (lc >= 'a' && lc <= 'z') || (lc >= '0' && lc <= '9') then
      Buffer.add_char b lc
    else
      Buffer.add_char b ' '
  ) s;
  Buffer.contents b

let tokenize_overlap s =
  String.split_on_char ' ' (normalize_for_overlap s)
  |> List.filter (fun tok -> String.length tok >= 3)

let token_overlap_ratio ~source ~target =
  let source_tokens = tokenize_overlap source in
  match source_tokens with
  | [] -> 1.0
  | _ ->
      let matched =
        List.fold_left (fun acc tok ->
          if List.mem tok (tokenize_overlap target) then acc + 1 else acc
        ) 0 source_tokens
      in
      Float.of_int matched /. Float.of_int (List.length source_tokens)

let extract_prefixed_line ~prefix text =
  let p = String.lowercase_ascii prefix in
  let lp = String.length p in
  let rec loop = function
    | [] -> ""
    | line :: rest ->
        let trimmed = String.trim line in
        let lowered = String.lowercase_ascii trimmed in
        if String.length lowered >= lp && String.sub lowered 0 lp = p then
          String.trim (String.sub trimmed lp (String.length trimmed - lp))
        else
          loop rest
  in
  loop (String.split_on_char '\n' text)

let last_non_empty_line text =
  let rec loop last = function
    | [] -> last
    | line :: rest ->
        let trimmed = String.trim line in
        if trimmed = "" then loop last rest else loop trimmed rest
  in
  loop "" (String.split_on_char '\n' text)

let continuity_regression_check ~full_context ~compressed_context =
  let goal_hint = extract_prefixed_line ~prefix:"goal:" full_context in
  let task_hint = extract_prefixed_line ~prefix:"current task:" full_context in
  let recent_hint = last_non_empty_line full_context in
  let hints =
    List.filter (fun (_, v) -> String.trim v <> "") [
      ("goal", goal_hint);
      ("current_task", task_hint);
      ("recent_turn", recent_hint);
    ]
  in
  let details, passed =
    List.fold_left (fun (acc, pass_n) (name, hint) ->
      let overlap = token_overlap_ratio ~source:hint ~target:compressed_context in
      let retained =
        contains_substring_ci ~haystack:compressed_context ~needle:hint
        || overlap >= 0.6
      in
      let detail = `Assoc [
        ("name", `String name);
        ("hint", `String (Mitosis.safe_sub hint 0 120));
        ("overlap_ratio", `Float overlap);
        ("retained", `Bool retained);
      ] in
      (detail :: acc, if retained then pass_n + 1 else pass_n)
    ) ([], 0) hints
  in
  let total = List.length hints in
  let retention_score =
    if total = 0 then 1.0
    else Float.of_int passed /. Float.of_int total
  in
  `Assoc [
    ("assessed", `Bool (total > 0));
    ("checks_total", `Int total);
    ("checks_passed", `Int passed);
    ("retention_score", `Float retention_score);
    ("details", `List (List.rev details));
  ]

(** 2-Phase auto mitosis handoff - THE CORE TOOL (v2 with BALTHASAR feedback)

    IMPROVEMENTS from v1:
    - context_ratio validation with clamping
    - DNA quality check before handoff
    - Fallback to compaction if spawn fails
    - Better error messages
    
    Usage:
    - Call periodically with your estimated context_ratio
    - At 50%: DNA is prepared (returns "prepared")
    - At 80%: Handoff executes (spawns successor agent)
    - Below 50%: No action needed
    
    Arguments:
    - context_ratio: float (0.0-1.0) - estimated context usage
    - full_context: string - current context/summary to pass to successor
    - target_agent: string (optional) - "claude"|"gemini"|"codex"|"ollama" (default: "claude")
    - prepare_threshold: float (optional) - when to prepare DNA (default: 0.5)
    - handoff_threshold: float (optional) - when to handoff (default: 0.8)
    - spawn_timeout: int (optional) - spawn timeout in seconds (default: 600)
    
    On spawn failure: Returns "fallback" with compaction suggestion instead of silent failure
*)
let run_sync_handoff ctx args : result =
  (* P2-2: Experiment flag — log when experimental mitosis path is active *)
  if Env_config.Mitosis.experiment_enabled then
    Printf.eprintf "[MITOSIS/EXPERIMENT] Experimental mitosis path active\n%!";
  (* P1-3: Handoff cooldown — prevent rapid repeated handoffs *)
  let cooldown = Env_config.Mitosis.handoff_cooldown_seconds in
  let now = Time_compat.now () in
  let elapsed = now -. !last_handoff_time in
  if !last_handoff_time > 0.0 && elapsed < cooldown then begin
    let remaining = cooldown -. elapsed in
    (* P2-3: Expose cooldown remaining to Prometheus *)
    Mitosis_metrics.set_cooldown_remaining remaining;
    let json = `Assoc [
      ("action", `String "cooldown");
      ("message", `String (Printf.sprintf "Handoff cooldown active. %.0fs remaining (cooldown: %.0fs)" remaining cooldown));
      ("cooldown_remaining_sec", `Float remaining);
      ("cooldown_total_sec", `Float cooldown);
    ] in
    (false, Yojson.Safe.pretty_to_string json)
  end else

  let raw_ratio = get_float args "context_ratio" 0.0 in
  let context_ratio = validate_context_ratio raw_ratio in
  let full_context = get_string args "full_context" "" in
  let target_agent = get_string args "target_agent" "claude" in
  (* P0-1: Configurable thresholds instead of hardcoded 0.5/0.8 *)
  let prepare_threshold = get_float args "prepare_threshold" 0.5 in
  let handoff_threshold = get_float args "handoff_threshold" 0.8 in
  let spawn_timeout = int_of_float (get_float args "spawn_timeout" (Float.of_int Mitosis.Defaults.spawn_timeout_seconds)) in
  
  (* Warn if context_ratio is default 0.0 - likely caller forgot to provide it *)
  if raw_ratio = 0.0 then
    Printf.eprintf "[MITOSIS/WARN] context_ratio is 0.0 - did you forget to estimate it?\n%!";
  
  let cell = !(Mcp_server.current_cell) in
  (* Override config with custom thresholds if provided *)
  let config_mitosis = { Mitosis.default_config with
    prepare_threshold;
    handoff_threshold;
  } in
  let pool = !(Mcp_server.stem_pool) in

  let selected_agent = ref (normalize_agent_name target_agent) in
  let spawn_attempts = ref [] in
  let spawn_fn ~prompt =
    let (result, actual_agent, attempts) =
      spawn_with_cascade
        ~ctx
        ~preferred_agent:target_agent
        ~total_timeout_seconds:spawn_timeout
        ~prompt
    in
    selected_agent := actual_agent;
    spawn_attempts := attempts;
    result
  in
  
  let result = Mitosis.auto_mitosis_check_2phase
    ~config:config_mitosis
    ~pool
    ~cell
    ~context_ratio
    ~full_context
    ~spawn_fn
  in
  
  match result with
  | Mitosis.NoAction ->
      let no_action_message =
        match cell.Mitosis.phase with
        | Mitosis.ReadyForHandoff _ ->
            "Already prepared. Continue working until handoff threshold."
        | Mitosis.Idle ->
            "Context ratio below prepare threshold. Continue working."
      in
      let warning = if raw_ratio = 0.0 then
        [("warning", `String "context_ratio is 0.0 - did you forget to provide it?")]
      else [] in
      let json = `Assoc ([
        ("action", `String "none");
        ("context_ratio", `Float context_ratio);
        ("phase", `String (Mitosis.phase_to_string cell.Mitosis.phase));
        ("message", `String no_action_message);
        ("threshold_prepare", `Float config_mitosis.Mitosis.prepare_threshold);
        ("threshold_handoff", `Float config_mitosis.Mitosis.handoff_threshold);
      ] @ warning) in
      (true, Yojson.Safe.pretty_to_string json)
      
  | Mitosis.Prepared prepared_cell ->
      let dna = Option.value ~default:"" prepared_cell.Mitosis.prepared_dna in
      let continuity =
        continuity_regression_check ~full_context ~compressed_context:dna
      in
      (* Validate DNA quality *)
      let dna_status = match validate_dna dna with
        | Ok _ -> "valid"
        | Error msg -> Printf.sprintf "warning: %s" msg
      in
      Mcp_server.current_cell := prepared_cell;
      Mitosis.write_status_with_backend ~room_config:ctx.config ~cell:prepared_cell ~config:config_mitosis;
      let json = `Assoc [
        ("action", `String "prepared");
        ("context_ratio", `Float context_ratio);
        ("message", `String "DNA extracted and ready. Continue working until 80% threshold.");
        ("phase", `String (Mitosis.phase_to_string prepared_cell.Mitosis.phase));
        ("dna_length", `Int (String.length dna));
        ("dna_quality", `String dna_status);
        ("continuity_regression", continuity);
        ("threshold_handoff", `Float config_mitosis.Mitosis.handoff_threshold);
      ] in
      (true, Yojson.Safe.pretty_to_string json)
      
  | Mitosis.Handoff (spawn_result, new_cell, new_pool, handoff_dna) ->
      (* P0-5: Record handoff in generational metrics *)
      let dna_size = String.length handoff_dna in
      ignore (Generational_metrics.record_handoff
        ~from_generation:cell.Mitosis.generation
        ~to_generation:new_cell.Mitosis.generation
        ~dna_size
        ~context_ratio);
      let effective_agent =
        if !selected_agent = "" then normalize_agent_name target_agent else !selected_agent
      in
      let attempts_json = spawn_attempts_to_json !spawn_attempts in
      let continuity =
        continuity_regression_check ~full_context ~compressed_context:handoff_dna
      in
      
      (* Check spawn success - BALTHASAR feedback: handle failures gracefully *)
      if not spawn_result.Spawn.success then begin
        (* P2-3: Record spawn failure metric *)
        Mitosis_metrics.inc_error ~reason:"spawn_failed" ();
        (* Spawn failed! Suggest fallback to compaction instead of losing context *)
        Printf.eprintf "[MITOSIS/ERROR] Spawn failed for %s, suggesting fallback\n%!" target_agent;
        let base_path = ctx.config.Room_utils.base_path in
        let session_id = get_session_id () in
        let fallback_ep = queue_episode
          ~base_path
          ~session_id
          ~agent_name:effective_agent
          ~generation:new_cell.Mitosis.generation
          ~event_type:"mitosis_handoff_fallback"
          ~summary:(Printf.sprintf "Mitosis handoff fallback: gen %d → gen %d (target: %s, context: %.0f%%)"
            cell.Mitosis.generation new_cell.Mitosis.generation target_agent (context_ratio *. 100.0))
          ~dna:handoff_dna
          () in
        let json = `Assoc [
          ("action", `String "fallback");
          ("success", `Bool false);
          ("context_ratio", `Float context_ratio);
          ("message", `String "Spawn failed! Consider using compaction instead. Context preserved.");
          ("target_agent", `String target_agent);
          ("selected_agent", `String effective_agent);
          ("spawn_attempts", attempts_json);
          ("spawn_error", `String spawn_result.Spawn.output);
          ("continuity_regression", continuity);
          ("episode_queued", match fallback_ep with Some id -> `String id | None -> `Null);
          ("suggestion", `String "Use /compact or masc_mitosis_divide with summary for graceful degradation");
        ] in
        (true, Yojson.Safe.pretty_to_string json)
      end else begin
        Mcp_server.current_cell := new_cell;
        Mcp_server.stem_pool := new_pool;
        Mitosis.write_status_with_backend ~room_config:ctx.config ~cell:new_cell ~config:config_mitosis;
        (* P1-3: Update cooldown timer after successful handoff *)
        last_handoff_time := Time_compat.now ();
        (* P2-3: Record handoff success metrics *)
        Mitosis_metrics.inc_handoff ();
        Mitosis_metrics.set_generation new_cell.Mitosis.generation;
        Mitosis_metrics.set_cooldown_remaining 0.0;
        let duration_sec = (float_of_int spawn_result.Spawn.elapsed_ms) /. 1000.0 in
        Mitosis_metrics.observe_handoff_duration duration_sec;

        (* Agent Being Protocol: Queue Episode for persistence *)
        let base_path = ctx.config.Room_utils.base_path in
        let session_id = get_session_id () in
        let summary = Printf.sprintf "Mitosis handoff: gen %d → gen %d (target: %s, context: %.0f%%)"
          cell.Mitosis.generation new_cell.Mitosis.generation target_agent (context_ratio *. 100.0) in
        let ep_id = queue_episode
          ~base_path
          ~session_id
          ~agent_name:effective_agent
          ~generation:new_cell.Mitosis.generation
          ~event_type:"mitosis_handoff"
          ~summary
          ~dna:handoff_dna
          () in

        let output_preview = Mitosis.safe_sub spawn_result.Spawn.output 0 500 in
        let json = `Assoc [
          ("action", `String "handoff");
          ("success", `Bool true);
          ("context_ratio", `Float context_ratio);
          ("message", `String "Handoff complete! Successor agent spawned.");
          ("target_agent", `String target_agent);
          ("selected_agent", `String effective_agent);
          ("spawn_attempts", attempts_json);
          ("previous_generation", `Int cell.Mitosis.generation);
          ("new_generation", `Int new_cell.Mitosis.generation);
          ("successor_output", `String output_preview);
          ("elapsed_ms", `Int spawn_result.Spawn.elapsed_ms);
          ("continuity_regression", continuity);
          ("episode_queued", match ep_id with Some id -> `String id | None -> `Null);
        ] in
        (true, Yojson.Safe.pretty_to_string json)
      end

let handle_mitosis_handoff ctx args : result =
  let async_mode = get_bool args "async" true in
  match async_mode, ctx.sw with
  | true, Some sw ->
      let base_path = ctx.config.Room_utils.base_path in
      let saga_id = generate_saga_id () in
      let args_sync = set_bool_arg args "async" false in
      let saga_timeout_sec =
        max 1.0 (get_float args_sync "verification_saga_timeout_sec" 180.0)
      in
      let status_file = write_saga_state
        ~base_path
        ~saga_id
        ~status:"queued"
        ~payload:(`Assoc [
          ("mode", `String "async");
          ("tool", `String "masc_mitosis_handoff");
        ])
      in
      Eio.Fiber.fork ~sw (fun () ->
        ignore (write_saga_state
          ~base_path
          ~saga_id
          ~status:"running"
          ~payload:(`Assoc [("message", `String "handoff saga running")]));
        let started = Time_compat.now () in
        try
          let run_once () =
            let (ok, body) = run_sync_handoff ctx args_sync in
            let parsed =
              try Yojson.Safe.from_string body
              with _ -> `String body
            in
            let (verification, gate_pass) =
              run_handoff_verifier ~ctx ~args:args_sync ~parsed_result:parsed
            in
            let final_ok = ok && gate_pass in
            ignore (write_saga_state
              ~base_path
              ~saga_id
              ~status:(if final_ok then "completed" else "failed")
              ~payload:(`Assoc [
                ("ok", `Bool final_ok);
                ("operation_ok", `Bool ok);
                ("verification_gate_passed", `Bool gate_pass);
                ("elapsed_sec", `Float (Time_compat.now () -. started));
                ("result", parsed);
                ("verification", match verification with Some v -> v | None -> `Null);
              ]))
          in
          (match ctx.clock with
           | Some (Clock clock) ->
               (try
                  Eio.Time.with_timeout_exn clock saga_timeout_sec run_once
                with Eio.Time.Timeout ->
                  ignore (write_saga_state
                    ~base_path
                    ~saga_id
                    ~status:"failed"
                    ~payload:(`Assoc [
                      ("ok", `Bool false);
                      ("operation_ok", `Bool false);
                      ("verification_gate_passed", `Bool false);
                      ("elapsed_sec", `Float (Time_compat.now () -. started));
                      ("error", `String "verification_saga_timeout");
                      ("timeout_sec", `Float saga_timeout_sec);
                    ])))
           | None ->
               run_once ())
        with exn ->
          ignore (write_saga_state
            ~base_path
            ~saga_id
            ~status:"error"
            ~payload:(`Assoc [
              ("error", `String (Printexc.to_string exn));
            ])));
      let json = `Assoc [
        ("action", `String "accepted");
        ("async", `Bool true);
        ("saga_id", `String saga_id);
        ("status_file", match status_file with Some p -> `String p | None -> `Null);
        ("message", `String "Handoff saga accepted. Check saga file for completion.");
      ] in
      (true, Yojson.Safe.pretty_to_string json)
  | _ ->
      let args_sync = set_bool_arg args "async" false in
      let (ok, body) = run_sync_handoff ctx args_sync in
      let parsed =
        try Yojson.Safe.from_string body
        with _ -> `String body
      in
      let (verification, gate_pass) = run_handoff_verifier ~ctx ~args:args_sync ~parsed_result:parsed in
      let final_ok = ok && gate_pass in
      let enriched =
        match parsed with
        | `Assoc fields ->
            `Assoc (
              ("verification", match verification with Some v -> v | None -> `Null)
              :: ("verification_gate_passed", `Bool gate_pass)
              :: ("operation_ok", `Bool ok)
              :: fields
            )
        | _ ->
            `Assoc [
              ("result", parsed);
              ("verification", match verification with Some v -> v | None -> `Null);
              ("verification_gate_passed", `Bool gate_pass);
              ("operation_ok", `Bool ok);
            ]
      in
      (final_ok, Yojson.Safe.pretty_to_string enriched)

(** {1 Metrics Handlers} *)

(** P1-4: Compare generational metrics *)
let handle_metrics_compare _ctx args : result =
  let gen_a = int_of_float (get_float args "gen_a" 0.0) in
  let gen_b = int_of_float (get_float args "gen_b" 1.0) in
  match Generational_metrics.compare_generations gen_a gen_b with
  | None ->
      let json = `Assoc [
        ("error", `String "Not enough data for comparison");
        ("gen_a", `Int gen_a);
        ("gen_b", `Int gen_b);
        ("hint", `String "Need task records for both generations");
      ] in
      (false, Yojson.Safe.pretty_to_string json)
  | Some comp ->
      let json = `Assoc [
        ("gen_a", `Int comp.gen_a);
        ("gen_b", `Int comp.gen_b);
        ("completion_delta", `Float comp.completion_delta);
        ("error_delta", `Float comp.error_delta);
        ("duration_delta", `Float comp.duration_delta);
        ("token_delta", `Float comp.token_delta);
        ("retention_b", match comp.retention_b with Some r -> `Float r | None -> `Null);
        ("verdict", `String comp.verdict);
        ("formatted", `String (Generational_metrics.format_comparison comp));
      ] in
      (true, Yojson.Safe.pretty_to_string json)

(** P1-4: Record task completion *)
let handle_metrics_record _ctx args : result =
  let task_id = get_string args "task_id" (Printf.sprintf "task-%d" (int_of_float (Time_compat.now () *. 1000.0) mod 100000)) in
  let completed = match args with
    | `Assoc pairs -> (
        match List.assoc_opt "completed" pairs with
        | Some (`Bool b) -> b
        | _ -> true
      )
    | _ -> true
  in
  let duration_ms = int_of_float (get_float args "duration_ms" 0.0) in
  let error_count = int_of_float (get_float args "error_count" 0.0) in
  let input_tokens = int_of_float (get_float args "input_tokens" 0.0) in
  let output_tokens = int_of_float (get_float args "output_tokens" 0.0) in
  let cell = !(Mcp_server.current_cell) in
  let generation = cell.Mitosis.generation in
  let record = Generational_metrics.record_task
    ~generation ~task_id ~completed ~duration_ms ~error_count
    ~input_tokens ~output_tokens
  in
  let json = `Assoc [
    ("action", `String "task_recorded");
    ("generation", `Int record.generation);
    ("task_id", `String record.task_id);
    ("completed", `Bool record.completed);
  ] in
  (true, Yojson.Safe.pretty_to_string json)

(** {1 Dispatcher} *)

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_mitosis_status" -> Some (handle_mitosis_status ctx args)
  | "masc_mitosis_all" -> Some (handle_mitosis_all ctx args)
  | "masc_mitosis_pool" -> Some (handle_mitosis_pool ctx args)
  | "masc_mitosis_divide" -> Some (handle_mitosis_divide ctx args)
  | "masc_mitosis_check" -> Some (handle_mitosis_check ctx args)
  | "masc_mitosis_record" -> Some (handle_mitosis_record ctx args)
  | "masc_mitosis_prepare" -> Some (handle_mitosis_prepare ctx args)
  | "masc_mitosis_handoff" -> Some (handle_mitosis_handoff ctx args)
  | "masc_metrics_compare" -> Some (handle_metrics_compare ctx args)
  | "masc_metrics_record" -> Some (handle_metrics_record ctx args)
  | _ -> None
