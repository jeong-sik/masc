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
       [--turn-timeout SECONDS] [--out PATH] *)

let default_facts = 9
let default_turn_interval_s = 0.0

let usage =
  "usage: keeper_canary_run --keeper NAME --run-id ID [--runtime LABEL] \
   [--base PATH] [--host HOST] [--port N] [--facts N] \
   [--turn-interval SECONDS] [--turn-timeout SECONDS] [--out PATH]"

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
  out : string option;
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
  let out = ref None in
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
    | "--out" :: v :: rest ->
      out := Some v;
      parse rest
    | [ "--out" ] -> Error "missing value for --out"
    | x :: _ -> Error ("unknown option: " ^ x)
  in
  match parse argv with
  | Error msg -> Error msg
  | Ok () ->
    (match !keeper, !run_id with
     | None, _ -> Error "--keeper NAME is required"
     | _, None -> Error "--run-id ID is required"
     | Some keeper, Some run_id ->
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
         ; out = !out
         })

let iso8601_now () =
  let t = Unix.gettimeofday () in
  let tm = Unix.gmtime t in
  Printf.sprintf
    "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec

(* With_process.with_process_args_in gives exact argv control (no shell
   string parsing, unlike Unix.open_process_in) and guarantees the
   subprocess is reaped on every exit path. The exit status is consumed:
   a captured line is only trusted when git actually reported success —
   e.g. a detached-HEAD-less checkout can print nothing on stdout while
   still exiting 0, and a failing invocation must not be read as "no
   commit" the same way a genuinely commit-less checkout would be. *)
let git_commit_opt () =
  try
    let lines, status =
      With_process.with_process_args_in
        "git"
        [| "git"; "rev-parse"; "HEAD" |]
        With_process.drain_lines
    in
    match status, lines with
    | Unix.WEXITED 0, line :: _ -> Some (String.trim line)
    | _ -> None
  with _ -> None

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

let run (args : args) : (Keeper_canary_evidence.run_evidence, string) result =
  let ( let* ) = Result.bind in
  let base_path =
    match args.base_path with
    | Some p -> p
    | None ->
      (match Config_dir_resolver.current_env_base_path_opt () with
       | Some p -> p
       | None -> "")
  in
  if base_path = ""
  then Error "no workspace base path: set MASC_BASE_PATH or pass --base PATH"
  else (
    let host = Option.value args.host ~default:(Env_config_core.masc_host ()) in
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
    let sleep_between_turns () =
      if args.turn_interval_s > 0.0 then Unix.sleepf args.turn_interval_s
    in
    (* The ordered turn sequence (N fact-injection turns, then one recall
       turn) is Keeper_canary_facts.plan's job, not inline bookkeeping here
       — see that module for the (unit-tested) construction. *)
    let plan = Keeper_canary_facts.plan ~facts in
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
    Ok
      { Keeper_canary_evidence.captured_at = iso8601_now ()
      ; harness_git_commit = git_commit_opt ()
      ; run_id = args.run_id
      ; keeper_name = args.keeper
      ; runtime = args.runtime
      ; base_path
      ; endpoint = Keeper_canary_http.url_of ~host ~port ~path:"/api/v1/keepers/chat/stream"
      ; turn_interval_s = args.turn_interval_s
      ; facts
      ; turns
      ; recall =
          { turn_index = recall_draft.index
          ; request_id = recall_draft.request_id
          ; prompt = Keeper_canary_facts.recall_prompt
          ; reply = recall_draft.reply_text
          }
      ; timing
      ; deterministic_signal
      ; notes = capped_note @ correlation_notes
      })

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
    (match run args with
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
       (* Masc_eio_env.init parks pool/keepalive fibers on this switch, so
          returning normally leaves Switch.run waiting on them and the
          process never exits (first live success run hung >7min after the
          evidence write, 2026-08-16). Explicit exit is the sibling-harness
          convention (keeper_capability_probe_cli.ml does the same); stdout
          is flushed by exit's at_exit hooks. *)
       exit 0)
