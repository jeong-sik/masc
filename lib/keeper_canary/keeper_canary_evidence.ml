(* Schema'd evidence JSON for the keeper canary harness.

   [schema_version] is "masc.keeper_canary_run.v1", distinct from
   docs/evidence/keeper-multiturn-*.json's
   "masc.keeper_feature_matrix.multiturn_evidence.v1": that schema was
   written by hand per run and its [facts_established_in_turns_1_to_9] field
   name is turn-count-shaped, which this harness's variable turn count
   cannot satisfy. This is a new schema rather than a same-named reshape of
   that one, per this repo's hard-cut convention (a schema name is a
   contract; changing its shape under the same name breaks every reader
   that already trusts it).

   [delivery_key] and [turn_ref] are carried as opaque, already-rendered
   values (JSON / string) rather than typed [Keeper_chat_delivery_identity.t]
   / [Ids.Turn_ref.t] values: this library has no Eio/network dependency and
   stays that way (see lib/keeper_canary/dune), so the durable-store lookup
   that produces those values lives in bin/keeper_canary_run.ml, which
   already links masc.keeper_chat_delivery_identity and masc_types. This
   module only knows how to serialize the result.

   [judgment] is [`Null] unless the caller ran an LLM judge: whether the
   recall reply demonstrates real continuity is a judge call (a different
   provider family than the keeper under test, per the M1 spec), not this
   harness's own substring check — see [Keeper_canary_facts.score] for that
   raw, non-authoritative signal instead. The field kept its name and
   position from the judge-less v1 shape, so a v1 reader written before the
   judge existed keeps working unchanged. *)

let schema_version = "masc.keeper_canary_run.v1"

type restart_injection = {
  after_turn : int;
  started_at : string;
  duration_s : float;
  trace_id_before : string;
  trace_id_after : string;
  generation_before : int;
  generation_after : int;
}

type failover_injection = {
  after_turn : int;
  started_at : string;
  duration_s : float;
  down_cmd : string;
  up_cmd : string option;
  window_start : string;
  mode : Keeper_canary_failover.mode;
  attempts : Keeper_canary_failover.attempt list;
}

type injection =
  | Restart of restart_injection
  | Failover of failover_injection

let restart_is_continuation (i : restart_injection) =
  String.equal i.trace_id_before i.trace_id_after
  && i.generation_before = i.generation_after

let injection_to_yojson (injection : injection) : Yojson.Safe.t =
  match injection with
  | Restart i ->
    `Assoc
      [ ("kind", `String "restart")
      ; ("after_turn", `Int i.after_turn)
      ; ("started_at", `String i.started_at)
      ; ("duration_s", `Float i.duration_s)
      ; ("trace_id_before", `String i.trace_id_before)
      ; ("trace_id_after", `String i.trace_id_after)
      ; ("generation_before", `Int i.generation_before)
      ; ("generation_after", `Int i.generation_after)
        (* Derived projection of the two identity pairs above, written out
           so a reader never re-implements the comparison. *)
      ; ("continuation", `Bool (restart_is_continuation i))
      ]
  | Failover i ->
    `Assoc
      [ ("kind", `String "failover")
      ; ("after_turn", `Int i.after_turn)
      ; ("started_at", `String i.started_at)
      ; ("duration_s", `Float i.duration_s)
      ; ("down_cmd", `String i.down_cmd)
      ; ("up_cmd", match i.up_cmd with Some c -> `String c | None -> `Null)
      ; ("window_start", `String i.window_start)
      ; ("mode", `String (Keeper_canary_failover.mode_to_string i.mode))
      ; ( "attempts"
        , `List (List.map Keeper_canary_failover.attempt_to_yojson i.attempts) )
      ]

type turn_evidence = {
  index : int;
  category : string option;
      (** The fact category this turn established, or [None] for the
          recall turn — makes [turns] self-describing without requiring a
          reader to cross-reference position against [facts_established]. *)
  delivery_key : Yojson.Safe.t option;
      (** [Keeper_chat_delivery_identity.delivery_key_to_yojson] as read
          back from the durable transcript row this turn produced.
          [None] when no row could be correlated to the [request_id] this
          turn sent — see [notes] for why. *)
  turn_ref : string option;
      (** [Ids.Turn_ref.to_string] from the same durable row. [None] when
          the row was found but carries no turn_ref, or no row was found. *)
  sent_at : string;  (** ISO8601, client-observed send time. *)
  round_trip_s : float;
      (** Wall-clock seconds from send to a parsed HTTP reply — durable
          rows written by [append_turn] share one timestamp per turn, so
          this is measured client-side, not read off the transcript. *)
  reply_digest : string option;
      (** SHA-256 hex of the assistant reply's content, or [None] when no
          reply row was found for this turn. *)
}

type recall_evidence = { turn_index : int; request_id : string; prompt : string; reply : string }

type timing = { min_s : float; median_s : float; max_s : float }

let median values =
  match List.sort compare values with
  | [] -> 0.0
  | sorted ->
    let arr = Array.of_list sorted in
    let n = Array.length arr in
    if n mod 2 = 1
    then arr.(n / 2)
    else (arr.((n / 2) - 1) +. arr.(n / 2)) /. 2.0

let timing_of = function
  | [] -> { min_s = 0.0; median_s = 0.0; max_s = 0.0 }
  | round_trips ->
    { min_s = List.fold_left min infinity round_trips
    ; median_s = median round_trips
    ; max_s = List.fold_left max neg_infinity round_trips
    }

type run_evidence = {
  captured_at : string;
  harness_git_commit : string option;
  run_id : string;
  keeper_name : string;
  runtime : string option;
      (** Caller-supplied label only (--runtime): actual runtime assignment
          is a config-side concern this harness does not enforce or
          verify — see bin/keeper_canary_run.ml's --runtime flag doc. *)
  base_path : string;
  endpoint : string;
  turn_interval_s : float;
  wall_clock_target_s : float option;
  facts : Keeper_canary_facts.fact list;
  turns : turn_evidence list;
  recall : recall_evidence;
  timing : timing;
  deterministic_signal : Keeper_canary_facts.score;
  judgment : Keeper_canary_judge.judgment option;
  injections : injection list;
  serving : Keeper_canary_serving.check option;
  notes : string list;
}

let fact_to_yojson (f : Keeper_canary_facts.fact) =
  `Assoc
    [ ("category", `String f.category)
    ; ("statement", `String f.statement)
    ; ("value", `String f.value)
    ]

let turn_to_yojson (t : turn_evidence) =
  `Assoc
    [ ("index", `Int t.index)
    ; ("category", match t.category with Some c -> `String c | None -> `Null)
    ; ( "delivery_key"
        (* [None] is a recorded finding, not a decode failure being
           papered over: it means correlate_turn found no durable row for
           this turn's request id (see bin/keeper_canary_run.ml and the
           [notes] this produces) — `Null renders that absence as-is. *)
      , match t.delivery_key with Some json -> json | None -> `Null )
    ; ("turn_ref", match t.turn_ref with Some s -> `String s | None -> `Null)
    ; ("sent_at", `String t.sent_at)
    ; ("round_trip_s", `Float t.round_trip_s)
    ; ( "reply_digest"
      , match t.reply_digest with Some d -> `String d | None -> `Null )
    ]

