(** Tool Registry - In-memory call counters and usage statistics

    Provides fast O(1) in-memory tracking of tool call frequency.
    Complements Telemetry_eio's JSONL-based persistence with
    zero-allocation atomic counters for hot-path performance.

    Usage:
    - record_call is called on every tools/call dispatch
    - get_stats / get_top_n / get_unused_since provide reporting
    - Data resets on server restart (telemetry.jsonl is the durable store)
*)

(** Call source for source-aware telemetry.
    Distinguishes external MCP calls from keeper-internal dispatch. *)
type call_source =
  | External_mcp
  | Keeper_internal
  | Inline_dispatch
  | Deprecated_alias

let string_of_source = function
  | External_mcp -> "external_mcp"
  | Keeper_internal -> "keeper_internal"
  | Inline_dispatch -> "inline_dispatch"
  | Deprecated_alias -> "deprecated_alias"

(** Per-tool call statistics *)
type call_stats = {
  call_count : int;
  success_count : int;
  failure_count : int;
  last_called_at : float;  (** Unix timestamp, 0.0 = never *)
  total_duration_ms : int;
  external_mcp_count : int;
  keeper_internal_count : int;
  inline_dispatch_count : int;
  deprecated_alias_count : int;
  last_assignment_id : string option;
}

(** Global registry — process-lifetime. Protected by [registry_mu] against
    concurrent access from tool dispatch (write path via [record_call]) and
    HTTP dashboard handlers (read path via [get_stats]/[stats_report]).

    Within a single Eio domain the RMW in [record_call] (find_opt → replace
    → mutate fields) happens to be atomic today only because none of the
    steps yield, but that is an implicit contract on the scheduler, not on
    this module. The mutex makes the contract explicit so the invariant
    survives future code changes (e.g. a yielding telemetry callback) and
    any future cross-domain use. *)
module StringMap = Map.Make(String)

type msg =
  | Record_call of { source: call_source; assignment_id: string option; tool_name: string; success: bool; duration_ms: int; timestamp: float }
  | Get_stats of (string * call_stats) list Eio.Promise.u
  | Get_unused_since of float * string list Eio.Promise.u
  | Get_never_called of string list * string list Eio.Promise.u
  | Total_calls of int Eio.Promise.u
  | Distinct_tools_called of int Eio.Promise.u
  | Warm_up of Telemetry_eio.tool_usage_summary * int Eio.Promise.u
  | Reset of unit Eio.Promise.u

let mailbox = Eio.Stream.create max_int

