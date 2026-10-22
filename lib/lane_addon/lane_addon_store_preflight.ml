let ( let* ) = Result.bind

module Store = struct
  type t =
    | Bindings
    | Native_claims
    | Actions
    | Exact_requests
    | Tool_request_owners
  [@@deriving enumerate]
end

type decoder =
  | Json
  | Retained_binding
  | Inventory_record
  | Native_lease
  | Cleanup_descriptor
  | Action_receipt
  | Exact_record
  | Tool_request_owner

let decoder_name = function
  | Json -> "Yojson.Safe.from_string"
  | Retained_binding -> "Lane_addon_runtime.parse_retained_binding"
  | Inventory_record -> "Lane_addon_runtime.inventory_record_json"
  | Native_lease -> "Native_addon_lease.inspect"
  | Cleanup_descriptor -> "Browser_addon_socket.decode_cleanup_context"
  | Action_receipt -> "Lane_addon_action.of_json"
  | Exact_record -> "Lane_addon_exact.check_retained_record"
  | Tool_request_owner -> "Lane_addon_tool_request_owner.check_published"

type refusal =
  { path : string
  ; decoder : decoder
  ; detail : string
  ; aside : string list
  }

type report =
  { rows : int
  ; refusals : refusal list
  }

let name = function
  | Store.Bindings -> "lane-addon bindings"
  | Native_claims -> "lane-addon native claims"
  | Actions -> "lane-addon action receipts"
  | Exact_requests -> "lane-addon exact requests"
  | Tool_request_owners -> "lane-addon tool request owners"

let on_refusal = function
  | Store.Bindings ->
    "the Lane Add-on inventory lists the record as an issue, and a declaration \
     the record names (any declaration, when its owner cannot be read) fails to \
     apply while the record is there"
  | Native_claims ->
    "the host cannot confirm the cleanup of the instance the slot holds, so that \
     installation stays failed and refuses every new start (#45106)"
  | Actions -> "reading that action receipt fails"
  | Exact_requests ->
    "the next run of that request fails before anything is sent, so the worker's \
     request is never answered"
  | Tool_request_owners ->
    "discovering the original requests of that scope fails as a whole, and so \
     does reading that request"

let fresh_state_step refusal =
  Printf.sprintf
    "stop the server, move %s aside, start the new build"
    (String.concat " and " refusal.aside)

(* The Lane Add-on store root the runtime opens below the workspace's .masc
   directory (Lane_addon_runtime builds it the same way at each entry point). *)
let store_root ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "lane-addons"

(* A missing directory is an empty store. Once it exists, a listing failure
   means the preflight has not read records the server uses. *)
let entries dir =
  match Unix.lstat dir with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
  | exception Unix.Unix_error (code, call, _) ->
    Error (dir ^ ": " ^ call ^ ": " ^ Unix.error_message code)
  | stat when stat.Unix.st_kind <> Unix.S_DIR -> Error (dir ^ ": not a directory")
  | _ ->
    (match Sys.readdir dir with
     | exception Sys_error detail -> Error (dir ^ ": " ^ detail)
     | names -> Ok (Array.to_list names |> List.sort String.compare))

let is_directory path =
  match Unix.lstat path with
  | exception Unix.Unix_error _ -> false
  | stat -> stat.Unix.st_kind = Unix.S_DIR

let exists path =
  match Unix.lstat path with
  | exception Unix.Unix_error _ -> false
  | _ -> true

let json_files names = List.filter (fun name -> Filename.check_suffix name ".json") names

let empty = { rows = 0; refusals = [] }

let counted report = { report with rows = report.rows + 1 }

let refused report refusal =
  { rows = report.rows + 1; refusals = refusal :: report.refusals }

let finish report = { report with refusals = List.rev report.refusals }

(* One record file: read and parse it as the store's readers do, then hand it
   to [decode]. A file removed between the listing and the read is absent. *)
