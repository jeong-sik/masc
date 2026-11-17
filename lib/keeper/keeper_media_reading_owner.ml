module Owner = Lane_addon_tool_request_owner
module Original = Keeper_media_reading_original
module Reply = Keeper_media_reading_reply
module Progress = Lane_addon_request_progress
open Result.Syntax

type error =
  | Store_error of Owner.error
  | Invalid_original of Original.error
  | Store_workspace_mismatch of { expected : string; actual : string }
  | Invalid_reply of string
  | Reply_blob_missing of string
  | Reply_blob_unavailable of Tool_blob_store.fetch_error
  | Reply_blob_write_failed of string
  | Reply_update_error of Owner.update_error

let error_to_string = function
  | Store_error error -> Owner.error_to_string error
  | Invalid_original error -> Original.error_to_string error
  | Store_workspace_mismatch { expected; actual } ->
    Printf.sprintf "media original store belongs to another workspace: expected %s, got %s"
      expected actual
  | Invalid_reply detail -> "invalid media reply: " ^ detail
  | Reply_blob_missing sha256 -> "retained media reply blob is missing: " ^ sha256
  | Reply_blob_unavailable error -> Tool_blob_store.fetch_error_to_string error
  | Reply_blob_write_failed detail -> "media reply blob publication failed: " ^ detail
  | Reply_update_error error -> Owner.update_error_to_string error

let scope = "keeper-media-reading-originals"
let installation_id = Owner.installation_id (Owner.Manual "keeper-media-reader-host")
let package_id = "keeper-media-reader"
let tool = "read"

type retained = {
  record : Owner.retained;
  original : Original.t;
  reply_link : Reply.link option;
}
let record retained = retained.record
let original retained = retained.original
type inventory = retained list
let originals inventory = inventory

let stored result = Result.map_error (fun error -> Store_error error) result
let captured result = Result.map_error (fun error -> Invalid_original error) result
let replied result = Result.map_error (fun detail -> Invalid_reply detail) result
let invalid detail = Error (Invalid_original (Original.Invalid_binding detail))

let check_header ~stored_scope ~stored_installation ~stored_package ~stored_tool =
  if String.equal stored_scope scope
     && String.equal stored_installation installation_id
     && String.equal stored_package package_id
     && String.equal stored_tool tool
  then Ok ()
  else invalid "media original has a different host scope, installation, package or tool"

let restore (record : Owner.retained) =
  let* () = check_header ~stored_scope:record.scope
      ~stored_installation:record.installation_id ~stored_package:record.package_id
      ~stored_tool:record.tool in
  let* original = captured (Original.restore record) in
  let* () = Keeper_media_reading_approval.validate_progress ~original record.progress
      |> Result.map_error (fun detail -> Invalid_original (Original.Invalid_binding detail)) in
  let+ reply_link = replied (Reply.validate_progress ~original record.progress) in
  { record; original; reply_link }

let check_retained record =
  restore record |> Result.map (fun _ -> ()) |> Result.map_error error_to_string

let check_store ~store owner =
  let expected = Lane_addon_store.directory
      ~masc_dir:(Config_dir_resolver.masc_root ~base_path:(Original.owner_base_path owner)) in
  let actual = Lane_addon_store.root store in
  if String.equal expected actual then Ok ()
  else Error (Store_workspace_mismatch { expected; actual })

let observe_subject ~store subject =
  let* owner = captured (Original.observe_owner
      ~base_path:(Original.subject_base_path subject)
      ~keeper_name:(Original.subject_keeper_name subject)) in
  let* () = check_store ~store owner in
  let+ () = captured (Original.check_workspace owner subject) in
  owner

let check_current ~store ~keeper_name retained =
  let subject = Original.original_subject retained.original in
  let* _owner = observe_subject ~store subject in
  if String.equal keeper_name (Original.subject_keeper_name subject) then Ok ()
  else invalid "media original belongs to another Keeper"

