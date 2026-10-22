(** Trusted Curator binding used by the existing common Add-on Exact runner.
    This is validation only; it does not start an owner, worker or domain commit. *)
val package_id : string
val tool : string
val request : Workspace_memory_execution_capture.t -> (Lane_addon_exact.request, string) result
(** The original host request ID, complete rendered prompt and output schema.
    Classification and briefing have distinct declared output names. *)
val submit : Lane_addon_exact.request -> Yojson.Safe.t
(** The arguments of the worker [submit] call that carries one request. *)
val classification_submit_bytes : request_id:Workspace_memory_execution_capture.Request_id.t ->
  Workspace_memory_request.batch -> (int, string) result
(** {!Lane_addon_host_delivery.arguments_bytes} of the [submit] a classification
    capture of this batch would send under [request_id], before any capture
    exists. The same request and [submit] builders serve the actual send. *)
val check_frame : max_reply_bytes:int -> Workspace_memory_execution_capture.t -> (unit, string) result
(** Refuse a capture whose [submit] arguments exceed the receiving Add-on's
    declared frame. *)
val authorize : base_path:string -> store:Lane_addon_store.t -> declaration_id:string ->
  package:Lane_addon_types.package -> Lane_addon_exact.request ->
  (Lane_addon_exact.output_validator, string) result
(** Requests without a Curator capture keep other packages' baseline validation.
    All requests strictly read the original Curator namespace so relabeling a
    package cannot bypass a retained binding. An unreadable namespace refuses
    resolution rather than becoming absence. The Curator package must
    have a strict original capture at this exact installation/tool and physical
    workspace. A child additionally needs the strictly loaded acknowledged
    predecessor chain and exact whole-batch derivation, including direct Exact
    calls and retained delivery. Its complete common Exact request must equal
    the captured one.
    Missing/unreadable/conflicting authority refuses before route resolution,
    including retained-answer delivery. No current prompt override replaces it. *)
