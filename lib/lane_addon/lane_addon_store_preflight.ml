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
  | Exact_proof_link
  | Exact_slot_observation
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
  | Exact_proof_link -> "Lane_addon_exact.Retained_key.proof_path"
  | Exact_slot_observation -> "Lane_addon_exact_observation.request_id"
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
     request is never answered; a proof link no record names fails the next run \
     of a request with its ID and digest the same way; the startup sweep stops at \
     a slot observation it cannot read and removes nothing"
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

(* The Exact scan refuses files in three directories, so the report sorts
   them; the other scans already meet them in path order. *)
let finish report =
  { report with
    refusals =
      List.stable_sort (fun (left : refusal) right -> String.compare left.path right.path)
        (List.rev report.refusals)
  }

let removed path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> true
  | exception Unix.Unix_error _ -> false
  | _ -> false

type 'a read =
  | Gone
  | Unreadable of refusal
  | Read of 'a

(* One store file: read and parse it as the store's readers do, then hand it
   to [decode]. A file removed between the listing and the read is gone, and
   so is one removed while it was checked: a running server settles an
   original by moving its record and then the body the check reads next. *)
let read_file ~after_read ~delete ~path decode =
  match Fs_compat.load_file_opt path with
  | exception Sys_error detail -> Unreadable { path; decoder = Json; detail; delete = delete path }
  | None -> Gone
  | Some bytes ->
    after_read path;
    (match Yojson.Safe.from_string bytes with
     | exception Yojson.Json_error detail ->
       Unreadable { path; decoder = Json; detail; delete = delete path }
     | json ->
       (match decode json with
        | Ok value -> Read value
        | Error (decoder, detail) ->
          if removed path then Gone else Unreadable { path; decoder; detail; delete = delete path }))

let read_record ~after_read ~delete report ~path decode =
  match read_file ~after_read ~delete ~path decode with
  | Gone -> report
  | Unreadable refusal -> refused report refusal
  | Read () -> counted report

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
let scan_groups root directory scan_group =
  let dir = Filename.concat root directory in
  let* groups = entries dir in
  List.fold_left
    (fun result group ->
       let* report = result in
       let group_dir = Filename.concat dir group in
       if is_directory group_dir then scan_group report ~group ~group_dir else Ok report)
    (Ok empty)
    groups

let scan_grouped ~after_read ~delete root directory ~entry decode =
  scan_groups root directory (fun report ~group ~group_dir ->
    let* names = entries group_dir in
    Ok
      (read_entries ~after_read ~delete:(delete ~group ~group_dir) report ~dir:group_dir ~entry
         (decode ~group) names))

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

module Exact = Lane_addon_exact
module Exact_observation = Lane_addon_exact_observation

(* A proof link and a slot observation name the store root they were written
   under. A file that names another root than this scan's comes from another
   store, or this scan's root is wrong; the check cannot tell which, so it
   deletes nothing and stops (RFC exact-request-skips-a-slot-that-refused-its-input
   3.3). *)
let same_store store ~path roots =
  let own = Lane_addon_store.root store in
  match List.find_opt (fun found -> not (String.equal found own)) roots with
  | None -> Ok ()
  | Some found ->
    Error (Printf.sprintf "%s names the store root %s, and this check reads %s" path found own)

let json_names names =
  List.filter
    (fun name ->
       match json_entry name with
       | Record -> true
       | Skipped | Refused _ -> false)
    names

type keyed_record =
  { record_path : string
  ; first : Yojson.Safe.t
  ; key : Exact.Retained_key.t
  }

(* The first read of an Exact record. [run] reads the record of a request at
   the path its declaration and request ID name, and compares the ids the
   record holds. A record whose ids name another path is refused alone: the
   proof link and observations its ids name belong to the record at that
   path. *)
let read_first ~after_read ~group ~name path =
  read_file ~after_read ~delete:record_alone ~path (fun first ->
    let* ({ Exact.Retained_key.declaration_id; request_id; _ } as key) =
      decoded Exact_record (Exact.Retained_key.of_record first)
    in
    let stored =
      Filename.concat Lane_addon_store.exact_requests_directory (Filename.concat group name)
    in
    if String.equal stored (Lane_addon_store.exact_request_path ~declaration_id ~request_id)
    then Ok { record_path = path; first; key }
    else Error (Exact_record, "retained Exact record is stored under another request's key"))

(* The slot observations of one declaration, read once with the startup
   sweep's read: the request each file belongs to. The sweep stops at a file
   it cannot read, so the check refuses that file. *)
