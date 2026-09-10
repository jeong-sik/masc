type release = {version:string; url:string; digest:string; size:int}
type verified_artifact = {release:release; path:string}
type error = Unsupported_host | Invalid_release | Download_failed | Invalid_file
  | Digest_mismatch | Signature_rejected | Publisher_mismatch | Installer_failed
type runner = string list -> (string, unit) result
let ( let* ) = Result.bind
let expected_publisher = "Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)"
(* Publisher identity observed from Apple's official 1.4.1 signed package:
   GitHub asset digest c0d2716afefbb194c93fae662e9cae7cc186bcbcf746816608ec673dd648a6a4,
   pkgutil validated the chain and spctl accepted its notarization (2026-09-10).
   This is an explicit trust anchor; a publisher change requires review. *)
let metadata_url = "https://api.github.com/repos/apple/container/releases/latest"
let string fields name = match List.assoc_opt name fields with Some (`String value) -> Some value | _ -> None
let valid_version value =
  match String.split_on_char '.' value with
  | [major;minor;patch] -> List.for_all (fun part -> part <> "" && String.for_all (function '0'..'9' -> true | _ -> false) part) [major;minor;patch]
  | _ -> false
let release_of_json = function
  | `Assoc fields ->
    (match string fields "tag_name", List.assoc_opt "assets" fields with
     | Some version, Some (`List assets) when valid_version version ->
       let name = "container-" ^ version ^ "-installer-signed.pkg" in
       let matching = List.filter_map (function
         | `Assoc fields when string fields "name" = Some name -> Some fields | _ -> None) assets in
       (match matching with
        | [asset] ->
          let url = "https://github.com/apple/container/releases/download/" ^ version ^ "/" ^ name in
          (match string asset "browser_download_url", string asset "digest", List.assoc_opt "size" asset with
           | Some actual_url, Some digest, Some (`Int size)
             when actual_url = url && size > 0 && String.starts_with ~prefix:"sha256:" digest ->
             let digest = String.sub digest 7 (String.length digest - 7) in
             if String.length digest = 64 && String.for_all (function '0'..'9'|'a'..'f' -> true | _ -> false) digest
             then Ok {version;url;digest;size} else Error Invalid_release
           | _ -> Error Invalid_release)
        | _ -> Error Invalid_release)
     | _ -> Error Invalid_release)
  | _ -> Error Invalid_release
let file_digest path =
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind <> Unix.S_REG || stat.st_uid <> Unix.geteuid () || stat.st_perm land 0o077 <> 0
    then Error Invalid_file
    else In_channel.with_open_bin path (fun input ->
      let buffer = Bytes.create 65536 in
      let rec read digest = match In_channel.input input buffer 0 (Bytes.length buffer) with
        | 0 -> Ok (Digestif.SHA256.(to_hex (get digest)), stat.st_size)
        | count -> read (Digestif.SHA256.feed_string digest (Bytes.sub_string buffer 0 count)) in
      read Digestif.SHA256.empty)
  with Sys_error _ | Unix.Unix_error _ -> Error Invalid_file
let verify ~run ~release ~path =
  let* digest,size = file_digest path in
  if digest <> release.digest || size <> release.size then Error Digest_mismatch else
  (* Absolute system tools are intentional: a PATH shim must not attest its own
     package. Locale is fixed because pkgutil exposes certificate text, not JSON. *)
  let* signature = run ["/usr/bin/env";"LC_ALL=C";"/usr/sbin/pkgutil";"--check-signature";path]
    |> Result.map_error (fun () -> Signature_rejected) in
  let leaves = String.split_on_char '\n' signature |> List.map String.trim
    |> List.filter_map (fun line -> if String.starts_with ~prefix:"1. " line
      then Some (String.sub line 3 (String.length line - 3)) else None) in
  if leaves <> [expected_publisher] then Error Publisher_mismatch else
  let* _ = run ["/usr/sbin/spctl";"--assess";"--type";"install";path]
    |> Result.map_error (fun () -> Signature_rejected) in
  Ok {release;path}
let acquire ~host ~run =
  match host with
  | Sandbox_readiness.Macos {architecture=Arm64;major} when major >= 26 ->
    let* metadata = run ["/usr/bin/curl";"--fail";"--silent";"--show-error";"--proto";"=https";metadata_url]
      |> Result.map_error (fun () -> Download_failed) in
    let* release = (try release_of_json (Yojson.Safe.from_string metadata)
      with Yojson.Json_error _ -> Error Invalid_release) in
    (try
      let path, channel = Filename.open_temp_file ~perms:0o600 "masc-apple-container-" ".pkg" in
      close_out channel;
      let keep = ref false in
      Fun.protect ~finally:(fun () -> if not !keep then (try Sys.remove path with Sys_error _ -> ()))
        (fun () ->
          let* _ = run ["/usr/bin/curl";"--fail";"--silent";"--show-error";
            "--location";"--proto";"=https";"--proto-redir";"=https";"--max-filesize";string_of_int release.size;"--output";path;release.url]
            |> Result.map_error (fun () -> Download_failed) in
          let* artifact = verify ~run ~release ~path in
          keep := true;
          Ok artifact)
     with Sys_error _ | Unix.Unix_error _ -> Error Invalid_file)
  | _ -> Error Unsupported_host
let install ~run artifact =
  let* verified = verify ~run ~release:artifact.release ~path:artifact.path in
  run ["/usr/bin/sudo";"/usr/sbin/installer";"-pkg";verified.path;"-target";"/"]
  |> Result.map (fun _ -> ()) |> Result.map_error (fun () -> Installer_failed)
let remove artifact = try Sys.remove artifact.path with Sys_error _ -> ()
let to_json artifact = `Assoc ["schema",`String "masc.verified_prerequisite.v1";
  "backend",`String "apple_container";"version",`String artifact.release.version;
  "source_url",`String artifact.release.url;"sha256",`String artifact.release.digest;
  "publisher",`String expected_publisher;"platform_signature",`String "accepted";
  "status",`String "verified_download";"installation",`String "not_attested";
  "sandbox_readiness",`String "not_checked"]
let error_message = function
  | Unsupported_host -> "Apple Container requires Apple Silicon and macOS 26 or newer."
  | Invalid_release -> "Apple's release metadata did not identify one signed package with an official SHA-256 digest."
  | Download_failed -> "The official package download failed. Check connectivity and retry."
  | Invalid_file -> "The private installer file could not be read safely. Download it again."
  | Digest_mismatch -> "The installer differs from its official release digest or size. It was not installed."
  | Signature_rejected -> "macOS rejected the installer's signature or notarization. It was not installed."
  | Publisher_mismatch -> "The installer is not signed by the expected Apple Container publisher. It was not installed."
  | Installer_failed -> "The system installer did not complete. Review its output, then retry or choose another sandbox."
