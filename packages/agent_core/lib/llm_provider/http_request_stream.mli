(** Encode a request tree with its final streaming fields, without first
    encoding and reparsing the complete request. *)

type fields =
  | Stream_only
  | Stream_with_usage

val encode
  :  fields:fields
  -> Yojson.Safe.t
  -> (string, Http_client.body_injection_error) result
(** Byte/error equivalent to encoding the input with [Yojson.Safe.to_string]
    and applying [Http_client.inject_stream_param] or
    [Http_client.inject_stream_and_options]. Existing top-level streaming
    fields are replaced in the same order.

    [Intlit] contains unchecked source text rather than a parsed number. If
    the tree contains one, retain the textual injector's validation and
    normalization, including malformed fragments and noncanonical numbers.
    Nonfinite floats also take that path so writer exceptions occur before
    any streaming field is dropped. Other trees are encoded once.
    No input tree, bytes or authority is cached. *)
