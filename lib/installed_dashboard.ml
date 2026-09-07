type error =
  | Invalid_receipt
  | Receipt_identity_mismatch
  | Binary_commit_unavailable
  | Binary_commit_mismatch of { expected : string; actual : string }
  | Digest_mismatch of { path : string; expected : string; actual : string }
  | Size_mismatch of string
  | Exact_read_failed of string
  | Root_identity_changed
  | Not_manifested

type entry = { path : string; sha256 : string; size : int; mtime : float }
type receipt = { source_commit : string; binary_sha256 : string; files : entry list }
type binding =
  { root : string; device : int; inode : int; receipt_sha256 : string
  ; receipt : receipt; binary_snapshot : Fs_compat.owned_regular_file_snapshot }
type selection = Not_installed | Unavailable of error | Bound of binding

let ( let* ) = Result.bind
let sha256 body = Digestif.SHA256.(digest_string body |> to_hex)
let hex length value =
  String.length value = length
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) value
let safe_path path =
  path <> "" && Filename.is_relative path
  && not (String.contains path '\\') && not (String.contains path '\000')
  && List.for_all (fun s -> s <> "" && s <> "." && s <> "..")
       (String.split_on_char '/' path)
let fields keys = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)
                      = List.sort String.compare keys -> Ok fields
  | _ -> Error Invalid_receipt
let string key fields =
  match List.assoc_opt key fields with Some (`String s) -> Ok s | _ -> Error Invalid_receipt
let parse_entry json =
  let* f = fields ["path"; "sha256"; "size"; "mtime"] json in
  let* path = string "path" f in
  let* sha256 = string "sha256" f in
  let* size = match List.assoc_opt "size" f with
    | Some (`Int n) when n >= 0 -> Ok n | _ -> Error Invalid_receipt in
  let* mtime = match List.assoc_opt "mtime" f with
    | Some (`Float n) when Float.is_finite n && n >= 0. -> Ok n
    | Some (`Int n) when n >= 0 -> Ok (float_of_int n)
    | _ -> Error Invalid_receipt in
  (* Health renders RFC3339 civil time. A finite float alone does not prove
     representability; Ptime owns the supported civil-time range. *)
  let* () = match Ptime.of_float_s mtime with
    | Some _ -> Ok () | None -> Error Invalid_receipt in
  if safe_path path && hex 64 sha256 then Ok {path; sha256; size; mtime}
  else Error Invalid_receipt
