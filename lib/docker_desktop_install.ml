type error = Unsupported_host | Invalid_checksum | Download_failed | Invalid_file
  | Digest_mismatch | Signature_rejected | Mount_failed | Installer_failed
  | Invalid_completion | Cleanup_required of string
type runner = string list -> (string, unit) result
type verified_artifact = {directory:string; path:string; sha256:string; size:int; url:string; version:string}
type cleanup = Cleaned | Pending of string
type completion = { cleanup : cleanup }
type action_result = { completion : completion; service : Sandbox_readiness.entry }
let ( let* ) = Result.bind
let publisher = "Developer ID Application: Docker Inc (9BNSXJN65R)"
(* Explicit trust anchor measured from official Docker 4.90.0/238679 macOS ARM
   DMG; see docs/evidence/prerequisite-installers/docker-desktop-4.90.0.json. *)
let requirement = "=anchor apple generic and identifier \"com.docker.docker\" and certificate leaf[subject.OU] = \"9BNSXJN65R\""
let valid_sha value = String.length value = 64 && String.for_all (function '0'..'9'|'a'..'f' -> true | _ -> false) value
let checksum body =
  let matches = String.split_on_char '\n' body |> List.filter_map (fun line ->
    match String.split_on_char ' ' (String.trim line) |> List.filter (fun field -> field <> "") with
    | [digest; ("*Docker.dmg" | "Docker.dmg")] -> Some digest
    | _ -> None) in
  match matches with [digest] when valid_sha digest -> Ok digest | _ -> Error Invalid_checksum
let architecture = function
  | Sandbox_readiness.Macos {architecture=Arm64;_} -> Ok "arm64"
  | Sandbox_readiness.Macos {architecture=X64;_} -> Ok "amd64"
  | Linux _ | Unsupported -> Error Unsupported_host
let same_file a b =
  a.Unix.st_dev=b.Unix.st_dev && a.st_ino=b.st_ino && a.st_kind=b.st_kind
  && a.st_uid=b.st_uid && a.st_perm=b.st_perm && a.st_size=b.st_size
  && a.st_mtime=b.st_mtime && a.st_ctime=b.st_ctime
let file_digest path =
  try
    let before = Unix.lstat path in
    if before.st_kind <> Unix.S_REG || before.st_uid <> Unix.geteuid () || before.st_perm land 0o077 <> 0
    then Error Invalid_file else
    In_channel.with_open_bin path (fun input ->
      let opened = Unix.fstat (Unix.descr_of_in_channel input) in
      if not (same_file before opened) then Error Invalid_file else
      let buffer = Bytes.create 65536 in
      let rec read hash = match In_channel.input input buffer 0 (Bytes.length buffer) with
        | 0 ->
          if not (same_file opened (Unix.fstat (Unix.descr_of_in_channel input)))
            || not (same_file opened (Unix.lstat path)) then Error Invalid_file
          else Ok (Digestif.SHA256.(to_hex (get hash)), opened.st_size)
        | count -> read (Digestif.SHA256.feed_string hash (Bytes.sub_string buffer 0 count)) in
      read Digestif.SHA256.empty)
  with Sys_error _ | Unix.Unix_error _ -> Error Invalid_file
let verify_digest ~path ~sha256 ~size =
  let* actual, actual_size = file_digest path in
  if actual=sha256 && actual_size=size then Ok () else Error Digest_mismatch
let verify_app ~run app =
  let* _ = run ["/usr/bin/codesign";"--verify";"--deep";"--strict";"-R";requirement;app]
    |> Result.map_error (fun () -> Signature_rejected) in
  let* _ = run ["/usr/sbin/spctl";"--assess";"--type";"execute";app]
    |> Result.map_error (fun () -> Signature_rejected) in
  Ok ()
let remove_empty path =
  try Unix.rmdir path; true with Unix.Unix_error (Unix.ENOENT,_,_) -> true | Unix.Unix_error _ -> false
