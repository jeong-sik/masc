(** Disk persistence for per-keeper tool-usage counters.

    Extracted from keeper_registry.ml (1495-1588) as part of the
    godfile decomp campaign. The file I/O (path + JSON serialization +
    JSON parsing) is fully separable from the Atomic state primitive
    — reads go through [Keeper_registry.get], writes go through
    [Keeper_registry.set_tool_usage_entry] (a thin facade over the
    same CAS retry [update_entry] used by [record_tool_use]). *)

open Keeper_registry_types

let schema_version = 2

let tool_usage_path ~base_path name =
  let dir =
    Filename.concat (Common.masc_dir_from_base_path ~base_path) "keepers/tool_usage"
  in
  Filename.concat dir (name ^ ".json")
;;

let flush ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ToolUsageFlushFailures)
      ~labels:[ "keeper", name ]
      ();
    Log.Keeper.warn "flush_tool_usage %s: keeper is not registered" name
  | Some entry ->
    let items =
      StringMap.fold
        (fun tool_name (e : Keeper_types.tool_call_entry) acc ->
           `Assoc
             [ "tool", `String tool_name
             ; "count", `Int e.count
             ; "successes", `Int e.successes
             ; "deferred", `Int e.deferred
             ; "failures", `Int e.failures
             ; "last_used_at", `Float e.last_used_at
             ]
           :: acc)
        entry.tool_usage
        []
    in
    let json =
      `Assoc
        [ "schema_version", `Int schema_version
        ; "keeper", `String name
        ; "flushed_at", `Float (Time_compat.now ())
        ; "tools", `List items
        ]
    in
    let path = tool_usage_path ~base_path name in
    (try
       Fs_compat.mkdir_p (Filename.dirname path);
       Fs_compat.save_file path (Yojson.Safe.to_string json ^ "\n")
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string ToolUsageFlushFailures)
         ~labels:[ "keeper", name ]
         ();
       Log.Keeper.error "flush_tool_usage %s: %s" name (Printexc.to_string exn))
;;

(* ── Batched flush ────────────────────────────────────────────────
   Instead of flushing to disk on every tool call, accumulate dirty
   keeper names in a set and flush them periodically (every 5s).
   The background flush fiber in server_runtime_bootstrap.ml calls
   [flush_all_dirty] on the interval. *)

let dirty_keepers : (string * string, unit) Hashtbl.t = Hashtbl.create 16
let dirty_mu = Stdlib.Mutex.create ()

(** Mark a keeper as needing a flush. Called on every tool use instead
    of [flush], avoiding disk I/O in the hot path. *)
let mark_dirty ~base_path name =
  Stdlib.Mutex.protect dirty_mu (fun () ->
    Hashtbl.replace dirty_keepers (base_path, name) ())

(** Flush all keepers in the dirty set. Called by the background fiber. *)
let flush_all_dirty () =
  let snapshot =
    Stdlib.Mutex.protect dirty_mu (fun () ->
      let items = Hashtbl.fold (fun k () acc -> k :: acc) dirty_keepers [] in
      Hashtbl.reset dirty_keepers;
      items)
  in
  List.iter (fun (base_path, name) -> flush ~base_path name) snapshot

let decode_tool_usage ~expected_keeper json =
  let invalid message = Error message in
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "schema_version" fields with
     | Some (`Int version) when Int.equal version schema_version ->
       (match List.assoc_opt "keeper" fields, List.assoc_opt "tools" fields with
        | Some (`String keeper), Some (`List items)
          when String.equal keeper expected_keeper ->
          let rec decode_items index seen acc = function
            | [] -> Ok (List.rev acc)
            | item :: rest ->
              (match
                 ( Safe_ops.json_string_opt "tool" item
                 , Safe_ops.json_int_opt "count" item
                 , Safe_ops.json_int_opt "successes" item
                 , Safe_ops.json_int_opt "deferred" item
                 , Safe_ops.json_int_opt "failures" item
                 , Safe_ops.json_float_opt "last_used_at" item )
               with
               | ( Some tool_name
                 , Some count
                 , Some successes
                 , Some deferred
                 , Some failures
                 , Some last_used_at )
                 when not (String.equal tool_name "")
                      && count >= 0
                      && successes >= 0
                      && deferred >= 0
                      && failures >= 0
                      && Float.is_finite last_used_at
                      && last_used_at >= 0.0
                      && successes <= count
                      && deferred <= count - successes
                      && Int.equal failures (count - successes - deferred)
                      && not (Set_util.StringSet.mem tool_name seen) ->
                 let entry : Keeper_types.tool_call_entry =
                   { count; successes; deferred; failures; last_used_at }
                 in
                 decode_items
                   (index + 1)
                   (Set_util.StringSet.add tool_name seen)
                   ((tool_name, entry) :: acc)
                   rest
               | _ ->
                 invalid
                   (Printf.sprintf
                      "invalid tool usage row at index %d for schema_version=%d"
                      index
                      schema_version))
          in
          decode_items 0 Set_util.StringSet.empty [] items
        | Some (`String keeper), _ when not (String.equal keeper expected_keeper) ->
          invalid
            (Printf.sprintf
               "keeper identity mismatch: payload=%S expected=%S"
               keeper
               expected_keeper)
        | _ -> invalid "missing required keeper string or tools array")
     | Some (`Int version) ->
       invalid
         (Printf.sprintf
            "unsupported tool usage schema_version=%d (expected=%d)"
            version
            schema_version)
     | _ -> invalid "missing required integer schema_version")
  | _ -> invalid "tool usage root must be a JSON object"
;;

let report_restore_failure name reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string CheckpointFailures)
    ~labels:[ "keeper", name; "site", "restore_tool_usage" ]
    ();
  Log.Keeper.warn "restore_tool_usage %s: %s" name reason
;;

let restore ~base_path name =
  let path = tool_usage_path ~base_path name in
  if not (Fs_compat.file_exists path)
  then ()
  else (
    match Keeper_registry.get ~base_path name with
    | None -> report_restore_failure name "keeper is not registered"
    | Some _entry ->
      (try
         let content = Fs_compat.load_file path in
         let json = Yojson.Safe.from_string content in
         (match decode_tool_usage ~expected_keeper:name json with
          | Ok tools ->
            List.iter
              (fun (tool_name, entry) ->
                 Keeper_registry.set_tool_usage_entry
                   ~base_path ~name ~tool_name entry)
              tools
          | Error reason -> report_restore_failure name reason)
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn -> report_restore_failure name (Printexc.to_string exn)))
;;
