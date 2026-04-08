(** Tool_usage_log -- Durable call logging for System_internal surface tools.

    Persists tool invocations to [.masc/tool_usage/YYYY-MM/DD.jsonl] via
    {!Dated_jsonl}. Only tools on the {!Tool_catalog_surfaces.System_internal}
    surface are logged, providing evidence for safe pruning decisions.

    Writes are immediate (no buffering) since System_internal call volume
    is low. All I/O failures are caught and logged (best-effort).

    @since 2.190.0 -- Issue #5120 *)

(* -- System_internal membership set (O(1) lookup) -- *)

let system_internal_set : (string, unit) Hashtbl.t =
  let tools = Tool_catalog_surfaces.system_internal_surface_tools in
  let tbl = Hashtbl.create (List.length tools) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) tools;
  tbl

let is_system_internal name = Hashtbl.mem system_internal_set name

(* -- Store management -- *)

let store_ref : Dated_jsonl.t option ref = ref None

let init ~base_path =
  let dir = Filename.concat base_path ".masc/tool_usage" in
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
  let counts : (string, int) Hashtbl.t = Hashtbl.create 64 in
  List.iter (fun json ->
    match Safe_ops.json_string_opt "tool_name" json with
    | Some name ->
        let c = match Hashtbl.find_opt counts name with
          | Some n -> n | None -> 0 in
        Hashtbl.replace counts name (c + 1)
    | None -> ()
  ) entries;
  let pairs = Hashtbl.fold (fun k v acc -> (k, v) :: acc) counts [] in
  List.sort (fun (_, a) (_, b) -> Int.compare b a) pairs
