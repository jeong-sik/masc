module StringSet = Set.Make (String)
module StringMap = Map.Make (String)

(** Tool_usage_log -- Durable call logging for System_internal surface tools.

    Persists tool invocations to [.masc/tool_usage/YYYY-MM/DD.jsonl] via
    {!Dated_jsonl}. Only tools on the {!Tool_catalog_surfaces.System_internal}
    surface are logged, providing evidence for safe pruning decisions.

    Writes are immediate (no buffering) since System_internal call volume
    is low. All I/O failures are caught and logged (best-effort).

    @since 2.190.0 -- Issue #5120 *)

(* -- System_internal membership set (O(log n) lookup) -- *)

let system_internal_set : StringSet.t =
  let tools = Tool_catalog_surfaces.system_internal_surface_tools in
  List.fold_left (fun s name -> StringSet.add name s) StringSet.empty tools

let is_system_internal name = StringSet.mem name system_internal_set

(* -- Store management -- *)

let store_ref : Dated_jsonl.t option ref = ref None

let init ?cluster_name ~base_path () =
  let cluster_name =
    Option.value ~default:(Env_config_core.cluster_name ()) cluster_name
  in
  let dir =
    Filename.concat
      (Coord_utils.masc_root_dir_from ~base_path ~cluster_name)
      "tool_usage"
  in
  (try
     Fs_compat.mkdir_p dir;
     let store = Dated_jsonl.create ~base_dir:dir () in
     store_ref := Some store
   with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
     Log.Misc.warn "tool_usage_log: init failed: %s" (Printexc.to_string exn))

(* -- Record format -- *)

let record_to_json ~tool_name ~success ~caller =
  let fields =
    [ ("tool_name", `String tool_name)
    ; ("ts", `Float (Time_compat.now ()))
    ; ("success", `Bool success)
    ]
  in
  let fields = match caller with
    | Some c when c <> "" && c <> "unknown" ->
        fields @ [("caller", `String c)]
    | _ -> fields
  in
  `Assoc fields

(* -- Write -- *)

let log_call ~tool_name ~success ~caller =
  match !store_ref with
  | None ->
      Log.Misc.debug "tool_usage_log: store not initialized, skipping %s" tool_name
  | Some store ->
      let json = record_to_json ~tool_name ~success ~caller in
      (try Dated_jsonl.append store json
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         Log.Misc.warn "tool_usage_log: append failed for %s: %s"
           tool_name (Printexc.to_string exn))

(* -- Post-hook installation -- *)

(** Caller extraction from tool result data.
    The caller (agent_name) is not in Tool_result.t directly, so we
    extract it from the structured data if present, or default to None. *)
let extract_caller (result : Tool_result.t) : string option =
  match result.data with
  | `Assoc fields ->
      (match List.assoc_opt "agent_name" fields with
       | Some (`String s) -> Some s
       | _ -> None)
  | _ -> None

let install () =
  Tool_dispatch.register_post_hook (fun (result : Tool_result.t) ->
    if is_system_internal result.tool_name then
      log_call
        ~tool_name:result.tool_name
        ~success:result.success
        ~caller:(extract_caller result);
    result)

(* -- Read utilities (for analysis) -- *)

let read_recent ?(n = 10_000) () : Yojson.Safe.t list =
  match !store_ref with
  | None -> []
  | Some store -> Dated_jsonl.read_recent store n

let summary () : (string * int) list =
  let entries = read_recent ~n:100_000 () in
  let counts =
    List.fold_left (fun counts json ->
      match Safe_ops.json_string_opt "tool_name" json with
      | Some name ->
          let c = match StringMap.find_opt name counts with
            | Some n -> n | None -> 0 in
          StringMap.add name (c + 1) counts
      | None -> counts
    ) StringMap.empty entries
  in
  let pairs = StringMap.bindings counts in
  List.sort (fun (_, a) (_, b) -> Int.compare b a) pairs
