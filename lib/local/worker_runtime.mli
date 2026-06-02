(** Worker_runtime — local agent runtime with worker containers,
    OAS/legacy backends, and heartbeat management.

    Facade re-exporting [Worker_container_runners], which itself
    transitively includes [Worker_container] and
    [Worker_container_types]. Callers reach
    [run_worker_oas], [list_masc_tools], and
    [parse_text_tool_calls] through this module. *)

include module type of Worker_container_runners
