open Result.Syntax

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
  | Tool_request_inventory
  | Tool_request_owner
  | Tool_request_payload
  | History_resolution

let decoder_name = function
  | Json -> "Yojson.Safe.from_string"
  | Retained_binding -> "Lane_addon_runtime.check_retained_binding"
  | Inventory_record -> "Lane_addon_runtime.check_inventory_record"
  | Native_lease -> "Native_addon_lease.inspect"
  | Cleanup_descriptor -> "Browser_addon_socket.check_retained"
  | Action_receipt -> "Lane_addon_action.of_json"
  | Exact_record -> "Lane_addon_exact.check_retained_record"
  | Tool_request_inventory -> "Lane_addon_store.tool_request_owner_entry"
  | Tool_request_owner -> "Lane_addon_tool_request_owner.Published_reader.read"
  | Tool_request_payload -> "consumer original request payload"
  | History_resolution -> "consumer history resolution record"

type tool_request_reader = scope:string -> request_id:string ->
  (Lane_addon_tool_request_owner.retained option, string) result
type request_body_reader = scope:string -> request_digest:string -> (Yojson.Safe.t, string) result
type tool_request_scope_reader = scope:string ->
  (Lane_addon_tool_request_owner.retained list, string) result
type tool_request_archive_reader = scope:string -> date:string -> request_id:string ->
  (Lane_addon_tool_request_owner.Record.t option, string) result
type history_resolution_reader = scope:string -> request_id:string -> (Yojson.Safe.t option, string) result
type history_resolution_validator = group:string -> name:string -> Yojson.Safe.t -> (unit, string) result
type payload_validator = read:tool_request_reader -> read_scope:tool_request_scope_reader -> read_body:request_body_reader ->
  read_archive:tool_request_archive_reader ->
  read_fence:history_resolution_reader -> read_resolution:history_resolution_reader ->
  Lane_addon_tool_request_owner.retained -> (unit, string) result