let process_msg state msg =
  match msg with
  | Record_call { source; assignment_id; tool_name; success; duration_ms; timestamp } ->
      let stats = match StringMap.find_opt tool_name state with
        | Some s -> s
        | None -> {
            call_count = 0;
            success_count = 0;
            failure_count = 0;
            last_called_at = 0.0;
            total_duration_ms = 0;
            external_mcp_count = 0;
            keeper_internal_count = 0;
            inline_dispatch_count = 0;
            deprecated_alias_count = 0;
            last_assignment_id = None;
          }
      in
      let stats = {
        call_count = stats.call_count + 1;
        external_mcp_count = (if source = External_mcp then stats.external_mcp_count + 1 else stats.external_mcp_count);
        keeper_internal_count = (if source = Keeper_internal then stats.keeper_internal_count + 1 else stats.keeper_internal_count);
        inline_dispatch_count = (if source = Inline_dispatch then stats.inline_dispatch_count + 1 else stats.inline_dispatch_count);
        deprecated_alias_count = (if source = Deprecated_alias then stats.deprecated_alias_count + 1 else stats.deprecated_alias_count);
        success_count = (if success then stats.success_count + 1 else stats.success_count);
        failure_count = (if not success then stats.failure_count + 1 else stats.failure_count);
        last_called_at = timestamp;
        total_duration_ms = stats.total_duration_ms + duration_ms;
        last_assignment_id = (match assignment_id with Some _ as aid -> aid | None -> stats.last_assignment_id);
      } in
      StringMap.add tool_name stats state
  | Get_stats p ->
      let lst = StringMap.fold (fun k v acc -> (k, v) :: acc) state [] in
      let sorted = List.sort (fun (_, a) (_, b) -> compare b.call_count a.call_count) lst in
      Eio.Promise.resolve p sorted;
      state
  | Get_unused_since (cutoff, p) ->
      let lst = StringMap.fold (fun k v acc -> if v.last_called_at < cutoff then k :: acc else acc) state [] in
      Eio.Promise.resolve p (List.sort String.compare lst);
      state
  | Get_never_called (all, p) ->
      let lst = List.filter (fun name -> not (StringMap.mem name state)) all in
      Eio.Promise.resolve p (List.sort String.compare lst);
      state
  | Total_calls p ->
      let total = StringMap.fold (fun _ v acc -> acc + v.call_count) state 0 in
      Eio.Promise.resolve p total;
      state
  | Distinct_tools_called p ->
      Eio.Promise.resolve p (StringMap.cardinal state);
      state
  | Warm_up (summary, p) ->
      let state', count = Hashtbl.fold (fun tool_name (s : Telemetry_eio.tool_usage_stats) (acc_st, acc_count) ->
        if not (StringMap.mem tool_name acc_st) then
          let new_st = {
            call_count = s.count;
            success_count = s.success_count;
            failure_count = s.failure_count;
            last_called_at = (match s.last_used_at with Some t -> t | None -> 0.0);
            total_duration_ms = 0;
            external_mcp_count = 0;
            keeper_internal_count = 0;
            inline_dispatch_count = 0;
            deprecated_alias_count = 0;
            last_assignment_id = None;
          } in
          (StringMap.add tool_name new_st acc_st, acc_count + 1)
        else (acc_st, acc_count)
      ) summary.stats_by_tool (state, 0) in
      Eio.Promise.resolve p count;
      state'
  | Reset p ->
      Eio.Promise.resolve p ();
      StringMap.empty

let start_actor_if_needed ~sw =
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop state =
      let msg = Eio.Stream.take mailbox in
      loop (process_msg state msg)
    in
    loop StringMap.empty
  )
(** Use raw_all_tool_schemas to include hidden/internal tools.
    Previously used Config.all_tool_schemas (public-filtered), which caused
    hidden tools to be structurally undercounted in telemetry. *)
module StringSet = Set.Make (String)

