(** Mitosis_helpers — Context types, constructors, episode/saga management,
    handoff verifier logic, and evidence analysis helpers.

    This module is included by Mitosis_spawn which is included by Tool_mitosis. *)

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
  | Some sw, Some _pm ->
      (fun ~prompt ->
        let result = Spawn_eio.spawn ~sw ~agent_name ~prompt
          ~timeout_seconds ~room_config:ctx.config ()
        in
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
  Fs_compat.mkdir_p dir;
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
    Fs_compat.save_file file (Yojson.Safe.pretty_to_string json);
    Printf.printf "[EPISODE/QUEUE] Queued episode %s (gen %d) → %s\n%!" ep_id generation file;
    Some ep_id
  with exn ->
    Log.Misc.error "episode queue failed: %s" (Printexc.to_string exn);
    None

(** Saga status tracking for async handoff *)
let mitosis_saga_dir base_path =
  Filename.concat base_path ".masc/mitosis_sagas"

let generate_saga_id () =
  let ts = Time_compat.now () in
  let rand = Random.int 100000 in
  Printf.sprintf "saga-%d-%05d" (int_of_float (ts *. 1000.0)) rand

let ensure_dir dir =
  Fs_compat.mkdir_p dir

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
    Fs_compat.save_file file (Yojson.Safe.pretty_to_string json);
    Some file
  with exn ->
    Log.Misc.error "mitosis saga write failed %s: %s" file (Printexc.to_string exn);
    None

(** Get current session ID from environment or generate *)
let get_session_id () =
  match Sys.getenv_opt "TERM_SESSION_ID" with
  | Some sid when sid <> "" -> sid
  | _ ->
    match Sys.getenv_opt "MCP_SESSION_ID" with
    | Some sid when sid <> "" -> sid
    | _ -> Printf.sprintf "session-%d" (int_of_float (Time_compat.now () *. 1000.0) mod 1000000)

open Tool_args

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

let default_verifier_models =
  Llm_types.default_verifier_model_labels ()

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
  let explicit = get_string_list args "verifier_perspectives" in
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
    let model_strs = match get_string_list args "verifier_models" with [] -> default_verifier_models | xs -> xs in
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
        match Llm_types.model_spec_of_string model_str with
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
            let req = Verifier_oas.{
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
                        Verifier_oas.verify ~model req)
                  | _ ->
                      Verifier_oas.verify ~model req
                in
                `Verdict verdict
              with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | Eio.Time.Timeout ->
                  `Timeout
              | exn ->
                  `Error (Printexc.to_string exn)
            in
            let status_of = function
              | `Verdict Verifier_oas.Pass -> "pass"
              | `Verdict (Verifier_oas.Warn _) -> "warn"
              | `Verdict (Verifier_oas.Fail _) -> "fail"
              | `Timeout -> "warn"
              | `Error _ -> "warn"
            in
            let verdict_text_of = function
              | `Verdict v -> Verifier_oas.verdict_to_string v
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

