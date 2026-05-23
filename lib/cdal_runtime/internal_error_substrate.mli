(** Internal_error_substrate — RFC-0159 Phase A typed envelope for
    [Agent_sdk.Error.Internal] payloads emitted from the cdal_runtime
    sub-library.

    The cdal_runtime sub-library cannot depend on the masc_mcp main
    library where [Cascade_error_classify] lives, so this module is the
    minimal cdal_runtime-local typed substrate that produces the same
    [\[masc_oas_error\]] prefixed JSON payload the classifier parses
    upstream.  Before Phase A, [contract_runner.ml] emitted raw
    [Internal (Printf.sprintf "contract rejected: %s" reason)] which
    fell through to the [Reason_internal_error] catch-all bucket.

    The prefix string is mirrored from [Cascade_error_classify]; a
    follow-up PR can promote the prefix to a shared sub-library so it
    becomes a true SSOT.  For Phase A the substrate is intentionally
    closed-sum and serializes through a single emit function. *)

type t =
  | Contract_rejected of { reason : string }

val sdk_error_of : t -> Error.sdk_error
(** Encode [t] as an [Error.Internal] payload prefixed with
    [\[masc_oas_error\]] so the masc_mcp classifier routes it to the
    [internal_contract_rejected] kind instead of the catch-all bucket. *)