let mounted ~run ~directory ~path f =
  let mount = Filename.concat directory "volume" in
  Unix.mkdir mount 0o700;
  let cleaned = ref false in
  let result = Fun.protect ~finally:(fun () ->
    ignore (run ["/usr/bin/hdiutil";"detach";mount]);
    (* Never recursively remove a failed/unconfirmed mount. *)
    cleaned := remove_empty mount)
    (fun () ->
      let* _ = run ["/usr/bin/hdiutil";"attach";"-readonly";"-nobrowse";"-mountpoint";mount;path]
        |> Result.map_error (fun () -> Mount_failed) in
      try
        let app = Filename.concat mount "Docker.app" in
        let installer = Filename.concat app "Contents/MacOS/install" in
        let resolved_installer = Unix.realpath installer in
        (* The read-only image must contain the app and executable. A symlink
           into a user-writable host directory would defeat protected staging. *)
        if (Unix.lstat app).st_kind <> Unix.S_DIR || Unix.realpath app <> app
          || not (String.starts_with ~prefix:(app ^ "/") resolved_installer)
          || (Unix.stat resolved_installer).st_kind <> Unix.S_REG
        then Error Invalid_file else f app
      with Sys_error _ | Unix.Unix_error _ -> Error Invalid_file) in
  result, !cleaned
let cleanup_directory ~directory ~path =
  (try Sys.remove path with Sys_error _ -> ());
  ignore (remove_empty directory)
let acquire ~host ~run =
  let* arch = architecture host in
  let base = "https://desktop.docker.com/mac/main/" ^ arch ^ "/" in
  let* body = run ["/usr/bin/curl";"--fail";"--silent";"--show-error";"--proto";"=https";base ^ "checksums.txt"]
    |> Result.map_error (fun () -> Download_failed) in
  let* sha256 = checksum body in
  try
    let directory = Filename.temp_dir "masc-docker-desktop-" "" |> Unix.realpath in
    let path = Filename.concat directory "Docker.dmg" in
    let preserve = ref false in
    Fun.protect ~finally:(fun () -> if not !preserve then cleanup_directory ~directory ~path) (fun () ->
      let output = open_out_gen [Open_creat;Open_excl;Open_wronly;Open_binary] 0o600 path in
      close_out output;
      let url = base ^ "Docker.dmg" in
      let* _ = run ["/usr/bin/curl";"--fail";"--silent";"--show-error";"--location";
        "--proto";"=https";"--proto-redir";"=https";"--output";path;url]
        |> Result.map_error (fun () -> Download_failed) in
      let* actual,size = file_digest path in
      if actual <> sha256 || size <= 0 then Error Digest_mismatch else
      preserve := true;
      let result, cleaned = mounted ~run ~directory ~path (fun app ->
        let* () = verify_app ~run app in
        let* version = run ["/usr/bin/plutil";"-extract";"CFBundleShortVersionString";"raw";
          Filename.concat app "Contents/Info.plist"] |> Result.map_error (fun () -> Invalid_file) in
        let version = String.trim version in
        if version="" || not (String.for_all (function '0'..'9'|'.' -> true | _ -> false) version)
        then Error Invalid_file else Ok {directory;path;sha256;size;url;version}) in
      if not cleaned then Error (Cleanup_required directory) else
      match result with Ok artifact -> Ok artifact | Error _ as error -> preserve := false; error)
  with Sys_error _ | Unix.Unix_error _ -> Error Invalid_file
