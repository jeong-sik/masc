(* Keeper canary runner — nonce fact injection -> recall protocol.

   Automates the manual methodology PR #28743 (evidence/local-ollama-10turn,
   masc, 2026-08-14) established by hand: establish N facts one per turn
   over an existing keeper's live chat surface, then ask for recall on the
   final turn, and verify the reply against the durable on-disk transcript
   rather than trusting the HTTP response alone. This is PR1 of the M1
   commission (task-11): the core 10-turn protocol only. An LLM judge (a
   different provider family than the keeper under test), --promote
   (retroactive conversion of the 20 existing hand-run canary-*.jsonl files
   to this schema), and the --wall-clock-target / --inject-restart /
   --inject-failover ladder flags for the 1h/2h/4h/24h E6 tiers are
   follow-up PRs — this file reserves [judgment: null] in the evidence for
   the judge PR to fill (see lib/keeper_canary/keeper_canary_evidence.mli).

   Unlike fusion_run.ml (calls Fusion_panel.run / Fusion_judge.run directly,
   in-process, bypassing the server), this harness drives a live server over
   HTTP: the thing under test here is the server's own turn dispatch and
   durable chat store, which an in-process call would bypass entirely.

   Every fact value is derived deterministically from --run-id (see
   Keeper_canary_facts's doc comment) rather than process-internal
   randomness or wall-clock values, so a run is reproducible by hand from
   its run id and the evidence file never carries a source of variation
   the caller did not choose.

   Usage:
     dune exec bin/keeper_canary_run.exe -- \
       --keeper NAME --run-id ID [--runtime LABEL] [--base PATH] \
       [--host HOST] [--port N] [--facts N] [--turn-interval SECONDS] \
       [--turn-timeout SECONDS] [--wall-clock-target SECONDS] \
       [--inject-restart-after N] [--inject-failover-after N \
       --failover-down-cmd CMD [--failover-up-cmd CMD]] \
       [--judge-runtime ID] [--expect-runtime ID] [--out PATH] *)

let default_facts = 9
let default_turn_interval_s = 0.0

let usage =
  "usage: keeper_canary_run --keeper NAME --run-id ID [--runtime LABEL] \
   [--base PATH] [--host HOST] [--port N] [--facts N] \
   [--turn-interval SECONDS] [--turn-timeout SECONDS] \
   [--wall-clock-target SECONDS] [--inject-restart-after N] \
   [--inject-failover-after N --failover-down-cmd CMD [--failover-up-cmd CMD]] \
   [--judge-runtime ID] [--expect-runtime ID] [--out PATH] \
   [--allow-reused-keeper]"

type args = {
  keeper : string;
  run_id : string;
  runtime : string option;
  base_path : string option;
  host : string option;
  port : int option;
  facts : int;
  turn_interval_s : float;
  turn_timeout_s : float option;
  wall_clock_target_s : float option;
  inject_restart_after : int option;
  inject_failover_after : int option;
  failover_down_cmd : string option;
  failover_up_cmd : string option;
  judge_runtime : string option;
  expect_runtime : string option;
  out : string option;
  allow_reused_keeper : bool;
}