let read_record report ~path decode =
  match Fs_compat.load_file_opt path with
  | exception Sys_error detail ->
    refused report { path; decoder = Json; detail; aside = [ path ] }
  | None -> report
  | Some bytes ->
    (match Yojson.Safe.from_string bytes with
     | exception Yojson.Json_error detail ->
       refused report { path; decoder = Json; detail; aside = [ path ] }
     | json ->
       (match decode json with
        | Ok () -> counted report
        | Error (decoder, detail) -> refused report { path; decoder; detail; aside = [ path ] }))

let decoded decoder result = Result.map_error (fun detail -> decoder, detail) result

let scan_bindings root =
  let dir = Filename.concat root Lane_addon_store.bindings_directory in
  let* names = entries dir in
  Ok
    (List.fold_left
       (fun report name ->
          let path = Filename.concat dir name in
          read_record report ~path (fun json ->
            let* () = decoded Retained_binding (Lane_addon_runtime.parse_retained_binding_json json) in
            decoded Inventory_record (Lane_addon_runtime.inventory_record_json ~path json)))
       empty
       (json_files names))

(* Records grouped one directory deep: [<store>/<digest>/<digest>.json]. *)
let scan_grouped root directory decode =
  let dir = Filename.concat root directory in
  let* groups = entries dir in
  List.fold_left
    (fun result group ->
       let* report = result in
       let group_dir = Filename.concat dir group in
       if not (is_directory group_dir)
       then Ok report
       else
         let* names = entries group_dir in
         Ok
           (List.fold_left
              (fun report name ->
                 read_record report ~path:(Filename.concat group_dir name)
                   (decode ~group ~name))
              report
              (json_files names)))
    (Ok empty)
    groups

(* The binding and observations of the instance a native claim holds go aside
   with the slot: recovering #45106 moved all three, and a binding left behind
   keeps retrying the cleanup of a slot that is gone. *)
let instance_records root instance =
  [ Lane_addon_store.binding_path instance; Lane_addon_store.observation_dir instance ]
  |> List.map (Filename.concat root)
  |> List.filter exists

let scan_native_claims root =
  let dir = Filename.concat root Lane_addon_runtime.native_claims_directory in
  let* names = entries dir in
  Ok
    (List.fold_left
       (fun report name ->
          let slot_dir = Filename.concat dir name in
          match Lane_addon_runtime.native_claim_slot_of_name name with
          | None -> report
          | Some slot ->
            (match Native_addon_lease.inspect ~directory:slot_dir with
             | Error detail ->
               refused report { path = slot_dir; decoder = Native_lease; detail; aside = [ slot_dir ] }
             | Ok None -> counted report
             | Ok (Some recorded) ->
               (match slot with
                | Lane_addon_runtime.Chrome_child_slot | Live_bidi_child_slot -> counted report
                | Installation_slot ->
                  (match
                     Browser_addon_socket.decode_cleanup_context
                       ~instance_id:recorded.Native_addon_lease.instance
                       recorded.context
                   with
                   | Ok () -> counted report
                   | Error detail ->
                     refused
                       report
                       { path = Filename.concat slot_dir recorded.history
                       ; decoder = Cleanup_descriptor
                       ; detail
                       ; aside = slot_dir :: instance_records root recorded.instance
                       }))))
       empty
       names)

let scan store ~base_path =
  let root = store_root ~base_path in
  let report =
    match store with
    | Store.Bindings -> scan_bindings root
    | Native_claims -> scan_native_claims root
    | Actions ->
      scan_grouped root Lane_addon_store.actions_directory (fun ~group:_ ~name:_ json ->
        Lane_addon_action.of_json json |> Result.map ignore |> decoded Action_receipt)
    | Exact_requests ->
      scan_grouped root Lane_addon_store.exact_requests_directory (fun ~group:_ ~name:_ json ->
        Lane_addon_exact.check_retained_record json |> decoded Exact_record)
    | Tool_request_owners ->
      scan_grouped root Lane_addon_store.tool_request_owners_directory (fun ~group ~name json ->
        Lane_addon_tool_request_owner.check_published ~directory_name:group ~file_name:name json
        |> decoded Tool_request_owner)
  in
  Result.map finish report
