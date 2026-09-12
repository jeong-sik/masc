(** Masc_tui_image_cache — what a downloaded body must be before the image
    cache may call it a hit.

    A remote image URL can answer with something that is not an image: a
    rate-limit notice, a login page, an HTML error. If such a body is kept in
    the cache, every later preview finds a non-empty file, calls it a hit, and
    fails in the decoder. The verdict below is the only thing that decides a
    hit, and it reads the bytes, not the file size or the exit code. *)

type verdict =
  | Cached_image of { media_type : string }
      (** The bytes carry a known image signature; the file may stay cached. *)
  | Not_an_image of { reason : string }
      (** The bytes carry no known image signature (an HTML page, plain text,
          an empty file). The file must not be kept. *)

val verdict_of_bytes : string -> verdict
(** Pure. Decides by magic bytes through
    {!Masc.Keeper_vision_tool.sniff_image_media_type}, so the cache and the
    composer agree on what an image is. *)

type download_error =
  | Download_failed of string
      (** curl did not deliver a body (transport error, timeout, HTTP error
          status under [--fail]). Nothing is cached; a later attempt may
          succeed. *)
  | Body_not_an_image of { reason : string }
      (** The URL delivered a body that is not an image. The file was removed;
          a preview may record this so it does not fetch the URL again. *)

val download_error_text : download_error -> string
(** The error as one line for a notice or a refusal. *)