let parse_args argv =
  let keeper = ref None in
  let run_id = ref None in
  let runtime = ref None in
  let base_path = ref None in
  let host = ref None in
  let port = ref None in
  let facts = ref default_facts in
  let turn_interval_s = ref default_turn_interval_s in
  let turn_timeout_s = ref None in
  let wall_clock_target_s = ref None in
  let inject_restart_after = ref None in
  let inject_failover_after = ref None in
  let failover_down_cmd = ref None in
  let failover_up_cmd = ref None in
  let judge_runtime = ref None in
  let expect_runtime = ref None in
  let out = ref None in
  let allow_reused_keeper = ref false in
  let rec parse = function
    | [] -> Ok ()
    | "--keeper" :: v :: rest ->
      keeper := Some v;
      parse rest
    | [ "--keeper" ] -> Error "missing value for --keeper"
    | "--run-id" :: v :: rest ->
      run_id := Some v;
      parse rest
    | [ "--run-id" ] -> Error "missing value for --run-id"
    | "--runtime" :: v :: rest ->
      runtime := Some v;
      parse rest
    | [ "--runtime" ] -> Error "missing value for --runtime"
    | "--base" :: v :: rest ->
      base_path := Some v;
      parse rest
    | [ "--base" ] -> Error "missing value for --base"
    | "--host" :: v :: rest ->
      host := Some v;
      parse rest
    | [ "--host" ] -> Error "missing value for --host"
    | "--port" :: v :: rest ->
      (match int_of_string_opt v with
       | Some p -> port := Some p; parse rest
       | None -> Error ("--port must be an integer, got " ^ v))
    | [ "--port" ] -> Error "missing value for --port"
    | "--facts" :: v :: rest ->
      (match int_of_string_opt v with
       | Some n when n >= 1 -> facts := n; parse rest
       | Some n -> Error (Printf.sprintf "--facts must be >= 1, got %d" n)
       | None -> Error ("--facts must be an integer, got " ^ v))
    | [ "--facts" ] -> Error "missing value for --facts"
    | "--turn-interval" :: v :: rest ->
      (match float_of_string_opt v with
       | Some s when s >= 0.0 -> turn_interval_s := s; parse rest
       | Some s -> Error (Printf.sprintf "--turn-interval must be >= 0, got %g" s)
       | None -> Error ("--turn-interval must be a number, got " ^ v))
    | [ "--turn-interval" ] -> Error "missing value for --turn-interval"
    | "--turn-timeout" :: v :: rest ->
      (match float_of_string_opt v with
       | Some s when s > 0.0 -> turn_timeout_s := Some s; parse rest
       | Some s -> Error (Printf.sprintf "--turn-timeout must be > 0, got %g" s)
       | None -> Error ("--turn-timeout must be a number, got " ^ v))
    | [ "--turn-timeout" ] -> Error "missing value for --turn-timeout"
    | "--wall-clock-target" :: v :: rest ->
      (match float_of_string_opt v with
       | Some s when s > 0.0 -> wall_clock_target_s := Some s; parse rest
       | Some s -> Error (Printf.sprintf "--wall-clock-target must be > 0, got %g" s)
       | None -> Error ("--wall-clock-target must be a number, got " ^ v))
    | [ "--wall-clock-target" ] -> Error "missing value for --wall-clock-target"
    | "--inject-restart-after" :: v :: rest ->
      (match int_of_string_opt v with
       | Some n when n >= 1 -> inject_restart_after := Some n; parse rest
       | Some n -> Error (Printf.sprintf "--inject-restart-after must be >= 1, got %d" n)
       | None -> Error ("--inject-restart-after must be an integer, got " ^ v))
    | [ "--inject-restart-after" ] -> Error "missing value for --inject-restart-after"
    | "--inject-failover-after" :: v :: rest ->
      (match int_of_string_opt v with
       | Some n when n >= 1 -> inject_failover_after := Some n; parse rest
       | Some n -> Error (Printf.sprintf "--inject-failover-after must be >= 1, got %d" n)
       | None -> Error ("--inject-failover-after must be an integer, got " ^ v))
    | [ "--inject-failover-after" ] -> Error "missing value for --inject-failover-after"
    | "--failover-down-cmd" :: v :: rest ->
      failover_down_cmd := Some v;
      parse rest
    | [ "--failover-down-cmd" ] -> Error "missing value for --failover-down-cmd"
    | "--failover-up-cmd" :: v :: rest ->
      failover_up_cmd := Some v;
      parse rest
    | [ "--failover-up-cmd" ] -> Error "missing value for --failover-up-cmd"
    | "--judge-runtime" :: v :: rest ->
      judge_runtime := Some v;
      parse rest
    | [ "--judge-runtime" ] -> Error "missing value for --judge-runtime"
    | "--expect-runtime" :: v :: rest ->
      expect_runtime := Some v;
      parse rest
    | [ "--expect-runtime" ] -> Error "missing value for --expect-runtime"
    | "--out" :: v :: rest ->
      out := Some v;
      parse rest
    | [ "--out" ] -> Error "missing value for --out"
    | "--allow-reused-keeper" :: rest ->
      allow_reused_keeper := true;
      parse rest
    | x :: _ -> Error ("unknown option: " ^ x)
  in
  match parse argv with
  | Error msg -> Error msg
  | Ok () ->
    (match !keeper, !run_id with
     | None, _ -> Error "--keeper NAME is required"
     | _, None -> Error "--run-id ID is required"
     | Some keeper, Some run_id ->
       if !wall_clock_target_s <> None && !turn_interval_s > 0.0
       then
         Error
           "--wall-clock-target and --turn-interval are mutually exclusive: \
            the target derives the interval"
       else if !inject_restart_after <> None && !inject_failover_after <> None
       then
         Error
           "--inject-restart-after and --inject-failover-after are mutually \
            exclusive: one injection per run keeps the evidence attributable"
       else if !inject_failover_after <> None && !failover_down_cmd = None
       then Error "--inject-failover-after requires --failover-down-cmd"
       else if !failover_down_cmd <> None && !inject_failover_after = None
       then Error "--failover-down-cmd requires --inject-failover-after"
       else if !expect_runtime <> None && !allow_reused_keeper
       then
         Error
           "--expect-runtime and --allow-reused-keeper are mutually \
            exclusive: the serving check matches harness turn indices \
            against keeper_turn_id, which only line up on a fresh keeper"
       else
       Ok
         { keeper
         ; run_id
         ; runtime = !runtime
         ; base_path = !base_path
         ; host = !host
         ; port = !port
         ; facts = !facts
         ; turn_interval_s = !turn_interval_s
         ; turn_timeout_s = !turn_timeout_s
         ; wall_clock_target_s = !wall_clock_target_s
         ; inject_restart_after = !inject_restart_after
         ; inject_failover_after = !inject_failover_after
         ; failover_down_cmd = !failover_down_cmd
         ; failover_up_cmd = !failover_up_cmd
         ; judge_runtime = !judge_runtime
         ; expect_runtime = !expect_runtime
         ; out = !out
         ; allow_reused_keeper = !allow_reused_keeper
         })

let iso8601_now () = Time_codec.rfc3339_of_unix (Unix.gettimeofday ())

(* This must testify to the canary executable that is running, not to an
   arbitrary checkout it happens to be launched from.  The trusted runtime
   manifest binds the companion binary digest to the same build source SHA;
   [binary_commit] is that SHA embedded by the Dune build rule. *)
let build_commit_opt () = (Masc.Build_identity.current ()).binary_commit

let sha256_hex text = Digestif.SHA256.(to_hex (digest_string text))

(* One fact-injection or recall turn, before durable-store correlation. *)
type turn_draft = {
  index : int;
  category : string option;
  request_id : string;
  sent_at : string;
  round_trip_s : float;
  reply_text : string;
}

(* Every row up to and including the recall turn's request is durable by the
   time this reads it: the HTTP POST in send_turn only returns after the
   server's turn (and its transcript append) has completed, so one load
   after every turn has been sent is sufficient — no per-turn reload. *)
