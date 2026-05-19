(** Disk persistence for per-keeper tool-usage counters.

    Extracted from keeper_registry.ml (1495-1588) as part of the
    godfile decomp campaign. The file I/O (path + JSON serialization +
    JSON parsing) is fully separable from the Atomic state primitive
    — reads go through [Keeper_registry.get], writes go through
    [Keeper_registry.set_tool_usage_entry] (a thin facade over the
    same CAS retry [update_entry] used by [record_tool_use]). *)

open Keeper_registry_types

let tool_usage_path ~base_path name =
  let dir =
    Filename.concat (Common.masc_dir_from_base_path ~base_path) "keepers/tool_usage"
  in
  Filename.concat dir (name ^ ".json")
;;

let flush ~base_path name =
  match Keeper_registry.get ~base_path name with
  | None -> ()
  | Some entry ->
    let items =
      StringMap.fold
        (fun tool_name (e : Keeper_types.tool_call_entry) acc ->
           `Assoc
             [ "tool", `String tool_name
             ; "count", `Int e.count
             ; "successes", `Int e.successes
             ; "failures", `Int e.failures
             ; "last_used_at", `Float e.last_used_at
             ]
           :: acc)
        entry.tool_usage
        []
    in
    let json =
      `Assoc
        [ "keeper", `String name
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
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_tool_usage_flush_failures
         ~labels:[ "keeper", name ]
         ();
       Log.Keeper.error "flush_tool_usage %s: %s" name (Printexc.to_string exn))
;;

let restore ~base_path name =
  let path = tool_usage_path ~base_path name in
  if not (Fs_compat.file_exists path)
  then ()
  else (
    match Keeper_registry.get ~base_path name with
    | None -> ()
    | Some _entry ->
      (try
         let content = Fs_compat.load_file path in
         let json = Yojson.Safe.from_string content in
         let tools =
           match json with
           | `Assoc fields ->
             (match List.assoc_opt "tools" fields with
              | Some (`List items) -> items
              | _ -> [])
           | _ -> []
         in
         List.iter
           (fun item ->
              match
                ( Safe_ops.json_string_opt "tool" item
                , Safe_ops.json_int_opt "count" item
                , Safe_ops.json_int_opt "successes" item
                , Safe_ops.json_int_opt "failures" item
                , Safe_ops.json_float_opt "last_used_at" item )
              with
              | ( Some tool_name
                , Some count
                , Some successes
                , Some failures
                , Some last_used_at )
                when tool_name <> "" ->
                let e : Keeper_types.tool_call_entry =
                  { count; successes; failures; last_used_at }
                in
                Keeper_registry.set_tool_usage_entry
                  ~base_path ~name ~tool_name e
              | _ -> ())
           tools
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Prometheus.inc_counter
           Keeper_metrics.metric_keeper_checkpoint_failures
           ~labels:[ "keeper", name; "site", "restore_tool_usage" ]
           ();
         Log.Keeper.warn "restore_tool_usage %s: %s" name (Printexc.to_string exn)))
;;