let read_slot_observations store ~root report ~declaration_id =
  let dir = Filename.concat root (Exact_observation.directory ~declaration_id) in
  let* names = entries dir in
  let* owned, report =
    List.fold_left
      (fun state name ->
         let* owned, report = state in
         let path = Filename.concat dir name in
         match read_file ~after_read:ignore ~delete:record_alone ~path Result.ok with
         | Gone -> Ok (owned, report)
         | Unreadable refusal -> Ok (owned, refused report refusal)
         | Read json ->
           let* () = same_store store ~path (Option.to_list (Exact_observation.store_root json)) in
           (match Exact_observation.request_id ~store ~declaration_id ~file_name:name json with
            | Ok request_id -> Ok ((request_id, path) :: owned, counted report)
            | Error _ when removed path -> Ok (owned, report)
            | Error detail ->
              Ok
                ( owned
                , refused
                    report
                    { path; decoder = Exact_slot_observation; detail; delete = record_alone path } )))
      (Ok ([], report))
      (json_names names)
  in
  Ok (List.rev owned, report)

(* One record with its proof link: the record, the link, then the record
   again. Fresh state deletes a refused record with its link and the slot
   observations of its request: [run] reads that link with the record, and the
   observations are read with that link. *)
let check_record store ~root ~observations report { record_path; first; key } =
  let link = Filename.concat root (Exact.Retained_key.proof_path key) in
  let { Exact.Retained_key.request_id; _ } = key in
  let delete _ =
    let observed =
      List.filter_map
        (fun (owner, file) -> if String.equal owner request_id then Some file else None)
        observations
    in
    record_path :: List.filter exists (link :: observed)
  in
  let read_second proof =
    match
      read_file ~after_read:ignore ~delete ~path:record_path (fun second ->
        decoded Exact_record (Exact.check_retained_record ~store ~first ~proof ~second))
    with
    | Gone -> Ok report
    | Unreadable refusal -> Ok (refused report refusal)
    | Read () -> Ok (counted report)
  in
  match read_file ~after_read:ignore ~delete ~path:link Result.ok with
  | Gone -> read_second None
  | Unreadable refusal -> Ok (refused report refusal)
  | Read proof ->
    let* () = same_store store ~path:link (Exact.proof_store_roots proof) in
    read_second (Some proof)

(* The proof links of one declaration that no record names. The server writes
   a record before its link, so the records are listed again after the links:
   a record written in between names its link too. A link removed before it is
   refused is not refused. *)
let unnamed_proof_links ~root report ~group ~group_dir ~declaration_id ~listed ~named =
  let dir = Filename.concat root (Exact.proof_directory ~declaration_id) in
  let* links = entries dir in
  let* again = entries group_dir in
  let link_name key = Filename.basename (Exact.Retained_key.proof_path key) in
  let later =
    List.filter_map
      (fun name ->
         if List.mem name listed
         then None
         else
           match read_first ~after_read:ignore ~group ~name (Filename.concat group_dir name) with
           | Read { key; _ } -> Some (link_name key)
           | Gone | Unreadable _ -> None)
      (json_names again)
  in
  let named = List.map (fun { key; _ } -> link_name key) named @ later in
  Ok
    (List.fold_left
       (fun report link ->
          let path = Filename.concat dir link in
          if List.mem link named || not (exists path)
          then report
          else
            refused
              report
              { path
              ; decoder = Exact_proof_link
              ; detail = "no retained record names this original execution link"
              ; delete = [ path ]
              })
       report
       (json_names links))

(* Exact requests (RFC exact-request-skips-a-slot-that-refused-its-input 3.3).
   Per declaration the check reads every record once, the slot observations,
   each record's proof link and the record again, then the proof links no
   record names. The declaration comes from a record whose ids name its own
   path; the links of a declaration none of whose records can be read are not
   found. *)
let scan_exact_declaration ~after_read store ~root report ~group ~group_dir =
  let* listed = entries group_dir in
  let records = json_names listed in
  let report, keyed =
    List.fold_left
      (fun (report, keyed) name ->
         match read_first ~after_read ~group ~name (Filename.concat group_dir name) with
         | Gone -> report, keyed
         | Unreadable refusal -> refused report refusal, keyed
         | Read record -> report, record :: keyed)
      (report, [])
      records
  in
  match List.rev keyed with
  | [] -> Ok report
  | { key = { Exact.Retained_key.declaration_id; _ }; _ } :: _ as keyed ->
    let* observations, report = read_slot_observations store ~root report ~declaration_id in
    let* report =
      List.fold_left
        (fun report record ->
           let* report = report in
           check_record store ~root ~observations report record)
        (Ok report)
        keyed
    in
    unnamed_proof_links ~root report ~group ~group_dir ~declaration_id ~listed:records ~named:keyed

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
      scan_groups root Lane_addon_store.exact_requests_directory
        (scan_exact_declaration ~after_read (Lane_addon_store.create ~root) ~root)
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