let correlate_turn ~(messages : Masc.Keeper_chat_store.chat_message list)
    (draft : turn_draft) : Keeper_canary_evidence.turn_evidence * string option
  =
  let not_found_note =
    Printf.sprintf
      "turn %d (%s): no durable row correlated to request_id %s"
      draft.index
      (Option.value draft.category ~default:"recall")
      draft.request_id
  in
  match Keeper_chat_delivery_identity.Request_id.of_string draft.request_id with
  | Error _ ->
    ( { Keeper_canary_evidence.index = draft.index
      ; category = draft.category
      ; delivery_key = None
      ; turn_ref = None
      ; sent_at = draft.sent_at
      ; round_trip_s = draft.round_trip_s
      ; reply_digest = Some (sha256_hex draft.reply_text)
      }
    , Some not_found_note )
  | Ok rid ->
    let target = Keeper_chat_delivery_identity.Operation rid in
    let assistant_row =
      List.find_opt
        (fun (m : Masc.Keeper_chat_store.chat_message) ->
           Masc.Keeper_chat_store.Role.equal
             m.role
             Masc.Keeper_chat_store.Role.Assistant
           &&
           match m.delivery_provenance with
           | Some { delivery_key; _ } ->
             Keeper_chat_delivery_identity.delivery_key_equal delivery_key target
           | None -> false)
        messages
    in
    (match assistant_row with
     | None ->
       ( { Keeper_canary_evidence.index = draft.index
         ; category = draft.category
         ; delivery_key = None
         ; turn_ref = None
         ; sent_at = draft.sent_at
         ; round_trip_s = draft.round_trip_s
         ; reply_digest = Some (sha256_hex draft.reply_text)
         }
       , Some not_found_note )
     | Some row ->
       let delivery_key =
         Option.map
           (fun (p : Keeper_chat_delivery_identity.delivery_provenance) ->
              Keeper_chat_delivery_identity.delivery_key_to_yojson p.delivery_key)
           row.delivery_provenance
       in
       let turn_ref = Option.map Ids.Turn_ref.to_string row.turn_ref in
       ( { Keeper_canary_evidence.index = draft.index
         ; category = draft.category
         ; delivery_key
         ; turn_ref
         ; sent_at = draft.sent_at
         ; round_trip_s = draft.round_trip_s
         ; reply_digest = Some (sha256_hex draft.reply_text)
         }
       , None ))

(* --inject-restart-after: the four-step lifecycle sequence the 08-14
   drain-restart canary established live (docs/evidence/
   keeper-drain-restart-recall-live-2026-08-14T074735Z.json):
   shutdown -> read owner nonce -> directive resume -> boot. /boot answers
   409 while the owner is operator-paused, and the nonce comes from the
   trajectory projection's "generation" — the one place the durable owner
   nonce is exposed over HTTP. trace_id and generation surviving the whole
   sequence is the continuation signal (reset would mint new ones). *)

