(** See [server_timing.mli] for the public contract. *)

type phase =
  | Cache_lookup
  | Cache_compute
  | Projection_status
  | Projection_agents
  | Projection_tasks
  | Projection_keepers
  | Projection_configured_keepers
  | Projection_config_resolution
  | Projection_runtime_resolution
  | Project_snapshot_shell_refresh
  | Project_snapshot_runtime
  | Tools_compute
  | Telemetry_query
  | Telemetry_filter
  | Telemetry_summary_per_keeper
  | Telemetry_summary_aggregate
  | Json_serialize
  | Custom of string

(* RFC 8673 §3.2.1 token grammar: ALPHA / DIGIT / "-" / "_" / "." *)
let is_token_char = function
  | '0' .. '9' | 'A' .. 'Z' | 'a' .. 'z' | '-' | '_' | '.' -> true
  | _ -> false
;;

let sanitize_token s =
  if String.length s = 0
  then "anon"
  else String.map (fun c -> if is_token_char c then c else '_') s
;;

let phase_token = function
  | Cache_lookup -> "cache_lookup"
  | Cache_compute -> "cache_compute"
  | Projection_status -> "projection_status"
  | Projection_agents -> "projection_agents"
  | Projection_tasks -> "projection_tasks"
  | Projection_keepers -> "projection_keepers"
  | Projection_configured_keepers -> "projection_configured_keepers"
  | Projection_config_resolution -> "projection_config_resolution"
  | Projection_runtime_resolution -> "projection_runtime_resolution"
  | Project_snapshot_shell_refresh -> "project_snapshot_shell_refresh"
  | Project_snapshot_runtime -> "project_snapshot_runtime"
  | Tools_compute -> "tools_compute"
  | Telemetry_query -> "telemetry_query"
  | Telemetry_filter -> "telemetry_filter"
  | Telemetry_summary_per_keeper -> "telemetry_summary_per_keeper"
  | Telemetry_summary_aggregate -> "telemetry_summary_aggregate"
  | Json_serialize -> "json_serialize"
  | Custom raw -> sanitize_token raw
;;

(* Entries are kept in insertion order so DevTools renders the bars in
   the order the handler actually executed phases. *)
type entry = { token : string; mutable ms : float }
type t = { mutable entries : entry list }

let create () = { entries = [] }

let find_or_add t token =
  let rec loop = function
    | [] ->
      let e = { token; ms = 0.0 } in
      t.entries <- t.entries @ [ e ];
      e
    | e :: _ when String.equal e.token token -> e
    | _ :: rest -> loop rest
  in
  loop t.entries
;;

let record_ms t phase ms =
  let e = find_or_add t (phase_token phase) in
  e.ms <- e.ms +. ms
;;

let measure t phase f =
  let started = Unix.gettimeofday () in
  let finish () =
    let elapsed_ms = (Unix.gettimeofday () -. started) *. 1000.0 in
    record_ms t phase elapsed_ms
  in
  match f () with
  | result ->
    finish ();
    result
  | exception exn ->
    finish ();
    raise exn
;;

(* Round to one decimal place via integer arithmetic so the wire format
   does not depend on locale or Printf rounding modes. *)
let format_ms ms =
  let tenths = int_of_float ((ms *. 10.0) +. 0.5) in
  Printf.sprintf "%d.%d" (tenths / 10) (tenths mod 10)
;;

let to_header_value t =
  match t.entries with
  | [] -> ""
  | _ ->
    t.entries
    |> List.map (fun e -> Printf.sprintf "%s;dur=%s" e.token (format_ms e.ms))
    |> String.concat ", "
;;

let extra_header t =
  match to_header_value t with
  | "" -> []
  | v -> [ "Server-Timing", v ]
;;
