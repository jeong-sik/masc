module Backend = Keeper_microvm_backend
open Keeper_sandbox_microvm_base

(** Whether [image] is in container's own store.

    container keeps its images separately from the Docker daemon: a
    [masc-keeper-sandbox:local] built for Docker is invisible here. And
    [container run] has no [--pull=never], so a missing image is not an
    error -- it is a fetch. Observed 2026-08-28: the first live call through
    masc's own entry point reached out to registry-1.docker.io and came back
    401, and with credentials present it would have pulled a stranger's
    image under the keeper's name instead.

    [container image inspect] answers from the local store without touching
    the network -- verified against a present and an absent image -- so the
    check is a gate, not a probe that itself fetches.

    A missing image and a dead service both exit 1. Human error prose is not a
    protocol, so a failed inspect is classified as missing only after
    [container image list --format json] proves that the service and image
    store are readable. *)
type image_probe_phase =
  | Image_inspect
  | Image_list

type image_probe_failure =
  { phase : image_probe_phase
  ; status : Unix.process_status
  ; stdout : string
  ; stderr : string
  ; reason : string
  }

type image_probe_outcome =
  | Image_present
  | Image_missing
  | Image_cli_unavailable
  | Image_probe_failed of image_probe_failure

(** The shapes a machine-readable image answer arrives in.

    Measured 2026-09-04, container 1.3.1 and msb 0.6.16:

    {v
      container image list --format json     [ {...}, ... ]   array
      container image inspect <ref>          [ {...} ]        array
      msb image list --format json           [ {...}, ... ]   array
      msb image inspect --format json <ref>  { ... }          object
      nerdctl images --format '{{json .}}'   one object/line  lines
    v}

    An object read with the array check would call a healthy answer malformed
    and turn "image is present" into "the probe could not say" -- which is
    what an earlier version of this module did to every [msb] keeper. The
    shape is chosen by the runtime and the question, never assumed. *)
type json_shape =
  | Json_array
  | Json_object
  | Json_lines

let json_array_error raw =
  match Yojson.Safe.from_string raw with
  | `List _ -> None
  | _ -> Some "expected a JSON array"
  | exception Yojson.Json_error detail -> Some ("invalid JSON: " ^ detail)
;;

let json_object_error raw =
  match Yojson.Safe.from_string raw with
  | `Assoc _ -> None
  | _ -> Some "expected a JSON object"
  | exception Yojson.Json_error detail -> Some ("invalid JSON: " ^ detail)
;;

let json_lines_error raw =
  String.split_on_char '\n' raw
  |> List.map String.trim
  |> List.filter (fun line -> not (String.equal line ""))
  |> List.fold_left
       (fun found line ->
         match found with
         | Some _ -> found
         | None ->
           (match Yojson.Safe.from_string line with
            | _ -> None
            | exception Yojson.Json_error detail ->
              Some ("invalid JSON line: " ^ detail)))
       None
;;

let json_shape_error shape raw =
  match shape with
  | Json_array -> json_array_error raw
  | Json_object -> json_object_error raw
  | Json_lines -> json_lines_error raw
;;

let probe_failure ~phase ~status ~stdout ~stderr ~reason =
  Image_probe_failed { phase; status; stdout; stderr; reason }
;;

let classify_image_probe
      ~inspect_shape
      ~listing_shape
      ~inspect:(inspect_status, inspect_stdout, inspect_stderr)
      ~listing
  =
  match inspect_status with
  | Unix.WEXITED 0 ->
    (match json_shape_error inspect_shape inspect_stdout with
     | None -> Image_present
     | Some reason ->
       probe_failure
         ~phase:Image_inspect
         ~status:inspect_status
         ~stdout:inspect_stdout
         ~stderr:inspect_stderr
         ~reason)
  | Unix.WEXITED 127 -> Image_cli_unavailable
  | Unix.WEXITED 1 ->
    (match listing with
     | Some (Unix.WEXITED 0 as status, stdout, stderr) ->
       (match json_shape_error listing_shape stdout with
        | None -> Image_missing
        | Some reason ->
          probe_failure ~phase:Image_list ~status ~stdout ~stderr ~reason)
     | Some
         ( ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status)
         , stdout
         , stderr ) ->
       probe_failure
         ~phase:Image_list
         ~status
         ~stdout
         ~stderr
         ~reason:"image store listing failed after inspect exited 1"
     | None ->
       probe_failure
         ~phase:Image_inspect
         ~status:inspect_status
         ~stdout:inspect_stdout
         ~stderr:inspect_stderr
         ~reason:"image store listing evidence was not collected")
  | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status ->
    probe_failure
      ~phase:Image_inspect
      ~status
      ~stdout:inspect_stdout
      ~stderr:inspect_stderr
      ~reason:"image inspect failed"
;;

let phase_label = function
  | Image_inspect -> "image inspect"
  | Image_list -> "image listing"
;;

