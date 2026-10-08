(** Tool Registry - In-memory call counters and usage statistics

    Provides fast O(1) in-memory tracking of tool call frequency.
    Complements Telemetry_eio's JSONL-based persistence with
    immutable per-tool observations published atomically.

    Usage:
    - record_call is called on every tools/call dispatch
    - get_stats / get_top_n / get_never_called provide reporting
    - Data resets on server restart (the date-split Telemetry_eio store is durable)
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
  { call_count : int
  ; success_count : int
  ; deferred_count : int
  ; failure_count : int
  ; last_called_at : float (** Unix timestamp, 0.0 = never *)
  ; total_duration_ms : int
  ; external_mcp_count : int
  ; agent_internal_count : int
  ; last_assignment_id : string option
  }

(** Global registry — process-lifetime. Protected by [registry_mu] against
    concurrent access from tool dispatch (write path via [record_call]) and
    HTTP dashboard handlers (read path via [get_stats]).

    The registry lock owns table membership. Each value is an atomic cell
    holding one immutable per-tool observation; recording publishes all related
    counters in one CAS, while readers retain the observation they acquired. *)
let registry : (string, call_stats Atomic.t) Hashtbl.t = Hashtbl.create 128

let registry_mu = Eio.Mutex.create ()
let with_registry_rw f = Eio_guard.with_mutex registry_mu f
let with_registry_ro f = Eio_guard.with_mutex_ro registry_mu f

module StringSet = Set_util.StringSet

(** Tool_registry sits below keeper/AGENT_CORE dispatch; depending on Config or tool
    schemas creates cycles. Explicit metadata is its local catalog truth. *)
let stats_catalog_tool_names : StringSet.t Eio.Lazy.t =
  Eio.Lazy.from_fun ~cancel:`Protect (fun () ->
    let explicit_metadata_names =
      List.map fst Tool_catalog.explicit_metadata
    in
    List.fold_left
      (fun set name -> StringSet.add name set)
      StringSet.empty
      explicit_metadata_names)
;;

let is_stats_known_tool tool_name =
  StringSet.mem tool_name (Eio.Lazy.force stats_catalog_tool_names)

let is_known_tool = is_stats_known_tool

(** Find or install the per-tool publication cell under the registry lock. *)
let get_or_create_stats tool_name =
  match with_registry_ro (fun () -> Hashtbl.find_opt registry tool_name) with
  | Some s -> s
  | None ->
    with_registry_rw (fun () ->
      match Hashtbl.find_opt registry tool_name with
      | Some s -> s
      | None ->
        let s =
          Atomic.make { call_count = 0
          ; success_count = 0
          ; deferred_count = 0
          ; failure_count = 0
          ; last_called_at = 0.0
          ; total_duration_ms = 0
          ; external_mcp_count = 0
          ; agent_internal_count = 0
          ; last_assignment_id = None
          }
        in
        Hashtbl.replace registry tool_name s;
        s)
;;

let record_call
      ?(source = External_mcp)
      ?assignment_id
      ~tool_name
      ~disposition
      ~duration_ms
      ()
  =
  let cell = get_or_create_stats tool_name in
  let now = Time_compat.now () in
  let rec publish () =
    let previous = Atomic.get cell in
    let next =
      { call_count = previous.call_count + 1
      ; success_count = previous.success_count +
          (match disposition with Tool_result.Completed _ -> 1 | Deferred _ | Failed _ -> 0)
      ; deferred_count = previous.deferred_count +
          (match disposition with Tool_result.Deferred _ -> 1 | Completed _ | Failed _ -> 0)
      ; failure_count = previous.failure_count +
          (match disposition with Tool_result.Failed _ -> 1 | Completed _ | Deferred _ -> 0)
      ; last_called_at = now
      ; total_duration_ms = previous.total_duration_ms + duration_ms
      ; external_mcp_count = previous.external_mcp_count +
          (match source with External_mcp -> 1 | Agent_internal -> 0)
      ; agent_internal_count = previous.agent_internal_count +
          (match source with Agent_internal -> 1 | External_mcp -> 0)
      ; last_assignment_id =
          (match assignment_id with Some _ -> assignment_id | None -> previous.last_assignment_id)
      }
    in
    if not (Atomic.compare_and_set cell previous next) then publish ()
  in
  publish ()
;;

let record_call_if_known
      ?(source = External_mcp)
      ?assignment_id
      ~tool_name
      ~disposition
      ~duration_ms
      ()
  =
  if is_known_tool tool_name
  then record_call ~source ?assignment_id ~tool_name ~disposition ~duration_ms ()
;;

(** Freeze each per-tool observation before sorting. The comparator and
    downstream renderers cannot observe subsequent counter updates. *)
let get_stats () : (string * call_stats) list =
  with_registry_ro (fun () ->
    Hashtbl.fold (fun name stats acc -> (name, Atomic.get stats) :: acc) registry [])
  |> List.sort (fun (_, a) (_, b) ->
    Int.compare b.call_count a.call_count)
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
    Hashtbl.fold (fun _ stats acc -> acc + (Atomic.get stats).call_count) registry 0)
;;

(** Number of distinct tools that have been called *)
let distinct_tools_called () : int = with_registry_ro (fun () -> Hashtbl.length registry)

(** Reset all counters (for testing) *)
let reset () = with_registry_rw (fun () -> Hashtbl.clear registry)