let trajectory_identity ~host ~port ~keeper_name :
  (string * int, string) result
  =
  let ( let* ) = Result.bind in
  let path = Printf.sprintf "/api/v1/keepers/%s/trajectory" keeper_name in
  let* status, body = Keeper_canary_http.admin_get ~host ~port ~path () in
  if status < 200 || status >= 300
  then Error (Printf.sprintf "GET %s returned HTTP %d: %s" path status body)
  else (
    match Yojson.Safe.from_string body with
    | exception Yojson.Json_error msg -> Error ("trajectory: invalid JSON: " ^ msg)
    | `Assoc kvs ->
      (match List.assoc_opt "trace_id" kvs, List.assoc_opt "generation" kvs with
       | Some (`String trace_id), Some (`Int generation) -> Ok (trace_id, generation)
       | _ -> Error "trajectory: missing trace_id/generation")
    | _ -> Error "trajectory: not a JSON object")

let lifecycle_post ~host ~port ~keeper_name ~action ~body () :
  (int * string, string) result
  =
  Keeper_canary_http.admin_post
    ~host
    ~port
    ~path:(Printf.sprintf "/api/v1/keepers/%s/%s" keeper_name action)
    ~body
    ()

(* Shutdown answers 200 when the drain is *accepted*; the registry lane
   passes through draining before it reaches stopped, and both /boot and
   the resume directive 409 while it is still in flight (observed live
   2026-08-16: directive answered "Resume_owner requires a paused registry
   lane, actual phase=running" two HTTP round-trips after a 200 shutdown).

   This poll is only a cheap pre-check, not a drain-completion guarantee:
   the gate projection's surface status leaves "active" the moment the
   registry phase leaves Running (Draining already reads as non-active —
   adversarial review, 2026-08-16), and the gate row exposes no registry
   phase to poll on. The 409 -> resume -> boot fallback below is the
   actual correctness mechanism when the drain is still in flight; a
   keeper with in-flight work will simply take that path every time. *)
let wait_until_stopped ~host ~port ~keeper_name :
  (unit, string) result
  =
  let ( let* ) = Result.bind in
  let poll_interval_s = 1.0 in
  let max_polls = 60 in
  let status_of body =
    match Yojson.Safe.from_string body with
    | exception Yojson.Json_error msg -> Error ("gate/keepers: invalid JSON: " ^ msg)
    | `Assoc kvs ->
      (match List.assoc_opt "keepers" kvs with
       | Some (`List rows) ->
         let row =
           List.find_opt
             (fun row ->
               match row with
               | `Assoc kvs ->
                 (match List.assoc_opt "name" kvs with
                  | Some (`String n) -> String.equal n keeper_name
                  | _ -> false)
               | _ -> false)
             rows
         in
         (match row with
          | Some (`Assoc kvs) ->
            (match List.assoc_opt "status" kvs with
             | Some (`String s) -> Ok s
             | _ -> Error "gate/keepers row missing status")
          | _ -> Error (Printf.sprintf "keeper %s not in gate/keepers" keeper_name))
       | _ -> Error "gate/keepers missing keepers list"
      )
    | _ -> Error "gate/keepers: not a JSON object"
  in
  let rec poll n =
    let* status, body = Keeper_canary_http.admin_get ~host ~port ~path:"/api/v1/gate/keepers" () in
    if status < 200 || status >= 300
    then Error (Printf.sprintf "gate/keepers returned HTTP %d" status)
    else
      let* keeper_status = status_of body in
      if not (String.equal keeper_status "active")
      then Ok ()
      else if n >= max_polls
      then
        Error
          (Printf.sprintf
             "keeper still active %d s after shutdown accepted"
             max_polls)
      else (
        Keeper_canary_http.sleep_s poll_interval_s;
        poll (n + 1))
  in
  poll 0

let inject_restart ~host ~port ~keeper_name ~run_id ~after_turn :
  (Keeper_canary_evidence.injection, string) result
  =
  let ( let* ) = Result.bind in
  let started = Unix.gettimeofday () in
  let started_at = iso8601_now () in
  let* trace_id_before, generation_before =
    trajectory_identity ~host ~port ~keeper_name
  in
  Printf.eprintf
    "[keeper_canary_run] inject restart after turn %d (trace=%s gen=%d)\n%!"
    after_turn
    trace_id_before
    generation_before;
  let* status, body =
    lifecycle_post ~host ~port ~keeper_name ~action:"shutdown" ~body:"{}" ()
  in
  let* () =
    if status >= 200 && status < 300
    then Ok ()
    else Error (Printf.sprintf "shutdown returned HTTP %d: %s" status body)
  in
  let* () = wait_until_stopped ~host ~port ~keeper_name in
  let* _trace_id_paused, _ = trajectory_identity ~host ~port ~keeper_name in
  let boot () = lifecycle_post ~host ~port ~keeper_name ~action:"boot" ~body:"{}" () in
  let* status, body = boot () in
  let* () =
    if status >= 200 && status < 300
    then Ok ()
    else if status = 409
    then (
      (* Operator-paused: commit Resume_owner through the directive
         endpoint, then boot again. operator_operation_id is run-id
         derived so an idempotent retry names the same operation. *)
      let directive_body =
        Yojson.Safe.to_string
          (`Assoc
            [ ("action", `String "resume")
            ; ( "operator_operation_id"
              , `String (Printf.sprintf "canary-restart-%s" run_id) )
            ])
      in
      let* status, body =
        lifecycle_post ~host ~port ~keeper_name ~action:"directive" ~body:directive_body ()
      in
      let* () =
        if status >= 200 && status < 300
        then Ok ()
        else Error (Printf.sprintf "directive resume returned HTTP %d: %s" status body)
      in
      let* status, body = boot () in
      if status >= 200 && status < 300
      then Ok ()
      else Error (Printf.sprintf "boot after resume returned HTTP %d: %s" status body))
    else Error (Printf.sprintf "boot returned HTTP %d: %s" status body)
  in
  let* trace_id_after, generation_after =
    trajectory_identity ~host ~port ~keeper_name
  in
  let restart =
    { Keeper_canary_evidence.after_turn
    ; started_at
    ; duration_s = Unix.gettimeofday () -. started
    ; trace_id_before
    ; trace_id_after
    ; generation_before
    ; generation_after
    }
  in
  Printf.eprintf
    "[keeper_canary_run] restart done in %.1fs continuation=%b (trace=%s gen=%d)\n%!"
    restart.duration_s
    (Keeper_canary_evidence.restart_is_continuation restart)
    trace_id_after
    generation_after;
  Ok (Keeper_canary_evidence.Restart restart)

(* --inject-failover-after: the harness owns no knowledge of how to
   break a runtime, so the operator supplies the two commands (take the
   lane's head candidate down, bring it back). The verdict never comes
   from the commands' exit codes — it is read back from the keeper's own
   runtime-manifest rows, the durable per-candidate attribution the turn
   driver writes (see Keeper_canary_failover). *)
let run_shell_command cmd : (unit, string) result =
  match
    With_process.with_process_args_in
      "/bin/sh"
      [| "/bin/sh"; "-c"; cmd |]
      With_process.drain_lines
  with
  | _, Unix.WEXITED 0 -> Ok ()
  | _, Unix.WEXITED code -> Error (Printf.sprintf "%S exited %d" cmd code)
  | _, Unix.WSIGNALED signal -> Error (Printf.sprintf "%S killed by signal %d" cmd signal)
  | _, Unix.WSTOPPED signal -> Error (Printf.sprintf "%S stopped by signal %d" cmd signal)
  | exception e -> Error (Printf.sprintf "%S failed to spawn: %s" cmd (Printexc.to_string e))

type pending_failover = {
  pf_after_turn : int;
  pf_started_at : string;
  pf_duration_s : float;
  pf_window_start : string;
  pf_down_cmd : string;
}

let start_failover ~down_cmd ~after_turn : (pending_failover, string) result =
  let ( let* ) = Result.bind in
  let window_start = iso8601_now () in
  let started = Unix.gettimeofday () in
  Printf.eprintf
    "[keeper_canary_run] inject failover after turn %d: %s\n%!"
    after_turn
    down_cmd;
  let* () = run_shell_command down_cmd in
  Ok
    { pf_after_turn = after_turn
    ; pf_started_at = window_start
    ; pf_duration_s = Unix.gettimeofday () -. started
    ; pf_window_start = window_start
    ; pf_down_cmd = down_cmd
    }

(* One fetch shape for both consumers of the runtime-manifest attempts:
   the failover verdict and the serving check (#28913). *)
let fetch_manifest_attempts ~host ~port ~keeper_name :
  (Keeper_canary_failover.attempt list, string) result
  =
  let ( let* ) = Result.bind in
  let path =
    Printf.sprintf "/api/v1/keepers/%s/runtime-trace?limit=500" keeper_name
  in
  let* status, body = Keeper_canary_http.admin_get ~host ~port ~path () in
  let* () =
    if status >= 200 && status < 300
    then Ok ()
    else Error (Printf.sprintf "runtime-trace returned HTTP %d" status)
  in
  let* json =
    match Yojson.Safe.from_string body with
    | j -> Ok j
    | exception Yojson.Json_error msg -> Error ("runtime-trace: invalid JSON: " ^ msg)
  in
  Keeper_canary_failover.parse_manifest_rows json

let finish_failover ~host ~port ~keeper_name ~up_cmd (pending : pending_failover) :
  (Keeper_canary_evidence.injection, string) result * string list
  =
  let up_notes =
    match up_cmd with
    | None -> [ "failover: no --failover-up-cmd given; the head candidate stays down" ]
    | Some cmd ->
      (match run_shell_command cmd with
       | Ok () -> []
       | Error detail ->
         (* The run itself already measured what it needed; a failed
            restore is the operator's cleanup problem, surfaced loudly
            in the evidence rather than aborting the receipt. *)
         [ Printf.sprintf "failover: up command failed: %s" detail ])
  in
  let result =
    let ( let* ) = Result.bind in
    let* attempts = fetch_manifest_attempts ~host ~port ~keeper_name in
    let mode, windowed =
      Keeper_canary_failover.classify
        ~window_start:pending.pf_window_start
        ~attempts
    in
    Printf.eprintf
      "[keeper_canary_run] failover verdict mode=%s attempts=%d\n%!"
      (Keeper_canary_failover.mode_to_string mode)
      (List.length windowed);
    Ok
      (Keeper_canary_evidence.Failover
         { after_turn = pending.pf_after_turn
         ; started_at = pending.pf_started_at
         ; duration_s = pending.pf_duration_s
         ; down_cmd = pending.pf_down_cmd
         ; up_cmd
         ; window_start = pending.pf_window_start
         ; mode
         ; attempts = windowed
         })
  in
  result, up_notes

(* A restart mid-run only measures continuity if the keeper cannot slip
   unattended turns into the transcript while the harness is not looking:
   proactive keepalive turns after boot would add facts the plan never
   sent (observed live 2026-08-14, setup_anomaly in the drain-restart
   evidence). Fail loud before turn 1 instead of polluting the ledger. *)
let require_proactive_disabled ~host ~port ~keeper_name :
  (unit, string) result
  =
  let ( let* ) = Result.bind in
  let* status, body = Keeper_canary_http.admin_get ~host ~port ~path:"/api/v1/gate/keepers" () in
  if status < 200 || status >= 300
  then Error (Printf.sprintf "gate/keepers returned HTTP %d" status)
  else (
    match Yojson.Safe.from_string body with
    | exception Yojson.Json_error msg -> Error ("gate/keepers: invalid JSON: " ^ msg)
    | json ->
      let keepers =
        match json with
        | `Assoc kvs ->
          (match List.assoc_opt "keepers" kvs with
           | Some (`List rows) -> rows
           | _ -> [])
        | _ -> []
      in
      let row =
        List.find_opt
          (fun row ->
            match row with
            | `Assoc kvs ->
              (match List.assoc_opt "name" kvs with
               | Some (`String n) -> String.equal n keeper_name
               | _ -> false)
            | _ -> false)
          keepers
      in
      (match row with
       | None -> Error (Printf.sprintf "keeper %s not in gate/keepers" keeper_name)
       | Some (`Assoc kvs) ->
         (match List.assoc_opt "proactive_enabled" kvs with
          | Some (`Bool false) -> Ok ()
          | Some (`Bool true) ->
            Error
              (Printf.sprintf
                 "keeper %s has proactive_enabled=true; unattended keepalive \
                  turns after the injected boot would pollute the fact \
                  ledger — disable proactive on this keeper first"
                 keeper_name)
          | _ -> Error "gate/keepers row missing proactive_enabled")
       | Some _ -> Error "gate/keepers row is not an object"))

type judge_fn =
  facts:Keeper_canary_facts.fact list ->
  recall_reply:string ->
  (Keeper_canary_judge.judgment, string) result

(* First-occurrence recall scoring is only sound on a transcript that
   cannot already contain this run's fact values or another round's list
   for the scorer to match first. A reused keeper broke exactly that on
   the 2026-08-16 wave-1 sweep (an old round's enum value matched before
   this run's facts and flipped order_matches). Fail loud before turn 1;
   --allow-reused-keeper turns the refusal into a recorded measurement
   condition instead. *)
let require_fresh_transcript ~host ~port ~keeper_name ~allow_reused :
  (string list, string) result
  =
  let ( let* ) = Result.bind in
  let path = Printf.sprintf "/api/v1/keepers/%s/chat/history" keeper_name in
  let* status, body = Keeper_canary_http.admin_get ~host ~port ~path () in
  if status < 200 || status >= 300
  then Error (Printf.sprintf "chat/history returned HTTP %d" status)
  else (
    match Yojson.Safe.from_string body with
    | exception Yojson.Json_error msg -> Error ("chat/history: invalid JSON: " ^ msg)
    | `List [] -> Ok []
    | `List rows ->
      if allow_reused
      then
        Ok
          [ Printf.sprintf
              "reused keeper: transcript already held %d messages before turn 1 \
               (--allow-reused-keeper); first-occurrence order scoring may be \
               polluted by earlier rounds"
              (List.length rows)
          ]
      else
        Error
          (Printf.sprintf
             "keeper %s already has %d transcript messages; recall scoring needs \
              a fresh keeper (pass --allow-reused-keeper to record the condition \
              and proceed)"
             keeper_name
             (List.length rows))
    | _ -> Error "chat/history: expected a JSON array")

let resolve_base_path (args : args) : (string, string) result =
  let resolved =
    match args.base_path with
    | Some p -> p
    | None ->
      (match Config_dir_resolver.current_env_base_path_opt () with
       | Some p -> p
       | None -> "")
  in
  if resolved = ""
  then Error "no workspace base path: set MASC_BASE_PATH or pass --base PATH"
  else Ok resolved

let run ?(judge : judge_fn option) ~(base_path : string) (args : args) :
  (Keeper_canary_evidence.run_evidence, string) result
  =
  Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path;
  Server_runtime_bootstrap.bootstrap_prompt_assets ();
  ignore
    (Masc.Prompt_defaults.bootstrap_runtime
       ~workspace_path:base_path
       ~base_path
     : string);
  let ( let* ) = Result.bind in
  (
    (* [--host] says where to reach the server. Without it the server is the one
       on this machine, so the fallback is loopback.

       It used to fall back to MASC_HOST, which is the server's bind address:
       its documented non-default values are the wildcards 0.0.0.0 and ::,
       which [Masc_network_defaults.is_unspecified_host] names as "every
       interface" rather than a reachable peer. *)
    let host =
      Option.value args.host ~default:Masc_network_defaults.masc_http_loopback_peer
    in
    let port =
      Option.value args.port ~default:(Env_config_core.masc_http_port_int ())
    in
    (* No local existence pre-flight: Keeper_registry is a process-local
       Atomic.t populated at server startup (keeper_registry_setup.ml:998,
       "Atomic.get registry"), not a disk read, so a standalone CLI process
       always sees it empty regardless of whether the keeper is real. The
       first send_turn call below surfaces "unknown keeper" from the
       server's own request validation instead — one source of truth for
       that check, not a second one this harness could drift from. *)
    let requested_facts = args.facts in
    let facts = Keeper_canary_facts.generate ~seed:args.run_id ~count:requested_facts in
    let capped_note =
      if requested_facts > List.length Keeper_canary_facts.category_names
      then
        [ Printf.sprintf
            "--facts %d exceeds the %d known categories; capped to %d"
            requested_facts
            (List.length Keeper_canary_facts.category_names)
            (List.length facts)
        ]
      else []
    in
    let mint_request_id () = Random_id.prefixed ~prefix:"canary-" ~bytes:8 in
    let send ~turn_label message =
      let request_id = mint_request_id () in
      let sent_at = iso8601_now () in
      let started = Unix.gettimeofday () in
      Printf.eprintf "[keeper_canary_run] %s -> %s\n%!" turn_label message;
      match
        Keeper_canary_http.send_turn
          ?timeout_sec:args.turn_timeout_s
          ~host
          ~port
          ~keeper_name:args.keeper
          ~request_id
          ~message
          ()
      with
      | Ok reply ->
        let round_trip_s = Unix.gettimeofday () -. started in
        Printf.eprintf "[keeper_canary_run] %s <- %s\n%!" turn_label reply;
        Ok (request_id, sent_at, round_trip_s, reply)
      | Error detail ->
        Printf.eprintf "[keeper_canary_run] %s FAILED: %s\n%!" turn_label detail;
        Error detail
    in
    (* A wall-clock target spreads the whole plan evenly: N+1 turns have N
       gaps, so interval = target / gaps. Mutual exclusion with
       --turn-interval is enforced at parse time. *)
    let effective_turn_interval_s =
      match args.wall_clock_target_s with
      | None -> args.turn_interval_s
      | Some target_s ->
        (* N fact turns + 1 recall = N gaps. *)
        Keeper_canary_facts.interval_for_wall_clock
          ~gaps:(List.length facts)
          ~target_s
    in
    let sleep_between_turns () =
      (* Eio sleep, not Unix.sleepf: a blocking sleep parks the whole Eio
         domain, which is survivable at a few seconds but not at the
         1h-to-24h gaps a wall-clock target produces. *)
      Keeper_canary_http.sleep_s effective_turn_interval_s
    in
    (* The ordered turn sequence (N fact-injection turns, then one recall
       turn) is Keeper_canary_facts.plan's job, not inline bookkeeping here
       — see that module for the (unit-tested) construction. *)
    let plan = Keeper_canary_facts.plan ~facts in
    let bounds_check ~flag = function
      | None -> Ok ()
      | Some n ->
        if n >= List.length plan
        then
          Error
            (Printf.sprintf
               "%s %d is at or past the recall turn (plan has %d turns); the \
                injection must land between turns"
               flag
               n
               (List.length plan))
        else Ok ()
    in
    let* () = bounds_check ~flag:"--inject-restart-after" args.inject_restart_after in
    let* () = bounds_check ~flag:"--inject-failover-after" args.inject_failover_after in
    let* () =
      match args.inject_restart_after with
      | None -> Ok ()
      | Some _ -> require_proactive_disabled ~host ~port ~keeper_name:args.keeper
    in
    let* transcript_notes =
      require_fresh_transcript
        ~host
        ~port
        ~keeper_name:args.keeper
        ~allow_reused:args.allow_reused_keeper
    in
    let injections = ref [] in
    let pending_failover = ref None in
    let inject_between ~completed_index =
      let restart () =
        match args.inject_restart_after with
        | Some n when n = completed_index ->
          (match
             inject_restart
               ~host
               ~port
               ~keeper_name:args.keeper
               ~run_id:args.run_id
               ~after_turn:n
           with
           | Ok injection ->
             injections := injection :: !injections;
             Ok ()
           | Error detail ->
             Error (Printf.sprintf "restart injection after turn %d failed: %s" n detail))
        | Some _ | None -> Ok ()
      in
      let failover () =
        match args.inject_failover_after, args.failover_down_cmd with
        | Some n, Some down_cmd when n = completed_index ->
          (match start_failover ~down_cmd ~after_turn:n with
           | Ok pending ->
             pending_failover := Some pending;
             Ok ()
           | Error detail ->
             Error
               (Printf.sprintf "failover injection after turn %d failed: %s" n detail))
        | _ -> Ok ()
      in
      let ( let* ) = Result.bind in
      let* () = restart () in
      failover ()
    in
    let rec send_all acc = function
      | [] -> Ok (List.rev acc)
      | (entry : Keeper_canary_facts.turn_plan_entry) :: rest ->
        let kind_label =
          match entry.category with
          | Some category -> Printf.sprintf "fact:%s" category
          | None -> "recall"
        in
        let turn_label = Printf.sprintf "turn %d (%s)" entry.index kind_label in
        (match send ~turn_label entry.message with
         | Error detail ->
           Error (Printf.sprintf "turn %d (%s) failed: %s" entry.index kind_label detail)
         | Ok (request_id, sent_at, round_trip_s, reply_text) ->
           let* () = inject_between ~completed_index:entry.index in
           (* No sleep after the last turn (the recall) — there is no next
              turn for it to space out from. *)
           if rest <> [] then sleep_between_turns ();
           send_all
             ({ index = entry.index; category = entry.category; request_id; sent_at; round_trip_s; reply_text }
              :: acc)
             rest)
    in
    let* all_drafts = send_all [] plan in
    let recall_draft =
      match List.rev all_drafts with
      | last :: _ -> last
      | [] ->
        (* Keeper_canary_facts.plan always yields at least the recall
           entry, and send_all preserves plan's length on success. *)
        assert false
    in
    let messages =
      Masc.Keeper_chat_store.load_all ~base_dir:base_path ~keeper_name:args.keeper
    in
    let turns_and_notes = List.map (correlate_turn ~messages) all_drafts in
    let turns = List.map fst turns_and_notes in
    let correlation_notes = List.filter_map snd turns_and_notes in
    let timing =
      Keeper_canary_evidence.timing_of
        (List.map (fun (d : turn_draft) -> d.round_trip_s) all_drafts)
    in
    let deterministic_signal =
      Keeper_canary_facts.score ~facts ~reply:recall_draft.reply_text
    in
    (* A requested judge that fails does not erase the run's receipt: the
       evidence still lands with [judgment = None] plus an explicit note,
       and main exits non-zero so automation sees the judging failed. *)
    let failover_notes =
      match !pending_failover with
      | None -> []
      | Some pending ->
        let result, up_notes =
          finish_failover
            ~host
            ~port
            ~keeper_name:args.keeper
            ~up_cmd:args.failover_up_cmd
            pending
        in
        (match result with
         | Ok injection ->
           injections := injection :: !injections;
           up_notes
         | Error detail ->
           (* The attribution read failing does not erase the run: the note
              records it and the missing Failover entry in [injections] is
              the loud signal. *)
           (Printf.sprintf "failover: attribution read failed: %s" detail) :: up_notes)
    in
    let judgment, judge_notes =
      match judge with
      | None -> (None, [])
      | Some judge ->
        (match judge ~facts ~recall_reply:recall_draft.reply_text with
         | Ok verdict -> (Some verdict, [])
         | Error detail -> (None, [ Printf.sprintf "judge failed: %s" detail ]))
    in
    let serving, serving_notes =
      match args.expect_runtime with
      | None -> (None, [])
      | Some expected_runtime ->
        (match fetch_manifest_attempts ~host ~port ~keeper_name:args.keeper with
         | Error detail ->
           (* Attribution unreadable means the serving claim is unproven:
              serving stays null and the exit path treats that as a failed
              check rather than a silent pass. *)
           (None, [ Printf.sprintf "serving: attribution read failed: %s" detail ])
         | Ok attempts ->
           (* [turns] already includes the recall turn: all_drafts ends
              with it and every draft is correlated into a turn row. *)
           let window_start =
             match turns with
             | first :: _ -> first.Keeper_canary_evidence.sent_at
             | [] -> recall_draft.sent_at
           in
           let turn_ids =
             List.map (fun (t : Keeper_canary_evidence.turn_evidence) -> t.index) turns
           in
           let c =
             Keeper_canary_serving.check
               ~expected_runtime
               ~window_start
               ~turn_ids
               ~attempts
           in
           Printf.eprintf
             "[keeper_canary_run] serving check expected=%s mismatched=%d unattributed=%d\n%!"
             expected_runtime
             (List.length c.Keeper_canary_serving.mismatched)
             (List.length c.Keeper_canary_serving.unattributed);
           (Some c, []))
    in
    Ok
      { Keeper_canary_evidence.captured_at = iso8601_now ()
      ; harness_git_commit = build_commit_opt ()
      ; run_id = args.run_id
      ; keeper_name = args.keeper
      ; runtime = args.runtime
      ; base_path
      ; endpoint = Keeper_canary_http.url_of ~host ~port ~path:"/api/v1/keepers/chat/stream"
      ; turn_interval_s = effective_turn_interval_s
      ; wall_clock_target_s = args.wall_clock_target_s
      ; facts
      ; turns
      ; recall =
          { turn_index = recall_draft.index
          ; request_id = recall_draft.request_id
          ; prompt = Keeper_canary_facts.recall_prompt ()
          ; reply = recall_draft.reply_text
          }
      ; timing
      ; deterministic_signal
      ; judgment
      ; injections = List.rev !injections
      ; serving
      ; notes =
          transcript_notes @ capped_note @ correlation_notes @ failover_notes
          @ judge_notes @ serving_notes
      })

(* Sized for the judge's small JSON verdict (at most nine per_fact rows and
   one rationale paragraph) — far above any observed need, far below a
   runaway generation. *)
let judge_max_tokens = 2048

let describe_http_error : Llm_provider.Http_client.http_error -> string =
  let preview_max = 200 in
  function
  | Llm_provider.Http_client.HttpError { code; body; _ } ->
    let body =
      if String.length body > preview_max then String.sub body 0 preview_max else body
    in
    Printf.sprintf "HTTP %d: %s" code body
  | Llm_provider.Http_client.NetworkError { message; _ } -> "network error: " ^ message
  | Llm_provider.Http_client.TimeoutError { message; _ } -> "timeout: " ^ message
  | Llm_provider.Http_client.AcceptRejected { reason } -> "accept rejected: " ^ reason
  | Llm_provider.Http_client.ProviderTerminal { message; _ } ->
    "provider terminal: " ^ message
  | Llm_provider.Http_client.ProviderFailure { kind; message } ->
    Llm_provider.Http_client.provider_failure_to_string ~kind ~message

let assistant_text (resp : Agent_core.Types.api_response) : string =
  resp.Agent_core.Types.content
  |> List.filter_map (function
    | Agent_core.Types.Text t -> Some t
    | _ -> None)
  |> String.concat ""

(* The server installs the deployment capability overlay at boot and a CLI
   does not; without it an Agent Core runtime present in runtime.toml still
   resolves as "absent from the AGENT_CORE capability catalog".
   keeper_capability_probe_cli.ml and fusion_run.ml carry the same call for
   the same reason. *)
let init_judge_runtime_catalog ~base_path =
  let config_path = Masc.Fusion_config_loader.runtime_toml_path ~base_path in
  ignore
    (Server_runtime_bootstrap.configure_agent_core_model_catalog_overlay
       ~config_root:(Filename.dirname config_path)
       ()
     : string option);
  match Runtime.init_default_strict ~config_path with
  | Error msg ->
    Printf.eprintf "keeper_canary_run: runtime init failed (%s): %s\n" config_path msg;
    exit 1
  | Ok () -> ()

let make_judge ~sw ~net ~clock ~judge_runtime : judge_fn =
 fun ~facts ~recall_reply ->
  match Runtime.get_runtime_by_id judge_runtime with
  | None -> Error (Printf.sprintf "unknown runtime: %s" judge_runtime)
  | Some rt ->
    (match rt.Runtime.execution with
     | Runtime_execution.Codex_app_server _ | Runtime_execution.Antigravity_cli _
     | Runtime_execution.Claude_code _ ->
       Error
         (Printf.sprintf
            "%s is a %s lane; the judge subcall needs an Agent Core runtime"
            judge_runtime
            (Runtime_execution.label rt.Runtime.execution))
     | Runtime_execution.Agent_core _ ->
       (* [_for_turn], not the bare resolver: the bare one omits the
          runtime's inference seed, and a judge measuring a request no
          keeper turn would send measures itself (masc#28473 — same
          reasoning as keeper_capability_probe.ml). *)
       (match
          Runtime_agent_core_runner.resolve_runtime_providers_for_turn
            ~runtime_id:judge_runtime
            ()
        with
        | Error detail -> Error ("provider resolution failed: " ^ detail)
        | Ok [] -> Error (judge_runtime ^ " resolved no provider")
        | Ok (config :: _) ->
          let config =
            Masc.Keeper_structured_output_schema.for_deterministic_subcall
              ~max_tokens:(Some judge_max_tokens)
              config
          in
          let message role text =
            { Agent_core.Types.role
            ; content = [ Agent_core.Types.Text text ]
            ; name = None
            ; tool_call_id = None
            ; metadata = []
            }
          in
          let messages =
            [ message Agent_core.Types.System (Keeper_canary_judge.system_prompt ())
            ; message
                Agent_core.Types.User
                (Keeper_canary_judge.compose_prompt ~facts ~recall_reply)
            ]
          in
          (match
             Masc.Keeper_provider_subcall.complete ~sw ~net ~clock ~config ~messages ()
           with
           | Error e -> Error (describe_http_error e)
           | Ok resp ->
             let text = assistant_text resp in
             if String.trim text = ""
             then Error "judge reply carried no text content"
             else Keeper_canary_judge.parse_reply ~judge_runtime ~facts text)))

let () =
  match parse_args (match Array.to_list Sys.argv with _ :: tl -> tl | [] -> []) with
  | Error msg ->
    Printf.eprintf "keeper_canary_run: %s\n%s\n" msg usage;
    exit 2
  | Ok args ->
    Eio_main.run
    @@ fun env ->
    Crypto_rng.ensure_default ();
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Process_eio.init
      ~cwd_default:(Eio.Stdenv.fs env)
      ~proc_mgr:(Eio.Stdenv.process_mgr env)
      ~clock:(Eio.Stdenv.clock env);
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Eio.Switch.run
    @@ fun sw ->
    Masc.Masc_eio_env.init ~sw ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env) ();
    Eio_context.set_env env;
    Eio_context.set_clock (Eio.Stdenv.clock env);
    Eio_context.set_switch sw;
    let base_path =
      match resolve_base_path args with
      | Ok p -> p
      | Error msg ->
        Printf.eprintf "keeper_canary_run: %s\n%s\n" msg usage;
        exit 2
    in
    let judge =
      match args.judge_runtime with
      | None -> None
      | Some judge_runtime ->
        init_judge_runtime_catalog ~base_path;
        Some
          (make_judge
             ~sw
             ~net:(Eio.Stdenv.net env)
             ~clock:(Eio.Stdenv.clock env)
             ~judge_runtime)
    in
    (match run ?judge ~base_path args with
     | Error msg ->
       Printf.eprintf "keeper_canary_run: %s\n" msg;
       exit 1
     | Ok evidence ->
       let json_text = Keeper_canary_evidence.to_pretty_string evidence in
       print_endline json_text;
       (match args.out with
        | None -> ()
        | Some path ->
          let oc = open_out path in
          output_string oc json_text;
          output_char oc '\n';
          close_out oc;
          Printf.eprintf "[keeper_canary_run] evidence written to %s\n" path);
       Printf.eprintf
         "[keeper_canary_run] run_id=%s facts=%d/%d order_matches=%b timing(min/median/max)=%.2f/%.2f/%.2fs\n"
         evidence.run_id
         evidence.deterministic_signal.facts_recalled
         evidence.deterministic_signal.facts_total
         evidence.deterministic_signal.order_matches
         evidence.timing.min_s
         evidence.timing.median_s
         evidence.timing.max_s;
       (* Returning normally from the Switch.run body leaves the process
          alive indefinitely — measured >7min after the evidence write on
          the first live success run (2026-08-16). Exact owner of the
          lingering fiber is unconfirmed (Masc_eio_env.init only captures
          handles per its .mli; the HTTP connection pool or Process_eio.init
          are the remaining suspects). Explicit exit is the sibling-harness
          convention regardless (keeper_capability_probe_cli.ml does the
          same); stdout is flushed by exit's at_exit hooks. *)
       let serving_failed =
         match args.expect_runtime, evidence.Keeper_canary_evidence.serving with
         | None, _ -> false
         | Some _, None ->
           (* Requested but unreadable: the claim is unproven, which for
              automation is the same as disproven. The note in the
              evidence carries the read error. *)
           true
         | Some _, Some c ->
           if Keeper_canary_serving.all_as_expected c
           then false
           else (
             List.iter
               (fun (turn, rid) ->
                 Printf.eprintf
                   "[keeper_canary_run] serving MISMATCH turn=%d served_by=%s\n"
                   turn
                   rid)
               c.Keeper_canary_serving.mismatched;
             List.iter
               (fun turn ->
                 Printf.eprintf
                   "[keeper_canary_run] serving UNATTRIBUTED turn=%d\n"
                   turn)
               c.Keeper_canary_serving.unattributed;
             true)
       in
       if serving_failed
       then
         (* Distinct from the judge-leg failure (1): the receipt landed but
            it does not measure the runtime it was pointed at. *)
         exit 3
       else (
         match args.judge_runtime, evidence.Keeper_canary_evidence.judgment with
         | Some _, None ->
           (* The judge was requested but produced no judgment — the receipt
              above still landed (with the failure note), and the exit code
              tells automation the judging leg failed. *)
           exit 1
         | _ -> exit 0))
