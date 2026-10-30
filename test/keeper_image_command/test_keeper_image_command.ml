open Alcotest
module Image = Masc.Keeper_microvm_image_command

let reference = "fixture-ocaml:build"
let digest = "sha256:" ^ String.make 64 'a'
let platform : Image.platform = {architecture="arm64"; os="linux"; variant=None}
let identity : Image.identity = {descriptor_digest=digest; platform}
let strings values = `List (List.map (fun value -> `String value) values)
let platform_json = `Assoc ["architecture", `String "arm64"; "os", `String "linux"]

(* Apple container 1.3.1 image-inspect shape, with independent values.
   The observed OCaml image has Entrypoint=[opam;exec;--] and Cmd=[/bin/bash]. *)
let image_config ?(architecture="arm64") ?(os="linux") fields =
  `Assoc ["architecture", `String architecture; "os", `String os;
          "config", `Assoc (("Cmd", strings ["/bin/bash"]) :: fields)]

let variant ?(platform=platform_json) ?(config=image_config []) () =
  `Assoc ["platform", platform; "config", config;
          "digest", `String ("sha256:" ^ String.make 64 'b'); "size", `Int 1024]

let image ?(name=reference) ?(descriptor_digest=digest) ?(variants=[variant ()]) () =
  `Assoc ["id", `String (String.make 64 'a');
    "configuration", `Assoc ["name", `String name;
      "descriptor", `Assoc ["digest", `String descriptor_digest;
        "mediaType", `String "application/vnd.oci.image.index.v1+json"; "size", `Int 376]];
    "variants", `List variants]

let inspect ?name ?descriptor_digest ?variants () =
  `List [image ?name ?descriptor_digest ?variants ()]

let decode ?(identity=identity) value =
  Image.of_apple_inspect ~reference ~identity (Yojson.Safe.to_string value)

let accepted ?identity raw = match decode ?identity raw with
  | Ok value -> value
  | Error error -> fail (Image.error_message error)

let invalid_inspect = function
  | Image.Invalid_inspect _ -> true
  | Image.Reference_mismatch | Image.Descriptor_mismatch
  | Image.Platform_absent | Image.Platform_ambiguous -> false

let refused message expected raw = match decode raw with
  | Ok _ -> fail (message ^ ": accepted incomplete or conflicting image metadata")
  | Error error -> check bool message true (expected error)

let replace key value = function
  | `Assoc fields -> `Assoc ((key,value) :: List.remove_assoc key fields)
  | _ -> fail "fixture replacement requires an object"

let explicit_command = ["tail"; "-f"; "/dev/null"]

let test_entrypoint_composes_with_explicit_command () =
  List.iter (fun entrypoint ->
    let raw = inspect ~variants:[variant ~config:(image_config ["Entrypoint", strings entrypoint]) ()] () in
    let execution = accepted raw in
    check (list string) "image entrypoint precedes the explicit Keeper command"
      (entrypoint @ explicit_command) (Image.command execution ~arguments:explicit_command))
    [["opam"; "exec"; "--"]; ["/usr/local/bin/image-init"; "--mode"; "worker"]];
  let with_empty_argument = accepted (inspect ~variants:[variant
      ~config:(image_config ["Entrypoint", strings ["/image-init"; ""]]) ()] ()) in
  check (list string) "a non-executable empty argument remains an actual argv value"
    ["/image-init"; ""; "tail"; "-f"; "/dev/null"]
    (Image.command with_empty_argument ~arguments:explicit_command)

