(** Stagehand's text/structured model callback through the Add-on's private
    shared Exact Output broker. This module resolves no provider or credentials. *)
val output_name : string
val schema : Yojson.Safe.t
(** Baseline for Stagehand structured object results, without an envelope.
    The SDK owns complete validation of each request's specific schema. *)
val for_owner : Browser_addon_owner.t ->
  (Browser_stagehand_session.model option, string) result
(** [None] when the output is not selected. A selected output must grant request
    schemas and match the consumer baseline before a browser is launched. The
    returned callback waits in the original Stagehand call's cancellation scope;
    retirement wakes it and an uncertain result never becomes an input retry.

    Roles and text-block order are preserved; text blocks within a turn join
    with two newlines. Image/tool blocks, non-structured generations and supplied
    temperature/stop options are explicitly refused before queue admission.
    This constructs the callback only; Chrome ownership is separate. *)
