(** Fits one image to one candidate's request-body cap before the walk
    sends it.

    Pure: this module never runs a scaler. The walk asks {!plan}, runs the
    scaler it names, and asks again with the re-encoded bytes. The exact
    serialized size is still enforced by the client before dispatch; this
    only decides whether a scaler run is worth it and how far to shrink. *)

(** What the walk must do with the image before this candidate sees it. *)
type verdict =
  | Sends_as_is  (** The serialized request stays under the cap. *)
  | Shrink_longest_edge_to of int
      (** Re-encode with this longest edge, then ask again. Always below the
          current edge and at or above the floor the caller gave. *)
  | Cannot_fit of
      { needed_bytes : int
      ; cap_bytes : int
      }
      (** No re-encoding this module can plan brings the request under the
          cap: the dimensions are unknown, the cap leaves no room for pixels
          once the query and the envelope are counted, or the edge that
          would fit is below the floor. *)

val envelope_allowance_bytes : int
(** Bytes reserved for everything in the request that is neither the image
    nor the query: the JSON envelope, the prompt wrapped around the query,
    the generation parameters. *)

val shrink_margin : float
(** Factor applied to the edge the byte ratio predicts, because encoders do
    not scale bytes exactly with pixel count. *)

val base64_length : int -> int
(** Length of the standard base64 encoding of that many bytes. *)

val needed_bytes : image_bytes:int -> query_bytes:int -> int
(** The serialized request size this module predicts for those inputs. *)

val plan
  :  cap_bytes:int
  -> image_bytes:int
  -> query_bytes:int
  -> longest_edge:int option
  -> min_edge:int
  -> verdict
(** [longest_edge] is the image's current longest edge when its header could
    be read; [min_edge] is the smallest edge worth sending. *)