let refresh_owner ~store owner =
  let* current = captured (Original.observe_owner
      ~base_path:(Original.owner_base_path owner)
      ~keeper_name:(Original.owner_keeper_name owner)) in
  let* () = captured (Original.check_owner ~expected:owner current) in
  let+ () = check_store ~store current in
  current

let load ~store ~owner ~request_id =
  let* owner = refresh_owner ~store owner in
  let* loaded = stored (Owner.load ~store ~scope ~request_id) in
  match loaded with
  | None ->
    (* The observation still belongs to the requested workspace, even when
       there is no record whose subject could be checked. *)
    let+ _current = refresh_owner ~store owner in
    None
  | Some record ->
    let* retained = restore record in
    let subject = Original.original_subject retained.original in
    let* () = captured (Original.check_workspace owner subject) in
    let+ () = check_current ~store ~keeper_name:(Original.owner_keeper_name owner) retained in
    Some retained

let retain ~store original =
  let subject = Original.original_subject original in
  let* owner = observe_subject ~store subject in
  let request_id = Original.request_id original in
  let* () = stored (Owner.retain ~store ~scope ~request_id
      ~installation_id ~package_id ~tool ~summary:(Original.summary original)
      ~request:(Original.to_json original)) in
  let* loaded = load ~store ~owner ~request_id in
  match loaded with
  | Some retained -> Ok retained
  | None -> Error (Store_error (Owner.Store_unavailable
      "media original disappeared after retention"))

type reply_publication =
  | Stored of retained
  | Already_stored of retained
  | Unconfirmed of string

let current_retained ~store (expected : retained) =
  let subject = Original.original_subject expected.original in
  let* owner = observe_subject ~store subject in
  let* current = load ~store ~owner ~request_id:expected.record.request_id in
  match current with
  | None -> Error (Store_error (Owner.Store_unavailable
      "media original disappeared before reply observation"))
  | Some current ->
    (* The body was read and restored above. Reuse the common owner's exact
       immutable-binding comparison; only progress may differ. *)
    (match Owner.rebind expected.record (Owner.listed current.record) with
     | None -> Error (Store_error Owner.Binding_conflict)
     | Some _ ->
       if List_util.is_prefix ~equal:( = )
           (Progress.events expected.record.progress)
           (Progress.events current.record.progress)
       then Ok current
       else Error (Reply_update_error Owner.State_conflict))

let blob_store (retained : retained) =
  Tool_blob_store.create
    ~base_path:(Original.subject_base_path (Original.original_subject retained.original))

let fetch_reply (retained : retained) link =
  let artifact = Reply.artifact link in
  let* bytes = Tool_blob_store.fetch (blob_store retained) ~sha256:artifact.sha256
      |> Result.map_error (fun error -> Reply_blob_unavailable error) in
  match bytes with
  | None -> Error (Reply_blob_missing artifact.sha256)
  | Some bytes ->
    if String.length bytes <> artifact.bytes then
      Error (Invalid_reply "retained blob byte length differs from its reply link")
    else replied (Reply.restore_reply_bytes bytes)

let load_reply ~store retained =
  let* current = current_retained ~store retained in
  let* reply = match current.reply_link with
    | None -> Ok None
    | Some link -> Result.map Option.some (fetch_reply current link) in
  (* Keep the observation tied to the original physical workspace even when
     fetching the blob yielded control to another fiber. *)
  let+ () = check_current ~store
      ~keeper_name:(Original.subject_keeper_name
        (Original.original_subject current.original)) current in
  reply

let reply_conflict () = Error (Reply_update_error Owner.State_conflict)