let recall_result_to_yojson (r : Keeper_canary_facts.recall_result) =
  `Assoc
    [ ("category", `String r.category)
    ; ("value", `String r.value)
    ; ("recalled", `Bool r.recalled)
    ; ( "first_index"
      , match r.first_index with Some i -> `Int i | None -> `Null )
    ]

let score_to_yojson (s : Keeper_canary_facts.score) =
  `Assoc
    [ ("facts_total", `Int s.facts_total)
    ; ("facts_recalled", `Int s.facts_recalled)
    ; ("order_matches", `Bool s.order_matches)
    ; ( "recalled_categories"
      , `List (List.map (fun c -> `String c) s.recalled_categories) )
    ; ( "missing_categories"
      , `List (List.map (fun c -> `String c) s.missing_categories) )
    ; ("per_fact", `List (List.map recall_result_to_yojson s.per_fact))
    ]

let to_yojson (e : run_evidence) =
  `Assoc
    [ ("schema", `String schema_version)
    ; ("captured_at", `String e.captured_at)
    ; ( "harness"
      , `Assoc
          [ ( "git_commit"
            , match e.harness_git_commit with
              | Some c -> `String c
              | None -> `Null )
          ] )
    ; ("run_id", `String e.run_id)
    ; ( "keeper"
      , `Assoc
          [ ("name", `String e.keeper_name)
          ; ("runtime", match e.runtime with Some r -> `String r | None -> `Null)
          ; ("base_path", `String e.base_path)
          ] )
    ; ( "transport"
      , `Assoc
          [ ("endpoint", `String e.endpoint)
          ; ("turn_interval_s", `Float e.turn_interval_s)
          ; ( "wall_clock_target_s"
            , match e.wall_clock_target_s with
              | Some s -> `Float s
              | None -> `Null )
          ] )
    ; ("facts_established", `List (List.map fact_to_yojson e.facts))
    ; ("turns", `List (List.map turn_to_yojson e.turns))
    ; ( "recall"
      , `Assoc
          [ ("turn_index", `Int e.recall.turn_index)
          ; ("request_id", `String e.recall.request_id)
          ; ("prompt", `String e.recall.prompt)
          ; ("reply", `String e.recall.reply)
          ] )
    ; ( "timing"
      , `Assoc
          [ ("min_s", `Float e.timing.min_s)
          ; ("median_s", `Float e.timing.median_s)
          ; ("max_s", `Float e.timing.max_s)
          ] )
    ; ("deterministic_signal", score_to_yojson e.deterministic_signal)
    ; ( "judgment"
      , match e.judgment with
        | Some j -> Keeper_canary_judge.judgment_to_yojson j
        | None -> `Null )
    ; ("injections", `List (List.map injection_to_yojson e.injections))
    ; ( "serving"
      , match e.serving with
        | None -> `Null
        | Some c -> Keeper_canary_serving.to_yojson c )
    ; ("notes", `List (List.map (fun n -> `String n) e.notes))
    ]

let to_pretty_string e = Yojson.Safe.pretty_to_string (to_yojson e)
