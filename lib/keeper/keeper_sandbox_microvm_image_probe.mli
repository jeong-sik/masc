(** Whether the image a guest boots from is in the host's image store: the
    argv that lists or inspects an image, how each runtime's answer is read,
    the outcome and failure of a probe, the lock marker an inspect answer
    carries and the refusal that names how to get a missing image in.

    [Keeper_sandbox_microvm] includes this module. *)

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

val classify_image_probe :
  inspect_shape:json_shape ->
  listing_shape:json_shape ->
  inspect:Unix.process_status * string * string ->
  listing:(Unix.process_status * string * string) option ->
  image_probe_outcome

val image_present_result_for :
  Keeper_microvm_backend.t ->
  name:string option ->
  image:string ->
  image_probe_outcome ->
  (unit, string) result

val image_listing_argv_for : Keeper_microvm_backend.t -> string list

val image_listing_shape_for : Keeper_microvm_backend.t -> json_shape

val image_inspect_argv_for : Keeper_microvm_backend.t -> image:string -> string list

val image_inspect_shape_for : Keeper_microvm_backend.t -> json_shape

val image_lock_marker_from_inspect : string -> string option

val classify_image_probe_for :
  Keeper_microvm_backend.t ->
  image:string ->
  inspect:Unix.process_status * string * string ->
  listing:(Unix.process_status * string * string) option ->
  image_probe_outcome

val image_probe_for :
  Keeper_microvm_backend.t -> image:string -> timeout_sec:float -> image_probe_outcome

val image_present_for :
  Keeper_microvm_backend.t ->
  name:string option ->
  image:string ->
  timeout_sec:float ->
  (unit, string) result
