(** Browser-specific, read-only model selection through the host Exact broker.
    No provider credentials, selectors, scripts or input actions cross here. *)
val output_name : string
val schema : Yojson.Safe.t
val for_owner : Browser_addon_owner.t -> (Browser_webdriver.locate option, string) result
(** None when not selected. A selected output must match the consumer contract
    before its backend is published. Each generation uses a fresh request ID
    bound to the original command's cancellation scope. *)