type refusal =
  { path : string
  ; decoder : decoder
  ; detail : string
  ; delete : string list
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
    "the Lane Add-on inventory lists the record as an issue, a declaration the \
     record names (every declaration, when its owner cannot be read) fails to \
     apply while the record is there, and every read of that instance fails; a \
     detached record that names its declaration is not refused here, because \
     declaration application passes it and keeps its fields as evidence"
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
  Printf.sprintf "stop the server, delete %s, start the new build"
    (String.concat " and " refusal.delete)

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

let empty = { rows = 0; refusals = [] }

let counted report = { report with rows = report.rows + 1 }

let refused report refusal =
  { rows = report.rows + 1; refusals = refusal :: report.refusals }

let finish report = { report with refusals = List.rev report.refusals }

let removed path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> true
  | exception Unix.Unix_error _ -> false
  | _ -> false

(* One record file: read and parse it as the store's readers do, then hand it
   to [decode]. A file removed between the listing and the read is absent, and
   so is one removed while it was checked: a running server settles an
   original by moving its record and then the body the check reads next. *)
let read_record ~after_read ~delete report ~path decode =
  match Fs_compat.load_file_opt path with
  | exception Sys_error detail ->
    refused report { path; decoder = Json; detail; delete = delete path }
  | None -> report
  | Some bytes ->
    after_read path;
    (match Yojson.Safe.from_string bytes with
     | exception Yojson.Json_error detail ->
       refused report { path; decoder = Json; detail; delete = delete path }
     | json ->
       (match decode json with
        | Ok () -> counted report
        | Error (decoder, detail) ->
          if removed path then report else refused report { path; decoder; detail; delete = delete path }))

let decoded decoder result = Result.map_error (fun detail -> decoder, detail) result

(* What the store's reader does with one name in a record directory. *)
type entry =
  | Record
  | Skipped
  | Refused of decoder * string

(* Bindings, action receipts and Exact requests: only [.json] names are
   records, and their readers read nothing else in the directory. *)
let json_entry name = if Filename.check_suffix name ".json" then Record else Skipped

(* Discovery reads a whole scope and fails it on an entry it does not know. *)
let tool_request_owner_entry name =
  match Lane_addon_store.tool_request_owner_entry name with
  | Lane_addon_store.Record_entry -> Record
  | Staged_entry -> Skipped
  | Unknown_entry -> Refused (Tool_request_inventory, "unknown entry in original request namespace")

(* What fresh state deletes for a refused record when nothing else reads it
   with that record. *)
let record_alone path = [ path ]

let read_entries ~after_read ~delete report ~dir ~entry decode names =
  List.fold_left
    (fun report name ->
       let path = Filename.concat dir name in
       match entry name with
       | Skipped -> report
       | Refused (decoder, detail) -> refused report { path; decoder; detail; delete = delete path }
       | Record -> read_record ~after_read ~delete report ~path (decode ~name ~path))
    report
    names

let scan_bindings ~after_read root =
  let dir = Filename.concat root Lane_addon_store.bindings_directory in
  let* names = entries dir in
  Ok
    (read_entries ~after_read ~delete:record_alone empty ~dir ~entry:json_entry
       (fun ~name:_ ~path json ->
          let* () = decoded Retained_binding (Lane_addon_runtime.check_retained_binding json) in
          decoded Inventory_record (Lane_addon_runtime.check_inventory_record ~path json))
       names)

(* Records grouped one directory deep: [<store>/<digest>/<digest>.json]. *)
let scan_grouped ~after_read ~delete root directory ~entry decode =
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
           (read_entries ~after_read ~delete:(delete ~group ~group_dir) report ~dir:group_dir
              ~entry (decode ~group) names))
    (Ok empty)
    groups

(* The runtime loads a receipt by its key and refuses one that names another
   request. *)
let check_action ~group ~name json =
  let* receipt = Lane_addon_action.of_json json in
  let key =
    Lane_addon_store.action_path
      ~instance_id:receipt.Lane_addon_action.instance_id
      ~request_id:receipt.request_id
  in
  if String.equal key (Filename.concat Lane_addon_store.actions_directory (Filename.concat group name))
  then Ok ()
  else Error "retained receipt belongs to a different request"

(* The binding and observations of the instance a native claim holds are
   deleted with the slot: a binding left behind keeps retrying the cleanup of a
   slot that is gone. *)
let instance_records root instance =
  [ Lane_addon_store.binding_path instance; Lane_addon_store.observation_dir instance ]
  |> List.map (Filename.concat root)
  |> List.filter exists

(* The host reads an installation slot and, through the cleanup descriptor of
   the instance it holds, that instance's Chrome and live BiDi child slots. A
   child slot of an earlier instance is never read again, so it is not read
   here either: refusing it would stop every later deploy over a file nothing
   uses. *)
let scan_native_claims root =
  let dir = Filename.concat root Lane_addon_runtime.native_claims_directory in
  let* names = entries dir in
  Ok
    (List.fold_left
       (fun report name ->
          let slot_dir = Filename.concat dir name in
          let delete instance =
            slot_dir :: Option.fold ~none:[] ~some:(instance_records root) instance
          in
          match Lane_addon_runtime.is_installation_slot name with
          | false -> report
          | true ->
            (match Native_addon_lease.inspect ~directory:slot_dir with
             | Error (lease : Native_addon_lease.inspection_error) ->
               refused
                 report
                 { path = slot_dir
                 ; decoder = Native_lease
                 ; detail = lease.refusal
                 ; delete = delete lease.refused_instance
                 }
             | Ok None -> counted report
             | Ok (Some recorded) ->
               (match
                  Browser_addon_socket.check_retained
                    ~instance_id:recorded.Native_addon_lease.instance
                    ~slot:slot_dir
                    recorded.context
                with
                | Ok () -> counted report
                | Error detail ->
                  refused
                    report
                    { path = Filename.concat slot_dir recorded.history
                    ; decoder = Cleanup_descriptor
                    ; detail
                    ; delete = delete (Some recorded.instance)
                    })))
       empty
       names)

let scan_with ?(validate_tool_request=(fun () ~read:_ ~read_scope:_ ~read_body:_ ~read_archive:_ ~read_fence:_ ~read_resolution:_ _ -> Ok ()))
    ?(validate_history_resolution=(fun ~group:_ ~name:_ _ -> Ok ())) ~after_read store ~base_path =
  let root = Lane_addon_store.directory ~masc_dir:(Common.masc_dir_from_base_path ~base_path) in
  let report =
    match store with
    | Store.Bindings -> scan_bindings ~after_read root
    | Native_claims -> scan_native_claims root
    | Actions ->
      scan_grouped ~after_read ~delete:(fun ~group:_ ~group_dir:_ -> record_alone) root
        Lane_addon_store.actions_directory ~entry:json_entry
        (fun ~group ~name ~path:_ json -> check_action ~group ~name json |> decoded Action_receipt)
    | Exact_requests ->
      scan_grouped ~after_read ~delete:(fun ~group:_ ~group_dir:_ -> record_alone) root
        Lane_addon_store.exact_requests_directory ~entry:json_entry
        (fun ~group:_ ~name:_ ~path:_ json ->
           Lane_addon_exact.check_retained_record json |> decoded Exact_record)
    | Tool_request_owners ->
      (* One validator serves the whole scan, so it can keep what it already
         proved about an owner whose records it meets again. *)
      let validate_tool_request = validate_tool_request () in
      let archive_store=Lane_addon_store.create ~root in
      let read_archive ~scope ~date ~request_id =
        Lane_addon_tool_request_owner.load_settled ~store:archive_store ~scope ~date ~request_id
        |> Result.map_error Lane_addon_tool_request_owner.error_to_string in
      (* A record is checked with the body it names: present, named by its
         digest, canonical JSON. Like records, the body is read by path; the
         owner, mode and link checks stay with the runtime reader. *)
      let read_text path =
        try Ok (Fs_compat.load_file_opt path) with
        | Sys_error detail -> Error (path ^ ": " ^ detail)
        | Unix.Unix_error (error, operation, _) ->
          Error (path ^ ": " ^ operation ^ ": " ^ Unix.error_message error) in
      let read_body_bytes ~scope ~request_digest =
        read_text (Filename.concat root (Lane_addon_store.tool_request_body_path ~scope ~request_digest)) in
      let read_sidecar path ~scope ~request_id =
        let* bytes=read_text (Filename.concat root (path ~scope ~request_id)) in
        match bytes with None -> Ok None | Some bytes ->
          (try Ok (Some (Yojson.Safe.from_string bytes)) with Yojson.Json_error detail -> Error detail) in
      let read_fence=read_sidecar Lane_addon_store.history_fence_path in
      let read_resolution=read_sidecar Lane_addon_store.history_resolution_path in
      (* Discovery reads a scope as a whole and fails it on one record it
         cannot read, so fresh state deletes the scope: its owner records, its
         request bodies, and the history fences and resolution records that
         name those originals. A resolution record left behind names an
         original that is gone, and stops every pass of its Keeper. *)
      let scope_directories ~group ~group_dir:_ _ =
        List.filter exists
          (List.map (fun namespace -> Filename.concat root (Filename.concat namespace group))
             [ Lane_addon_store.tool_request_owners_directory
             ; Lane_addon_store.tool_request_bodies_directory
             ; Lane_addon_store.history_fences_directory
             ; Lane_addon_store.history_resolutions_directory ]) in
      (* A pass decodes every resolution record of its scope, also one whose
         original has no record left, so they are read from their own
         directory and not through the originals. *)
      let* resolutions =
        scan_grouped ~after_read ~delete:scope_directories root
          Lane_addon_store.history_resolutions_directory ~entry:tool_request_owner_entry
          (fun ~group ~name ~path:_ json ->
             validate_history_resolution ~group ~name json |> decoded History_resolution) in
      let+ originals =
      scan_grouped ~after_read ~delete:scope_directories root
        Lane_addon_store.tool_request_owners_directory ~entry:tool_request_owner_entry
        (fun ~group ->
          (* Share verified body decoding while checking this physical scope.
             Every parent/body/scope read still observes the current bytes.
             Discard these retained bytes and JSON before the next group. *)
          let module Reader=Lane_addon_tool_request_owner.Published_reader in
          let reader=Reader.create ~read_body:read_body_bytes in
          let read_body ~scope ~request_digest =
            Reader.request reader ~scope ~request_digest
            |> Result.map_error (fun detail ->
              Filename.concat root (Lane_addon_store.tool_request_body_path ~scope ~request_digest) ^ ": " ^ detail) in
          let read_name ~scope ~name =
            let group=Lane_addon_store.digest scope in
            let path=Filename.concat root (Filename.concat Lane_addon_store.tool_request_owners_directory
              (Filename.concat group name)) in
            let* bytes=read_text path in
            match bytes with
            | None -> Ok None
            | Some bytes ->
              let result =
                let* json=try Ok (Yojson.Safe.from_string bytes) with Yojson.Json_error detail -> Error detail in
                let* record=Reader.read reader ~directory_name:group ~file_name:name json in
                if record.scope=scope then Ok (Some record)
                else Error "original parent belongs to another scope" in
              Result.map_error (fun detail -> path ^ ": " ^ detail) result
          in
          let read ~scope ~request_id =
            let* record=read_name ~scope ~name:(Lane_addon_store.digest request_id ^ ".json") in
            match record with
            | Some record when record.request_id<>request_id -> Error "original parent belongs to another request"
            | None | Some _ -> Ok record in
          let read_scope ~scope =
            let directory=Filename.concat root (Filename.concat Lane_addon_store.tool_request_owners_directory
              (Lane_addon_store.digest scope)) in
            let* names=entries directory in
            List.fold_right (fun name rest ->
              let* rest=rest in
              match tool_request_owner_entry name with
              | Skipped -> Ok rest
              | Refused (_,detail) -> Error (Filename.concat directory name ^ ": " ^ detail)
              | Record -> let* record=read_name ~scope ~name in
                Ok (Option.fold ~none:rest ~some:(fun record -> record::rest) record)) names (Ok []) in
          fun ~name ~path:_ json ->
            let* record=Reader.read reader ~directory_name:group ~file_name:name json
              |> decoded Tool_request_owner in
            validate_tool_request ~read ~read_scope ~read_body ~read_archive ~read_fence ~read_resolution record |> Result.map_error (fun detail ->
              Tool_request_payload, Printf.sprintf "scope=%S request_id=%S request_digest=%s: %s"
                record.scope record.request_id record.request_digest detail)) in
      { rows = originals.rows + resolutions.rows; refusals = originals.refusals @ resolutions.refusals }
  in
  Result.map finish report

let scan = scan_with ~after_read:(fun _ -> ())

module For_testing = struct
  let scan = scan_with
end