let remove artifact = cleanup_directory ~directory:artifact.directory ~path:artifact.path
let to_json artifact = `Assoc ["schema",`String "masc.verified_prerequisite.v1";
  "backend",`String "docker";"version",`String artifact.version;
  "source_url",`String artifact.url;"sha256",`String artifact.sha256;
  "publisher",`String publisher;"platform_signature",`String "accepted";
  "status",`String "verified_download";"installation",`String "not_attested";
  "sandbox_readiness",`String "not_checked"]
let completion_to_json completion = `Assoc ["schema",`String "masc.docker_install_completion.v1";
  "installation",`String "completed";
  "cleanup",(match completion.cleanup with Cleaned -> `Assoc ["state",`String "cleaned"]
    | Pending directory -> `Assoc ["state",`String "pending";"directory",`String directory]);
  "license",`String "not_accepted_by_masc";"sandbox_readiness",`String "not_checked"]
let install_staged ~temp_dir ~run ~source ~sha256 ~size =
  if not (valid_sha sha256) || size <= 0 then Error Invalid_checksum else
  try
    let directory = Filename.temp_dir ~temp_dir "masc-root-docker-" "" |> Unix.realpath in
    let path = Filename.concat directory "Docker.dmg" in
    let cleanup = ref true in
    Fun.protect ~finally:(fun () -> if !cleanup then cleanup_directory ~directory ~path) (fun () ->
      let output = open_out_gen [Open_creat;Open_excl;Open_wronly;Open_binary] 0o600 path in
      Fun.protect ~finally:(fun () -> close_out_noerr output) (fun () ->
        In_channel.with_open_bin source (fun input ->
          let buffer = Bytes.create 65536 in
          let rec copy remaining =
            let count = In_channel.input input buffer 0 (min remaining (Bytes.length buffer)) in
            if count <> 0 then (output_bytes output (Bytes.sub buffer 0 count); copy (remaining-count)) in
          copy size;
          if In_channel.input_char input <> None then raise (Sys_error "larger than selected artifact"));
        close_out output);
      let* () = verify_digest ~path ~sha256 ~size in
      cleanup := false;
      let result, cleaned = mounted ~run ~directory ~path (fun app ->
        let* () = verify_app ~run app in
        let* _ = run [Filename.concat app "Contents/MacOS/install"]
          |> Result.map_error (fun () -> Installer_failed) in
        Ok ()) in
      cleanup := cleaned;
      match result with
      | Ok () -> Ok {cleanup=(if cleaned then Cleaned else Pending directory)}
      | Error error -> if cleaned then Error error else Error (Cleanup_required directory))
  with Sys_error _ | Unix.Unix_error _ -> Error Invalid_file
let install_privileged ~run ~source ~sha256 ~size =
  if Unix.geteuid () <> 0 then Error Installer_failed else
  (* Root-owned sticky system directory: inherited TMPDIR may be user-controlled. *)
  install_staged ~temp_dir:"/private/tmp" ~run ~source ~sha256 ~size
let completion_of_output output =
  try match Yojson.Safe.from_string output with
    | `Assoc fields when List.length fields = 5 &&
      List.assoc_opt "schema" fields = Some (`String "masc.docker_install_completion.v1") &&
      List.assoc_opt "installation" fields = Some (`String "completed") &&
      List.assoc_opt "license" fields = Some (`String "not_accepted_by_masc") &&
      List.assoc_opt "sandbox_readiness" fields = Some (`String "not_checked") ->
      (match List.assoc_opt "cleanup" fields with
       | Some (`Assoc ["state", `String "cleaned"]) -> Ok {cleanup=Cleaned}
       | Some (`Assoc [("state", `String "pending"); ("directory", `String directory)])
         when not (Filename.is_relative directory) -> Ok {cleanup=Pending directory}
       | _ -> Error Invalid_completion)
    | _ -> Error Invalid_completion
  with Yojson.Json_error _ -> Error Invalid_completion
let install ~executable_path ~run ~host ~probe_run ~require_rootless ~require_userns artifact =
  let* _ = architecture host in
  let* () = verify_digest ~path:artifact.path ~sha256:artifact.sha256 ~size:artifact.size in
  try
    let executable_path = Unix.realpath executable_path in
    let* output = run ["/usr/bin/sudo";executable_path;"sandbox-install-docker-verified";
      "--source";artifact.path;"--sha256";artifact.sha256;"--size";string_of_int artifact.size]
      |> Result.map_error (fun () -> Installer_failed) in
    let* completion = completion_of_output output in
    let service = Sandbox_readiness.probe ~host ~run:probe_run ~require_rootless ~require_userns Docker in
    Ok {completion;service}
  with Unix.Unix_error _ -> Error Installer_failed
let launch_and_recheck ~run ~host ~probe_run ~require_rootless ~require_userns () =
  let* _ = architecture host in
  (* Official install target. Custom application destinations are not this action. *)
  let app = "/Applications/Docker.app" in
  let* () = verify_app ~run app in
  let* _ = run ["/usr/bin/open";app] |> Result.map_error (fun () -> Installer_failed) in
  Ok (Sandbox_readiness.probe ~host ~run:probe_run ~require_rootless ~require_userns Docker)
module For_testing = struct let install_staged = install_staged end
let error_message = function
  | Unsupported_host -> "This Docker Desktop installer is for macOS. Choose the Linux Docker setup on Linux."
  | Invalid_checksum -> "Docker's official checksum did not identify exactly one installer. Refresh the download."
  | Download_failed -> "The official Docker download failed. Check connectivity and retry."
  | Invalid_file -> "The private Docker installer could not be read safely. Download it again."
  | Digest_mismatch -> "The download differs from Docker's official checksum. Refresh the download before installing."
  | Signature_rejected -> "macOS rejected Docker's expected publisher, signature, or notarization."
  | Mount_failed -> "The verified Docker disk image could not be mounted."
  | Installer_failed -> "Docker installation or launch was not confirmed. Review the system action and retry."
  | Invalid_completion -> "The privileged installer did not return a valid completion receipt."
  | Cleanup_required directory -> "The installer volume needs cleanup before retrying: " ^ directory