(* Each runtime keeps its own image store, so the refusal names the CLI that
   was asked. Telling an [msb] keeper to install Apple container -- which the
   Apple-only wording did -- sends the operator to fix a runtime the keeper
   does not use.

   Promote records a tag the store already has, so what differs per runtime
   is how a build gets into its store: [masc sandbox-image] builds into
   container's and nerdctl's, and msb has no build command, so a build
   reaches it through [msb load]. Going back is a promote of an earlier tag
   the store still has. *)
let missing_image_recovery backend ~name ~image =
  let runtime = Backend.to_string backend in
  match backend, name with
  | (Backend.Apple_container | Backend.Nerdctl_kata), Some name ->
    let source =
      if String.equal name Keeper_sandbox_image_version.(base_embedded.name)
      then ""
      else " --source <checkout>"
    in
    Printf.sprintf
      "Next: build a new version with `masc sandbox-image --recipe %s%s \
       --runtime %s` and promote the tag it prints, or promote an earlier tag \
       this store still has: `masc sandbox-image promote %s <tag> --runtime \
       %s`."
      name source runtime name runtime
  | (Backend.Apple_container | Backend.Nerdctl_kata), None ->
    Printf.sprintf
      "Next: inspect this Keeper's sandbox_image catalog name, then build and \
       promote a new version for %s."
      runtime
  | Backend.Microsandbox, Some name ->
    Printf.sprintf
      "Next: restore %s to msb's store from a trusted OCI archive with `msb \
       load`, or load another build and promote its tag with `masc \
       sandbox-image promote %s <tag> --runtime %s`. MASC cannot build a \
       microsandbox image: msb has no build command."
      image name runtime
  | Backend.Microsandbox, None ->
    Printf.sprintf
      "Next: restore %s to msb's store from a trusted OCI archive with `msb \
       load`. MASC cannot build a microsandbox image: msb has no build \
       command."
      image
;;

let image_present_result_for backend ~name ~image = function
  | Image_present -> Ok ()
  | Image_missing ->
    Error
      (Printf.sprintf
         "microvm_image_missing: %s is the build the host image catalog names \
          for this Keeper, and it is not in %s's image store. Each microVM \
          runtime keeps its images apart from Docker's, and none of these runs \
          has a --pull=never, so running without this check fetches from a \
          registry instead of failing. %s"
         image
         (Backend.cli_name backend)
         (missing_image_recovery backend ~name ~image))
  | Image_cli_unavailable ->
    Error
      (Printf.sprintf
         "microvm_cli_unavailable: keeper declares microvm_backend = %s and \
          the `%s` CLI is not on PATH. Next: install it, name a runtime this \
          host has (%s), or move the keeper to sandbox_profile = \"docker\"."
         (Backend.to_string backend)
         (Backend.cli_name backend)
         (String.concat ", " Backend.valid_strings))
  | Image_probe_failed failure ->
    Error
      (Printf.sprintf
         "microvm_image_probe_failed: `%s %s` did not establish whether image \
          %s exists (%s; %s: %s). Next: check that the %s runtime is running."
         (Backend.cli_name backend)
         (phase_label failure.phase)
         image
         failure.reason
         (Keeper_sandbox_exec_failure.status_label failure.status)
         (output_for_log ~stdout:failure.stdout ~stderr:failure.stderr)
         (Backend.cli_name backend))
;;

(* [nerdctl] has no [image list]; its listing is [images]. Its command
   reference documents both [--format=json] and the Go template; the template
   is the spelling used here because it is the one whose per-line output this
   module's [Json_lines] reader is written against. [container image list
   --format json] and [msb image list --format json] both answer an array,
   measured 0.6.16 and 1.3.1 on 2026-09-04. *)
let image_listing_argv_for backend =
  match (backend : Backend.t) with
  | Backend.Apple_container | Backend.Microsandbox ->
    command_argv_for backend @ [ "image"; "list"; "--format"; "json" ]
  | Backend.Nerdctl_kata ->
    command_argv_for backend @ [ "images"; "--format"; "{{json .}}" ]
;;

let image_listing_shape_for backend =
  match (backend : Backend.t) with
  | Backend.Apple_container | Backend.Microsandbox -> Json_array
  | Backend.Nerdctl_kata -> Json_lines
;;

(* [container image inspect] answers JSON with no flag; [msb image inspect]
   answers a human table unless [--format json] is asked for, and then answers
   a bare object rather than an array. Nerdctl 2.3.5 dockercompat rejects
   digest-only image references after normalizing an empty tag to latest.
   Native mode avoids that conversion and returns containerd image records.
   Its successful empty array and unfiltered digest aliases require the typed
   content check below, not merely an array-shape check.
   Source: nerdctl v2.3.5 pkg/cmd/image/inspect.go, native/image.go. *)
let image_inspect_argv_for backend ~image =
  match (backend : Backend.t) with
  | Backend.Apple_container -> command_argv_for backend @ [ "image"; "inspect"; image ]
  | Backend.Microsandbox ->
    command_argv_for backend @ [ "image"; "inspect"; "--format"; "json"; image ]
  | Backend.Nerdctl_kata ->
    command_argv_for backend
    @ [ "image"; "inspect"; "--mode"; "native"; image ]
;;

