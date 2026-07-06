module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

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
    Distinguishes external MCP calls from internal agent dispatch. *)
type call_source =
  | External_mcp
  | Agent_internal

let string_of_source = function
  | External_mcp -> "external_mcp"
  | Agent_internal -> "agent_internal"
;;

(** Per-tool call statistics *)
type call_stats =
  { call_count : int Atomic.t
  ; success_count : int Atomic.t
  ; failure_count : int Atomic.t
  ; last_called_at : float Atomic.t (** Unix timestamp, 0.0 = never *)
  ; total_duration_ms : int Atomic.t
  ; external_mcp_count : int Atomic.t
  ; agent_internal_count : int Atomic.t
  ; last_assignment_id : string option Atomic.t
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
let registry : (string, call_stats) Hashtbl.t = Hashtbl.create 128

let registry_mu = Eio.Mutex.create ()
let with_registry_rw f = Eio_guard.with_mutex registry_mu f
let with_registry_ro f = Eio_guard.with_mutex_ro registry_mu f

module StringSet = Set_util.StringSet

(** Use catalog/dispatch-owned registrations instead of actor-facing surfaces.
    Tool_registry sits below keeper/OAS dispatch; depending on Config or
    keeper schemas creates cycles. Explicit metadata plus the runtime
    tag/schema registries are the local truth for callable tool names. *)
let stats_catalog_tool_names : StringSet.t Eio.Lazy.t =
  Eio.Lazy.from_fun ~cancel:`Protect (fun () ->
    let explicit_metadata_names =
      List.map fst Tool_catalog.explicit_metadata
    in
    List.fold_left
      (fun set name -> StringSet.add name set)
      StringSet.empty
      (Tool_catalog_surfaces.system_internal_hidden @ explicit_metadata_names))
;;

let is_registered_tool_name tool_name =
  Option.is_some (Tool_catalog.registered_metadata tool_name)
  || Option.is_some (Tool_dispatch.lookup_tag tool_name)
  || Option.is_some (Tool_dispatch.lookup_schema tool_name)

let is_stats_known_tool tool_name =
  StringSet.mem tool_name (Eio.Lazy.force stats_catalog_tool_names)
  || is_registered_tool_name tool_name

let is_known_tool = is_stats_known_tool

(** Record a tool call with source attribution.

    The whole find-or-create + accumulator mutation runs under
    [with_registry_rw] so two concurrent calls cannot both observe [None]
    for the same [tool_name] and both install a fresh [call_stats] record
    (which would drop one increment). Re-entry is not possible because
    the body performs only non-yielding computation. *)
let get_or_create_stats tool_name =
  match with_registry_ro (fun () -> Hashtbl.find_opt registry tool_name) with
  | Some s -> s
  | None ->
    with_registry_rw (fun () ->
      match Hashtbl.find_opt registry tool_name with
      | Some s -> s
      | None ->
        let s =
          { call_count = Atomic.make 0
          ; success_count = Atomic.make 0
          ; failure_count = Atomic.make 0
          ; last_called_at = Atomic.make 0.0
          ; total_duration_ms = Atomic.make 0
          ; external_mcp_count = Atomic.make 0
          ; agent_internal_count = Atomic.make 0
          ; last_assignment_id = Atomic.make None
          }
        in
        Hashtbl.replace registry tool_name s;
        s)
;;

let record_call
      ?(source = External_mcp)
      ?assignment_id
      ~tool_name
      ~success
      ~duration_ms
      ()
  =
  let stats = get_or_create_stats tool_name in
  Atomic.incr stats.call_count;
  (match source with
   | External_mcp -> Atomic.incr stats.external_mcp_count
   | Agent_internal -> Atomic.incr stats.agent_internal_count);
  if success then Atomic.incr stats.success_count else Atomic.incr stats.failure_count;
  Atomic.set stats.last_called_at (Time_compat.now ());
  ignore (Atomic.fetch_and_add stats.total_duration_ms duration_ms);
  match assignment_id with
  | Some _ as aid -> Atomic.set stats.last_assignment_id aid
  | None -> ()
;;

let record_call_if_known
      ?(source = External_mcp)
      ?assignment_id
      ~tool_name
      ~success
      ~duration_ms
      ()
  =
  if is_known_tool tool_name
  then record_call ~source ?assignment_id ~tool_name ~success ~duration_ms ()
;;

(** Get all stats as a sorted list (by call_count descending).

    The [Hashtbl.fold] happens under [with_registry_ro] so the snapshot of
    bindings is consistent with the concurrent [record_call] writer. The
    returned list still points at the mutable [call_stats] records, so
    callers that format fields immediately see the current values; that
    matches the pre-existing API contract (callers already have no
    transactional guarantee across fields, only that the hashtable itself
    is not corrupted). *)
let get_stats () : (string * call_stats) list =
  with_registry_ro (fun () ->
    Hashtbl.fold (fun name stats acc -> (name, stats) :: acc) registry [])
  |> List.sort (fun (_, a) (_, b) ->
    compare (Atomic.get b.call_count) (Atomic.get a.call_count))
;;

(** Get top N tools by call count *)
let get_top_n n : (string * call_stats) list =
  let all = get_stats () in
  let rec take acc n = function
    | [] -> List.rev acc
    | _ when n <= 0 -> List.rev acc
    | x :: xs -> take (x :: acc) (n - 1) xs
  in
  take [] n all
;;

(** Get tool names not called since the given Unix timestamp.
    Only includes tools that are registered (have been called at least once)
    but not recently. *)
let get_unused_since (cutoff : float) : string list =
  with_registry_ro (fun () ->
    Hashtbl.fold
      (fun name stats acc ->
         if Stdlib.Float.compare (Atomic.get stats.last_called_at) cutoff < 0
         then name :: acc
         else acc)
      registry
      [])
  |> List.sort String.compare
;;

(** Get tools that have never been called (not in registry at all)
    compared against a list of all known tool names *)
let get_never_called (all_tool_names : string list) : string list =
  with_registry_ro (fun () ->
    List.filter (fun name -> not (Hashtbl.mem registry name)) all_tool_names)
  |> List.sort String.compare
;;

(** Total calls across all tools *)
let total_calls () : int =
  with_registry_ro (fun () ->
    Hashtbl.fold (fun _ stats acc -> acc + Atomic.get stats.call_count) registry 0)
;;

(** Number of distinct tools that have been called *)
let distinct_tools_called () : int = with_registry_ro (fun () -> Hashtbl.length registry)

(** Convert call_stats to JSON *)
let stats_to_json (name, (stats : call_stats)) : Yojson.Safe.t =
  let calls = Atomic.get stats.call_count in
  `Assoc
    [ "name", `String name
    ; "call_count", `Int calls
    ; "success_count", `Int (Atomic.get stats.success_count)
    ; "failure_count", `Int (Atomic.get stats.failure_count)
    ; ( "avg_duration_ms"
      , `Int (if calls > 0 then Atomic.get stats.total_duration_ms / calls else 0) )
    ; "last_called_at", `Float (Atomic.get stats.last_called_at)
    ; ( "last_assignment_id"
      , Json_util.string_opt_to_json (Atomic.get stats.last_assignment_id) )
    ; ( "by_source"
      , `Assoc
          [ "external_mcp", `Int (Atomic.get stats.external_mcp_count)
          ; "agent_internal", `Int (Atomic.get stats.agent_internal_count)
          ] )
    ]
;;

(** Generate a full stats report as JSON *)
let stats_report ~top_n ~all_tool_names : Yojson.Safe.t =
  let bounded_top_n = max 1 (min 100 top_n) in
  let top_tools = get_top_n bounded_top_n in
  let cutoff_30d = Time_compat.now () -. Masc_time_constants.days_to_seconds 30 in
  let unused_30d = get_unused_since cutoff_30d in
  let never_called = get_never_called all_tool_names in
  `Assoc
    [ "total_calls", `Int (total_calls ())
    ; "distinct_tools_called", `Int (distinct_tools_called ())
    ; "total_tools_available", `Int (List.length all_tool_names)
    ; "top_n_requested", `Int bounded_top_n
    ; "top_tools", `List (List.map stats_to_json top_tools)
    ; "top_20", `List (List.map stats_to_json top_tools)
    ; "unused_30d", `List (List.map (fun s -> `String s) unused_30d)
    ; "unused_30d_count", `Int (List.length unused_30d)
    ; "never_called", `List (List.map (fun s -> `String s) never_called)
    ; "never_called_count", `Int (List.length never_called)
    ]
;;

(** Structural warm-up input — the per-tool fields the registry needs to
    seed its counters. Decoupled from [Telemetry_eio.tool_usage_stats] so the
    Tool dispatch substrate (lib/tool/) does not code-depend on the telemetry
    persistence layer. The composition root projects the persisted summary
    into this shape — see [Server_runtime_bootstrap]. *)
type warm_up_stats = {
  count : int;
  success_count : int;
  failure_count : int;
  last_used_at : float option;
}

(** Warm up registry from persisted per-tool stats.
    Called once at server startup to restore persistent metrics.

    [Eio_guard.with_mutex] degrades to a direct call before the Eio
    runtime is up, so this stays safe when [warm_up] runs during early
    bootstrap. *)
let warm_up (stats_by_tool : (string * warm_up_stats) list) : int =
  let count = ref 0 in
  with_registry_rw (fun () ->
    List.iter
      (fun (tool_name, (stats : warm_up_stats)) ->
         if not (Hashtbl.mem registry tool_name)
         then (
           Hashtbl.replace
             registry
             tool_name
             { call_count = Atomic.make stats.count
             ; success_count = Atomic.make stats.success_count
             ; failure_count = Atomic.make stats.failure_count
             ; last_called_at =
                 Atomic.make
                   (match stats.last_used_at with
                    | Some t -> t
                    | None -> 0.0)
             ; total_duration_ms = Atomic.make 0
             ; external_mcp_count = Atomic.make 0
             ; agent_internal_count = Atomic.make 0
             ; last_assignment_id = Atomic.make None
             };
           Stdlib.incr count))
      stats_by_tool);
  !count
;;

(** Reset all counters (for testing) *)
let reset () = with_registry_rw (fun () -> Hashtbl.clear registry)