let parse body =
  let* json = try Ok (Yojson.Safe.from_string body) with
    | Yojson.Json_error _ -> Error Invalid_receipt in
  let* f = fields ["schema"; "source_commit"; "binary_asset"; "binary_sha256"; "files"] json in
  let* schema = string "schema" f in
  let* source_commit = string "source_commit" f in
  let* binary_sha256 = string "binary_sha256" f in
  let* binary_asset = string "binary_asset" f in
  let* files = match List.assoc_opt "files" f with
    | Some (`List files) ->
      List.fold_left (fun result json ->
        let* acc = result in
        let* entry = parse_entry json in
        if List.exists (fun old -> old.path = entry.path) acc then Error Invalid_receipt
        else Ok (entry :: acc)) (Ok []) files
    | _ -> Error Invalid_receipt in
  if schema = "masc.installed-release.v1" && hex 40 source_commit
     && hex 64 binary_sha256
     && List.mem binary_asset ["masc-macos-arm64"; "masc-macos-x64"; "masc-linux-x64"; "masc-linux-arm64"]
     && List.for_all (fun name -> List.exists (fun e -> e.path = name) files)
          ["index.html"; ".build-stamp"]
  then Ok {source_commit; binary_sha256; files}
  else Error Invalid_receipt

let build_stamp_mtime b =
  Option.map (fun e -> e.mtime)
    (List.find_opt (fun e -> e.path = ".build-stamp") b.receipt.files)
let assets_root b = Filename.concat b.root "assets"
let dashboard_root b = Filename.concat (assets_root b) "dashboard"
let asset_path b relative =
  Option.map (fun e -> Filename.concat (dashboard_root b) e.path)
    (List.find_opt (fun e -> e.path = relative) b.receipt.files)
let read root path =
  match Fs_compat.load_owned_regular_file_with_snapshot ~ownership_root:root path with
  | Ok (Some contents) -> Ok contents
  | Ok None | Error _ -> Error (Exact_read_failed path)
let root_matches b =
  try
    let info = Unix.lstat b.root in
    info.Unix.st_kind = Unix.S_DIR && info.st_uid = Unix.geteuid ()
    && info.st_dev = b.device && info.st_ino = b.inode
    && String.equal (Unix.realpath b.root) b.root
  with Unix.Unix_error _ -> false
let check_digest path expected body =
  let actual = sha256 body in
  if actual = expected then Ok () else Error (Digest_mismatch {path; expected; actual})
let binary_unchanged b =
  let path = Filename.concat b.root "masc" in
  try
    let stat = Unix.lstat path in
    let snapshot = b.binary_snapshot in
    stat.st_kind = Unix.S_REG && stat.st_dev = snapshot.device
    && stat.st_ino = snapshot.inode && stat.st_uid = snapshot.owner_uid
    && stat.st_perm = snapshot.permissions && stat.st_size = snapshot.file_size
    && stat.st_mtime = snapshot.modified_at && stat.st_ctime = snapshot.changed_at
  with Unix.Unix_error _ -> false
let check_binding b =
  let* () = if binary_unchanged b then Ok ()
    else Error (Exact_read_failed "installed binary identity changed") in
  if not (root_matches b) then Error Root_identity_changed else
  let path = Filename.concat b.root "release.json" in
  let* contents = read b.root path in
  let* () = check_digest path b.receipt_sha256 contents.content in
  if root_matches b then Ok () else Error Root_identity_changed
let read_entry b entry =
  let path = Filename.concat (dashboard_root b) entry.path in
  let* contents = read b.root path in
  let* () = if String.length contents.content = entry.size then Ok ()
    else Error (Size_mismatch entry.path) in
  let* () = check_digest entry.path entry.sha256 contents.content in
  Ok contents.content
let load b relative =
  let* () = check_binding b in
  let* entry = match List.find_opt (fun e -> e.path = relative) b.receipt.files with
    | Some entry -> Ok entry | None -> Error Not_manifested in
  let* body = read_entry b entry in
  let* () = check_binding b in
  Ok body

let inspect ~executable_path ~binary_commit =
  let root = Filename.dirname executable_path in
  (* This is the install format discriminator, not a guessed source root.
     Missing/corrupt receipts inside it are selected failures. *)
  if Filename.basename (Filename.dirname root) <> ".masc-releases" then Not_installed
  else
    let result =
      let* info = try Ok (Unix.lstat root) with
        | Unix.Unix_error _ -> Error Root_identity_changed in
      let* () = if info.st_kind = Unix.S_DIR && info.st_uid = Unix.geteuid ()
        && Filename.basename executable_path = "masc" then Ok ()
        else Error Root_identity_changed in
      let* contents = read root (Filename.concat root "release.json") in
      let receipt_sha256 = sha256 contents.content in
      let* () = if receipt_sha256 = Filename.basename root then Ok ()
        else Error Receipt_identity_mismatch in
      let* receipt = parse contents.content in
      let* actual = match binary_commit with Some c -> Ok c | None -> Error Binary_commit_unavailable in
      let* () = if actual = receipt.source_commit then Ok ()
        else Error (Binary_commit_mismatch {expected = receipt.source_commit; actual}) in
      let* binary = read root executable_path in
      let* () = check_digest "masc" receipt.binary_sha256 binary.content in
      let b = {root; device = info.st_dev; inode = info.st_ino; receipt_sha256; receipt; binary_snapshot = binary.snapshot} in
      (* Pin the receipt/root/binary around the complete startup scan. Re-reading
         the full receipt twice per file would make manifest I/O quadratic. *)
      let* () = check_binding b in
      let* () = List.fold_left (fun result entry ->
        let* () = result in Result.map (fun _ -> ()) (read_entry b entry))
          (Ok ()) receipt.files in
      let* () = check_binding b in
      Ok b
    in
    match result with Ok b -> Bound b | Error e -> Unavailable e

(* Initialized before Eio fibers start; no I/O occurs inside Atomic operations.
   Never resolve the install pointer again while this process is running. *)
let selected = Atomic.make None
let initialize ~executable_path ~binary_commit =
  match Atomic.get selected with
  | Some _ -> ()
  | None -> Atomic.set selected (Some (inspect ~executable_path ~binary_commit))
let current () = Option.value ~default:Not_installed (Atomic.get selected)

let error_json error =
  let kind, detail = match error with
    | Invalid_receipt -> "invalid_receipt", []
    | Receipt_identity_mismatch -> "receipt_identity_mismatch", []
    | Binary_commit_unavailable -> "binary_commit_unavailable", []
    | Binary_commit_mismatch {expected; actual} -> "binary_commit_mismatch",
        ["expected", `String expected; "actual", `String actual]
    | Digest_mismatch {path; expected; actual} -> "digest_mismatch",
        ["path", `String path; "expected", `String expected; "actual", `String actual]
    | Size_mismatch path -> "size_mismatch", ["path", `String path]
    | Exact_read_failed path -> "exact_read_failed", ["path", `String path]
    | Root_identity_changed -> "root_identity_changed", []
    | Not_manifested -> "not_manifested", [] in
  `Assoc (("kind", `String kind) :: detail)
let evidence = function
  | Not_installed -> `Null
  | Unavailable e -> `Assoc ["kind", `String "installed_release";
      "status", `String "unavailable"; "error", error_json e]
  | Bound b -> `Assoc ["kind", `String "installed_release";
      "status", `String "verified"; "receipt_sha256", `String b.receipt_sha256;
      "release_root", `String b.root; "source_commit", `String b.receipt.source_commit;
      "binary_sha256", `String b.receipt.binary_sha256;
      "file_count", `Int (List.length b.receipt.files);
      "build_stamp_mtime", (match build_stamp_mtime b with
        | Some mtime -> `Float mtime | None -> `Null)]
