(* Tier K4 — keeper-side tool-emission hook implementation. *)

type accumulator = {
  mutable items : Yojson.Safe.t list;
  mutex : Stdlib.Mutex.t;
  keeper_name : string option;
    (* Tier K6 — set by [accumulator_for_keeper] so the [push]
       function can emit a per-keeper Prometheus counter without
       routing the name through every call site. [None] for the
       process-wide [global_accumulator] and for test-created
       accumulators (no metric emitted in those cases). *)
}

let create_accumulator () =
  { items = []
  ; mutex = Stdlib.Mutex.create ()
  ; keeper_name = None
  }

let create_accumulator_for ~keeper_name =
  { items = []
  ; mutex = Stdlib.Mutex.create ()
  ; keeper_name = Some keeper_name
  }

let masc_tool_emission_enabled () =
  match Sys.getenv_opt "MASC_TOOL_EMISSION" with
  | Some ("1" | "true" | "TRUE") -> true
  | _ -> false

let push acc (json : Yojson.Safe.t) : unit =
  Stdlib.Mutex.lock acc.mutex;
  acc.items <- json :: acc.items;
  Stdlib.Mutex.unlock acc.mutex;
  (* Tier K6 — emit per-keeper push counter. Counter is incremented
     OUTSIDE the accumulator mutex so the metric write does not
     extend the critical section. The [keeper_name] field is read-
     only so reading after unlock is race-free. *)
  match acc.keeper_name with
  | None -> ()
  | Some name ->
    Prometheus.inc_counter
      Prometheus.metric_keeper_tool_emission_pushes
      ~labels:[ ("keeper", name) ]
      ()

let drain acc : Yojson.Safe.t list =
  Stdlib.Mutex.lock acc.mutex;
  let items = List.rev acc.items in
  acc.items <- [];
  Stdlib.Mutex.unlock acc.mutex;
  items

let accumulator_size acc =
  Stdlib.Mutex.lock acc.mutex;
  let n = List.length acc.items in
  Stdlib.Mutex.unlock acc.mutex;
  n

let try_parse (s : string) : Yojson.Safe.t option =
  try Some (Yojson.Safe.from_string s) with _ -> None

let make_post_tool_use_hook (acc : accumulator) : Oas.Hooks.hook =
  fun event ->
    (if masc_tool_emission_enabled () then
       match event with
       | Oas.Hooks.PostToolUse { output; _ } -> (
           match output with
           | Ok { content } -> (
               match try_parse content with
               | Some json -> push acc json
               | None -> ())
           | Error _ -> ())
       | _ -> ());
    Oas.Hooks.Continue

let install_into_hooks (acc : accumulator) (hooks : Oas.Hooks.hooks)
    : Oas.Hooks.hooks =
  let k4_hook = make_post_tool_use_hook acc in
  let combined : Oas.Hooks.hook =
    match hooks.post_tool_use with
    | None -> k4_hook
    | Some original ->
        fun event ->
          (* K4 hook is observational and always returns Continue;
             we run it for its side effect, then defer the decision
             to the original hook. *)
          let _ : Oas.Hooks.hook_decision = k4_hook event in
          original event
  in
  { hooks with post_tool_use = Some combined }

let drain_into_working_context acc ~(working_context : Yojson.Safe.t option)
    : Yojson.Safe.t option =
  if not (masc_tool_emission_enabled ()) then
    let _ : Yojson.Safe.t list = drain acc in
    working_context
  else
    let items = drain acc in
    if items = [] then working_context
    else
      Multimodal.Tool_emission.emit_from_tool_results
        ~working_context items

let global_accumulator = create_accumulator ()

(* Tier K4c — per-keeper registry. Each keeper gets its own
   accumulator so concurrent multi-keeper tool emissions cannot
   bleed across attribution boundaries. The registry itself is
   guarded by [registry_mutex] for the get-or-create path; each
   accumulator value carries its own mutex for push/drain (see
   [push] / [drain]). *)
let registry : (string, accumulator) Hashtbl.t = Hashtbl.create 16
let registry_mutex : Stdlib.Mutex.t = Stdlib.Mutex.create ()

(* Tier K5 — emit registry size gauge after every register/drop so
   operators can alert on divergence from the active keeper count.
   Caller MUST already hold [registry_mutex]; we read the size
   under the same lock that mutated the table. No labels. *)
let emit_registry_size_gauge_holding_lock () : unit =
  let n = Hashtbl.length registry in
  Prometheus.set_gauge
    Prometheus.metric_keeper_tool_emission_registry_size
    ~labels:[]
    (float_of_int n)

let accumulator_for_keeper (keeper_name : string) : accumulator =
  Stdlib.Mutex.lock registry_mutex;
  let acc, grew =
    match Hashtbl.find_opt registry keeper_name with
    | Some a -> a, false
    | None ->
        let a = create_accumulator_for ~keeper_name in
        Hashtbl.add registry keeper_name a;
        a, true
  in
  if grew then emit_registry_size_gauge_holding_lock ();
  Stdlib.Mutex.unlock registry_mutex;
  acc

let registered_keeper_names () : string list =
  Stdlib.Mutex.lock registry_mutex;
  let names = Hashtbl.fold (fun k _ acc -> k :: acc) registry [] in
  Stdlib.Mutex.unlock registry_mutex;
  List.sort String.compare names

let drop_keeper_accumulator (keeper_name : string) : unit =
  Stdlib.Mutex.lock registry_mutex;
  let was_present = Hashtbl.mem registry keeper_name in
  Hashtbl.remove registry keeper_name;
  if was_present then emit_registry_size_gauge_holding_lock ();
  Stdlib.Mutex.unlock registry_mutex