let retain_reply_with ~put_blob ~advance_events ~store ~(expected : retained) ~reply =
  let* current = current_retained ~store expected in
  match current.reply_link with
  | Some link ->
    let* existing = fetch_reply current link in
    let* () = check_current ~store
        ~keeper_name:(Original.subject_keeper_name
          (Original.original_subject current.original)) current in
    if String.equal (Reply.reply_bytes existing) (Reply.reply_bytes reply)
    then Ok (Already_stored current)
    else reply_conflict ()
  | None ->
    if not (Owner.same_record expected.record current.record) then reply_conflict ()
    else
      let* () = match Progress.phase current.record.progress with
        | Progress.Dispatch_pending _ -> Ok ()
        | Captured | Admission_wait _ | Judged _ | Committing _ | Commit_unknown _
        | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ ->
          Error (Reply_update_error (Owner.Invalid_transition
            "media reply requires the original dispatch-pending record")) in
      (* Only this durable blob boundary catches Sys_error. The canonical
         returned SDK value remains with the caller on failure; no RPC runs. *)
      let* artifact =
        try Ok (put_blob (blob_store current)
          ~bytes:(Reply.reply_bytes reply) ~mime:Reply.mime_type)
        with Sys_error detail -> Error (Reply_blob_write_failed detail) in
      let* link = replied (Reply.link ~original:current.original
          (Tool_output.with_preview artifact "")) in
      let* () = check_current ~store
          ~keeper_name:(Original.subject_keeper_name
            (Original.original_subject current.original)) current in
      let* published = advance_events ~store ~expected:current.record
          ~events:[Progress.Judgment_retained (Reply.link_to_json link)]
          |> Result.map_error (fun error -> Reply_update_error error) in
      let* () = check_current ~store
          ~keeper_name:(Original.subject_keeper_name
            (Original.original_subject current.original)) current in
      match published with
      | Owner.Unconfirmed detail -> Ok (Unconfirmed detail)
      | Owner.Stored record -> Result.map (fun retained -> Stored retained) (restore record)
      | Owner.Already_stored record ->
        Result.map (fun retained -> Already_stored retained) (restore record)

let retain_reply ~store ~expected ~reply =
  retain_reply_with ~put_blob:Tool_blob_store.put_durable
    ~advance_events:Owner.advance_events ~store ~expected ~reply

module For_testing = struct
  let retain_reply ?(put_blob = Tool_blob_store.put_durable)
      ?(save = Lane_addon_store.save_tool_request_owner) ~store ~expected ~reply () =
    retain_reply_with ~put_blob ~advance_events:(Owner.For_testing.advance_events ~save)
      ~store ~expected ~reply
end

let discover_subject ~store subject =
  let* owner = observe_subject ~store subject in
  let* records = stored (Owner.discover ~store ~scope) in
  (* Check every summary before filtering. A new workspace identity or reader
     configuration must not turn a retained unknown original into absence. *)
  let* () = List.fold_left (fun checked record ->
    let* () = checked in
    let* () = check_header ~stored_scope:(Owner.Record.scope record)
        ~stored_installation:(Owner.Record.installation_id record)
        ~stored_package:(Owner.Record.package_id record)
        ~stored_tool:(Owner.Record.tool record) in
    let* indexed_subject = captured (Original.summary_subject
        ~request_id:(Owner.Record.request_id record)
        ~request_digest:(Owner.Record.request_digest record)
        (Owner.Record.summary record)) in
    captured (Original.check_workspace owner indexed_subject)) (Ok ()) records in
  (* Metadata alone cannot prove which subject a body names. Even a summary
     with valid IDs/digests can change its subject; restore every live body
     before selecting so such an edit cannot hide an earlier execution. *)
  let* retained = List.fold_left (fun retained record ->
    let* retained = retained in
    let* record = stored (Owner.load_listed ~store record) in
    let* item = restore record in
    let original_subject = Original.original_subject item.original in
    let* () = captured (Original.check_workspace owner original_subject) in
    if Original.same_subject subject original_subject
    then Ok (item :: retained)
    else Ok retained) (Ok []) records in
  let+ _owner = observe_subject ~store subject in
  List.rev retained