let test_no_entrypoint_keeps_the_explicit_command () =
  List.iter (fun fields ->
    let execution = accepted (inspect ~variants:[variant ~config:(image_config fields) ()] ()) in
    check (list string) "image Cmd never replaces or appends to explicit argv"
      explicit_command (Image.command execution ~arguments:explicit_command))
    [[]; ["Entrypoint", `Null]; ["Entrypoint", `List []]];
  List.iter (fun config ->
    let execution = accepted (inspect ~variants:[variant ~config ()] ()) in
    check (list string) "optional OCI execution config has no entrypoint defaults"
      explicit_command (Image.command execution ~arguments:explicit_command))
    [`Assoc ["architecture", `String "arm64"; "os", `String "linux"];
     `Assoc ["architecture", `String "arm64"; "os", `String "linux"; "config", `Null]]

let test_image_identity_must_match_observed_guest () =
  let canonical = accepted (inspect ~name:"docker.io/library/fixture-ocaml:build" ()) in
  check bool "canonical stored reference is bound to the actual query by image content" true
    (Image.validate_binding canonical ~reference ~identity = Ok ());
  refused "different descriptor" ((=) Image.Descriptor_mismatch)
    (inspect ~descriptor_digest:("sha256:" ^ String.make 64 'c') ());
  refused "conflicting top-level row identity" invalid_inspect
    (`List [replace "id" (`String (String.make 64 'c')) (image ())]);
  refused "two image rows are ambiguous" invalid_inspect
    (`List [image (); image ()]);
  refused "no image row is not an empty entrypoint" invalid_inspect (`List [])

let test_metadata_binding_cannot_be_reused_for_another_image () =
  let execution = accepted (inspect ()) in
  check bool "the original request and guest image retain authority" true
    (Image.validate_binding execution ~reference ~identity = Ok ());
  check bool "a different request cannot borrow the observation" true
    (Image.validate_binding execution ~reference:"another:image" ~identity
      = Error Image.Reference_mismatch);
  let changed_digest : Image.identity =
    {identity with descriptor_digest="sha256:" ^ String.make 64 'c'} in
  check bool "another image digest cannot borrow the observation" true
    (Image.validate_binding execution ~reference ~identity:changed_digest
      = Error Image.Descriptor_mismatch);
  let changed_platform : Image.identity =
    {identity with platform={platform with architecture="amd64"}} in
  check bool "another guest platform cannot borrow the observation" true
    (Image.validate_binding execution ~reference ~identity:changed_platform
      = Error Image.Platform_absent)

let test_platform_selection_is_exact_and_unique () =
  let foreign = variant
      ~platform:(`Assoc ["architecture", `String "amd64"; "os", `String "linux"])
      ~config:(image_config ~architecture:"amd64" ["Entrypoint", strings ["/foreign-init"]]) () in
  let matching = variant ~config:(image_config ["Entrypoint", strings ["/selected-init"]]) () in
  List.iter (fun variants ->
    let execution = accepted (inspect ~variants ()) in
    check (list string) "selected platform, not enumeration order, supplies the prefix"
      ["/selected-init"; "tail"; "-f"; "/dev/null"]
      (Image.command execution ~arguments:explicit_command))
    [[foreign; matching]; [matching; foreign]];
  refused "unavailable platform" ((=) Image.Platform_absent) (inspect ~variants:[foreign] ());
  refused "duplicate matching platform" ((=) Image.Platform_ambiguous)
    (inspect ~variants:[matching; matching] ());
  let arm_v8 = variant ~platform:(`Assoc ["architecture", `String "arm64";
      "os", `String "linux"; "variant", `String "v8"])
      ~config:(image_config ["Entrypoint", strings ["/v8-init"]]) () in
  refused "variant does not silently match an absent variant" ((=) Image.Platform_absent)
    (inspect ~variants:[arm_v8] ());
  let v8_identity : Image.identity =
    {identity with platform={platform with variant=Some "v8"}} in
  let execution = accepted ~identity:v8_identity (inspect ~variants:[arm_v8] ()) in
  check (list string) "exact variant remains usable"
    ["/v8-init"; "tail"; "-f"; "/dev/null"]
    (Image.command execution ~arguments:explicit_command)

let test_missing_metadata_never_means_no_entrypoint () =
  let row = image () and selected = variant () in
  let absent key = function
    | `Assoc fields -> `Assoc (List.remove_assoc key fields)
    | _ -> fail "fixture omission requires an object" in
  let malformed =
    [ `List [absent "variants" row]
    ; inspect ~variants:[] ()
    ; `List [replace "variants" `Null row]
    ; inspect ~variants:[absent "config" selected] ()
    ; inspect ~variants:[replace "config" `Null selected] ()
    ; inspect ~variants:[variant ~config:(replace "config" (`Int 7) (image_config [])) ()] ()
    ; `List [absent "configuration" row]
    ; `List [replace "configuration" (`Assoc ["name", `String reference]) row] ] in
  List.iter (fun raw -> match decode raw with
    | Error _ -> ()
    | Ok _ -> fail "missing metadata authorized an unwrapped command") malformed

let test_entrypoint_and_selected_objects_are_strict () =
  List.iter (fun entrypoint ->
    refused "invalid OCI entrypoint" invalid_inspect
      (inspect ~variants:[variant ~config:(image_config ["Entrypoint", entrypoint]) ()] ()))
    [`String "opam exec --"; `Int 7; `List [`String "opam"; `Int 1];
     strings [""]; strings ["/image-init"; "bad\000argument"]];
  refused "duplicate Entrypoint" invalid_inspect (inspect ~variants:[variant
    ~config:(image_config ["Entrypoint", strings ["/first"];
                          "Entrypoint", strings ["/second"]]) ()] ());
  refused "duplicate architecture" invalid_inspect (inspect ~variants:[variant
    ~platform:(`Assoc ["architecture", `String "arm64";
                      "architecture", `String "amd64"; "os", `String "linux"]) ()] ());
  List.iter (fun config ->
    refused "variant platform conflicts with image config" invalid_inspect
      (inspect ~variants:[variant ~config ()] ()))
    [image_config ~architecture:"amd64" []; image_config ~os:"windows" []]

let () = run "Keeper image command"
  ["OCI execution",
    [test_case "entrypoint composes with explicit argv" `Quick test_entrypoint_composes_with_explicit_command
    ; test_case "base image preserves explicit argv" `Quick test_no_entrypoint_keeps_the_explicit_command
    ; test_case "guest image identity binds metadata" `Quick test_image_identity_must_match_observed_guest
    ; test_case "metadata cannot be borrowed by another image" `Quick test_metadata_binding_cannot_be_reused_for_another_image
    ; test_case "platform selection is unique" `Quick test_platform_selection_is_exact_and_unique
    ; test_case "missing metadata refuses" `Quick test_missing_metadata_never_means_no_entrypoint
    ; test_case "malformed or conflicting metadata refuses" `Quick test_entrypoint_and_selected_objects_are_strict]]