let image_inspect_shape_for backend =
  match (backend : Backend.t) with
  | Backend.Apple_container | Backend.Nerdctl_kata -> Json_array
  | Backend.Microsandbox -> Json_object
;;

type nerdctl_native_image =
  { image_name : string
  ; target_digest : string
  }

let parse_nerdctl_native_images raw =
  let open Result.Syntax in
  let field key = function
    | `Assoc fields ->
      (match List.filter (fun (name, _) -> String.equal name key) fields with
       | [ (_, value) ] -> Ok value
       | _ -> Error ("native image requires exactly one " ^ key ^ " field"))
    | _ -> Error ("native image " ^ key ^ " parent must be an object")
  in
  let nonempty = function
    | `String value when String.trim value <> "" -> Ok value
    | _ -> Error "native image name and target digest must be nonempty strings"
  in
  let row value =
    let* image = field "Image" value in
    let* name = field "Name" image in
    let* image_name = nonempty name in
    let* target = field "Target" image in
    let* digest = field "digest" target in
    let* target_digest = nonempty digest in
    Ok { image_name; target_digest }
  in
  match Yojson.Safe.from_string raw with
  | `List rows ->
    List.fold_right
      (fun value acc ->
         let* image = row value in
         let* rest = acc in
         Ok (image :: rest))
      rows (Ok [])
  | _ -> Error "native image inspection must be an array"
  | exception Yojson.Json_error detail -> Error ("invalid native image JSON: " ^ detail)
;;

let image_lock_marker_from_inspect raw =
  let key = "masc.sandbox.opam_lock_sha256" in
  let rec find = function
    | `Assoc fields ->
      (match List.find_opt (fun (name, _) -> String.equal name key) fields with
       | Some (_, `String digest) -> Some digest
       | Some _ -> None
       | None -> List.find_map (fun (_, value) -> find value) fields)
    | `List values -> List.find_map find values
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> None
  in
  match Yojson.Safe.from_string raw with
  | json -> find json
  | exception Yojson.Json_error _ -> None
;;

let classify_image_probe_for backend ~image ~inspect ~listing =
  match backend, inspect with
  | Backend.Nerdctl_kata, (Unix.WEXITED 0 as status, stdout, stderr) ->
    let invalid reason = probe_failure ~phase:Image_inspect ~status ~stdout ~stderr ~reason in
    (match parse_nerdctl_native_images stdout with
     | Error reason -> invalid reason
     | Ok [] -> Image_missing
     | Ok rows ->
       (* OCI reference syntax uses @ to separate a name from immutable content.
          Native inspect may return other repository aliases for that digest;
          digest equality, not a guessed repository/tag normalization, binds it. *)
       (match String.split_on_char '@' image with
        | [ _name ] -> Image_present
        | [ name; digest ] when name <> "" && digest <> "" ->
          (match List.find_opt (fun row -> not (String.equal row.target_digest digest)) rows with
           | None -> Image_present
           | Some row ->
             invalid (Printf.sprintf
               "native image %s target digest %s differs from requested reference %s"
               row.image_name row.target_digest digest))
        | _ -> invalid "invalid digest-qualified image reference"))
  | (Backend.Apple_container | Backend.Microsandbox), _
  | ( Backend.Nerdctl_kata
    , ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _) ) ->
    classify_image_probe
      ~inspect_shape:(image_inspect_shape_for backend)
      ~listing_shape:(image_listing_shape_for backend)
      ~inspect ~listing
;;

let image_probe_with_inspect_for backend ~image ~timeout_sec =
  let inspect =
    Process_eio.run_argv_with_status_split
      ~timeout_sec
      (image_inspect_argv_for backend ~image)
  in
  let listing =
    match inspect with
    | Unix.WEXITED 1, _, _ ->
      Some
        (Process_eio.run_argv_with_status_split
           ~timeout_sec
           (image_listing_argv_for backend))
    | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _ -> None
  in
  classify_image_probe_for backend ~image ~inspect ~listing, inspect
;;

(* Presence and the build marker come from the same store observation.
   Missing metadata warns but never blocks boot. *)
let warn_if_lock_marker ~image (_, stdout, _) =
  Keeper_sandbox_image_version.lock_warning
    ~image
    ~built_lock_sha256:(image_lock_marker_from_inspect stdout)
  |> Option.iter (fun warning -> Log.Keeper.warn "%s" warning)
;;

(* The gate refuses a missing image rather than letting the runtime fetch
   it: none of these runs has --pull=never, so an absent image is a reach for
   a registry, and on 2026-08-28 that reach came back 401 from
   registry-1.docker.io -- with credentials present it would have pulled a
   stranger's image under the keeper's name. Nor does it build one: the image
   is the build the host catalog has promoted, and only
   [masc sandbox-image] builds and promotes. *)
let image_present_for backend ~name ~image ~timeout_sec =
  let outcome, inspect = image_probe_with_inspect_for backend ~image ~timeout_sec in
  (match outcome with
   | Image_present -> warn_if_lock_marker ~image inspect
   | Image_missing | Image_cli_unavailable | Image_probe_failed _ -> ());
  image_present_result_for backend ~name ~image outcome
;;
