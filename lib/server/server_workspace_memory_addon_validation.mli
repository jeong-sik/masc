(** Trusted Curator binding used by the existing common Add-on Exact runner.
    This is validation only; it does not start an owner, worker or domain commit. *)
val package_id : string
val tool : string
val request : Workspace_memory_execution_capture.t -> (Lane_addon_exact.request, string) result
(** The original host request ID, complete rendered prompt and output schema.
    Classification and briefing have distinct declared output names. *)
val authorize : base_path:string -> Lane_addon_exact.validation_authority
(** Requests without a Curator capture keep other packages' baseline validation.
    All requests strictly read the original Curator namespace so relabeling a
    package cannot bypass a retained binding. An unreadable namespace refuses
    resolution rather than becoming absence. The Curator package must
    have a strict original capture at this exact installation/tool and physical
    workspace. Its complete common Exact request must equal the captured one.
    Missing/unreadable/conflicting authority refuses before route resolution,
    including retained-answer delivery. No current prompt override replaces it. *)