let known_tool_names : StringSet.t Eio.Lazy.t =
  Eio.Lazy.from_fun ~cancel:`Protect (fun () ->
    List.fold_left
      (fun set (schema : Types.tool_schema) -> StringSet.add schema.name set)
      StringSet.empty Config.raw_all_tool_schemas)

let is_known_tool tool_name =
  StringSet.mem tool_name (Eio.Lazy.force known_tool_names)

(** Record a tool call with source attribution.

    The whole find-or-create + accumulator mutation runs under
    [with_registry_rw] so two concurrent calls cannot both observe [None]
    for the same [tool_name] and both install a fresh [call_stats] record
    (which would drop one increment). Re-entry is not possible because
    the body performs only non-yielding computation. *)


let record_call ?(source = External_mcp) ?assignment_id ~tool_name ~success ~duration_ms () =
  Eio.Stream.add mailbox (Record_call { source; assignment_id; tool_name; success; duration_ms; timestamp = Time_compat.now () })

let record_call_if_known ?(source = External_mcp) ?assignment_id ~tool_name ~success ~duration_ms () =
  if is_known_tool tool_name then
    record_call ~source ?assignment_id ~tool_name ~success ~duration_ms ()

(** Get all stats as a sorted list (by call_count descending).

    The [Hashtbl.fold] happens under [with_registry_ro] so the snapshot of
    bindings is consistent with the concurrent [record_call] writer. The
    returned list still points at the mutable [call_stats] records, so
    callers that format fields immediately see the current values; that
    matches the pre-existing API contract (callers already have no
    transactional guarantee across fields, only that the hashtable itself
    is not corrupted). *)
let get_stats () : (string * call_stats) list =
  let p, r = Eio.Promise.create () in
  Eio.Stream.add mailbox (Get_stats r);
  Eio.Promise.await p

(** Get top N tools by call count *)
let get_top_n n : (string * call_stats) list =
  let all = get_stats () in
  let rec take acc n = function
    | [] -> List.rev acc
    | _ when n <= 0 -> List.rev acc
    | x :: xs -> take (x :: acc) (n - 1) xs
  in
  take [] n all

(** Get tool names not called since the given Unix timestamp.
    Only includes tools that are registered (have been called at least once)
    but not recently. *)
let get_unused_since (cutoff : float) : string list =
  let p, r = Eio.Promise.create () in
  Eio.Stream.add mailbox (Get_unused_since (cutoff, r));
  Eio.Promise.await p

(** Get tools that have never been called (not in registry at all)
    compared against a list of all known tool names *)
let get_never_called (all_tool_names : string list) : string list =
  let p, r = Eio.Promise.create () in
  Eio.Stream.add mailbox (Get_never_called (all_tool_names, r));
  Eio.Promise.await p

(** Total calls across all tools *)
let total_calls () : int =
  let p, r = Eio.Promise.create () in
  Eio.Stream.add mailbox (Total_calls r);
  Eio.Promise.await p

(** Number of distinct tools that have been called *)
let distinct_tools_called () : int =
  let p, r = Eio.Promise.create () in
  Eio.Stream.add mailbox (Distinct_tools_called r);
  Eio.Promise.await p

(** Convert call_stats to JSON *)
let stats_to_json (name, (stats : call_stats)) : Yojson.Safe.t =
  let calls = stats.call_count in
  `Assoc [
    ("name", `String name);
    ("call_count", `Int calls);
    ("success_count", `Int (stats.success_count));
    ("failure_count", `Int (stats.failure_count));
    ("avg_duration_ms",
     `Int (if calls > 0
           then (stats.total_duration_ms) / calls
           else 0));
    ("last_called_at", `Float (stats.last_called_at));
    ("last_assignment_id",
     match stats.last_assignment_id with
     | Some aid -> `String aid
     | None -> `Null);
    ("by_source", `Assoc [
       ("external_mcp", `Int (stats.external_mcp_count));
       ("keeper_internal", `Int (stats.keeper_internal_count));
       ("inline_dispatch", `Int (stats.inline_dispatch_count));
       ("deprecated_alias", `Int (stats.deprecated_alias_count));
     ]);
  ]

(** Generate a full stats report as JSON *)
let stats_report ~top_n ~all_tool_names : Yojson.Safe.t =
  let bounded_top_n = max 1 (min 100 top_n) in
  let top_tools = get_top_n bounded_top_n in
  let cutoff_30d = Time_compat.now () -. Masc_time_constants.days_to_seconds 30 in
  let unused_30d = get_unused_since cutoff_30d in
  let never_called = get_never_called all_tool_names in
  `Assoc [
    ("total_calls", `Int (total_calls ()));
    ("distinct_tools_called", `Int (distinct_tools_called ()));
    ("total_tools_available", `Int (List.length all_tool_names));
    ("top_n_requested", `Int bounded_top_n);
    ("top_tools", `List (List.map stats_to_json top_tools));
    ("top_20", `List (List.map stats_to_json top_tools));
    ("unused_30d", `List (List.map (fun s -> `String s) unused_30d));
    ("unused_30d_count", `Int (List.length unused_30d));
    ("never_called", `List (List.map (fun s -> `String s) never_called));
    ("never_called_count", `Int (List.length never_called));
  ]

(** Warm up registry from telemetry summary.
    Called once at server startup to restore persistent metrics.

    [Eio_guard.with_mutex] degrades to a direct call before the Eio
    runtime is up, so this stays safe when [warm_up] runs during early
    bootstrap. *)
let warm_up (summary : Telemetry_eio.tool_usage_summary) : int =
  let p, r = Eio.Promise.create () in
  Eio.Stream.add mailbox (Warm_up (summary, r));
  Eio.Promise.await p

(** Reset all counters (for testing) *)
let reset () =
  let p, r = Eio.Promise.create () in
  Eio.Stream.add mailbox (Reset r);
  Eio.Promise.await p
