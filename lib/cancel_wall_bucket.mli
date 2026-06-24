(** Wall-clock duration bucket label for cancel/timeout metrics, shared by
    [keeper_llm_bridge] and [masc_oas_bridge] so the two metric sources keep
    identical boundaries and can be unioned in dashboards (#10942). *)

val of_wall : float -> string
(** Classify an elapsed wall-clock time in seconds into one bucket label:
    ["fast"] (<60), ["short_tail"] (<300), ["mid_tail"] (<600),
    ["long_mid"] (<1800), or ["long_tail"] (>=1800). *)
