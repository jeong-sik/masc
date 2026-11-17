module Owner = Lane_addon_tool_request_owner
module Original = Keeper_media_reading_original
open Result.Syntax

type error =
  | Store_error of Owner.error
  | Invalid_original of Original.error
  | Store_workspace_mismatch of { expected : string; actual : string }

let error_to_string = function
  | Store_error error -> Owner.error_to_string error
  | Invalid_original error -> Original.error_to_string error
  | Store_workspace_mismatch { expected; actual } ->
    Printf.sprintf "media original store belongs to another workspace: expected %s, got %s"
      expected actual

let scope = "keeper-media-reading-originals"
let installation_id = Owner.installation_id (Owner.Manual "keeper-media-reader-host")
let package_id = "keeper-media-reader"
let tool = "read"

type retained = { record : Owner.retained; original : Original.t }
let record retained = retained.record
let original retained = retained.original
type inventory = retained list
let originals inventory = inventory

let stored result = Result.map_error (fun error -> Store_error error) result
let captured result = Result.map_error (fun error -> Invalid_original error) result
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
  match Keeper_media_reading_approval.validate_progress ~original record.progress with
  | Ok () -> Ok { record; original }
  | Error detail -> invalid detail

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
