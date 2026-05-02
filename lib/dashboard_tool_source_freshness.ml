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

(** Dashboard_tool_source_freshness -- source freshness metadata helpers. *)

let numeric_ts_field fields name =
  match List.assoc_opt name fields with
  | Some (`Float ts) -> Some ts
  | Some (`Int ts) -> Some (Float.of_int ts)
  | _ -> None

let latest_ts_of_record = function
  | `Assoc fields -> (
      match numeric_ts_field fields "ts_unix" with
      | Some ts -> Some ts
      | None -> (
          match numeric_ts_field fields "ts" with
          | Some ts -> Some ts
          | None -> (
              match numeric_ts_field fields "timestamp" with
              | Some ts -> Some ts
              | None -> (
                  match List.assoc_opt "ts_iso" fields with
                  | Some (`String iso) -> Types.parse_iso8601_opt iso
                  | _ -> None))))
  | _ -> None

let count_source_entries dir =
  if not (Sys.file_exists dir) then 0
  else
    match Dated_jsonl.create ~base_dir:dir () with
    | store -> Dated_jsonl.count_entries store
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn ->
      Log.Dashboard.warn
        "dashboard source entry count failed for %s: %s"
        dir
        (Stdlib.Printexc.to_string exn);
      0

let freshness_fields ~now latest_ts =
  match latest_ts with
  | Some ts ->
    [
      ("latest_ts_unix", `Float ts);
      ("latest_ts_iso", `String (Types.iso8601_of_unix_seconds ts));
      ("latest_age_s", `Float (Stdlib.Float.max 0.0 (now -. ts)));
    ]
  | None ->
    [
      ("latest_ts_unix", `Null);
      ("latest_ts_iso", `Null);
      ("latest_age_s", `Null);
    ]

let health_fields ~now ~exists ~entry_count ~latest_ts ~freshness_slo_s
    ?coverage_gap () =
  let health, stale_reason =
    match coverage_gap with
    | Some gap ->
      ( "coverage_gap",
        Safe_ops.json_string ~default:"coverage_gap" "stale_reason" gap )
    | None ->
      if not exists then ("missing", "store_missing")
      else if entry_count = 0 then ("empty", "no_entries")
      else
        match latest_ts with
        | None -> ("empty", "no_entries")
        | Some ts ->
          let latest_age_s = Stdlib.Float.max 0.0 (now -. ts) in
          if Stdlib.Float.compare latest_age_s freshness_slo_s > 0 then
            ("stale", "freshness_slo_exceeded")
          else
            ("ok", "")
  in
  [
    ("health", `String health);
    ( "stale_reason",
      if String.equal stale_reason "" then `Null else `String stale_reason );
  ]

let coverage_gaps_for_store ~source_name ~durable_store =
  if String.equal durable_store "" then []
  else
    let masc_root = Filename.dirname durable_store in
    Telemetry_coverage_gap.read_recent ~masc_root ~n:50
    |> List.filter (fun gap ->
         String.equal source_name
           (Safe_ops.json_string ~default:"" "source" gap))

let metadata_fields ~source_name ~source_producer ~dashboard_surface
    ~freshness_slo_s ~durable_store ~latest_record () =
  let now = Unix.gettimeofday () in
  let exists = not (String.equal durable_store "") && Sys.file_exists durable_store in
  let entry_count = if exists then count_source_entries durable_store else 0 in
  let latest_ts =
    if exists then Option.bind latest_record latest_ts_of_record else None
  in
  let coverage_gaps = coverage_gaps_for_store ~source_name ~durable_store in
  let coverage_gap = List.rev coverage_gaps |> List.find_opt (fun _ -> true) in
  [
    ("source", `String source_name);
    ("producer", `String source_producer);
    ("durable_store", `String durable_store);
    ("dashboard_surface", `String dashboard_surface);
    ("freshness_slo_s", `Float freshness_slo_s);
    ("entry_count", `Int entry_count);
    ("exists", `Bool exists);
    ("coverage_gaps", `List coverage_gaps);
    ("coverage_gap_count", `Int (List.length coverage_gaps));
  ]
  @ freshness_fields ~now latest_ts
  @ health_fields ~now ~exists ~entry_count ~latest_ts ~freshness_slo_s
      ?coverage_gap ()

let keeper_tool_call_io_fields ~dashboard_surface () =
  metadata_fields
    ~source_name:"tool_call_io"
    ~source_producer:"keeper_hooks_oas|mcp_server_eio_call_tool"
    ~dashboard_surface
    ~freshness_slo_s:300.0
    ~durable_store:
      (Keeper_tool_call_log.store_dir () |> Option.value ~default:"")
    ~latest_record:(Keeper_tool_call_log.read_latest ())
    ()
