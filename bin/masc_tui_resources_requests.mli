(** MCP resource and published report requests. [launch] is the caller's workspace request boundary:
    it checks endpoint identity, owns cancellation and stamps completion. [check]
    rechecks the same captured authority after obtaining an MCP session. The
    list combines independent sources with their failure diagnostics. Reports
    use the token-bound admin API with a fixed revision and verified original body. *)

val launch_list
  :  Masc_tui_types.state
  -> host:string
  -> launch:
       (deliver:
          ((Masc_tui_resource_catalog.listing, string) result
           -> Masc_tui_async_protocol.async_msg)
        -> (unit
            -> (Masc_tui_resource_catalog.listing, string) result)
        -> unit)
  -> check:(unit -> (unit, string) result)
  -> unit

(** Mark the pending key before launching. Changing resources clears the old
    content, error and scroll; re-reading the same resource keeps its content.
    Selection is retained while authority is unconfirmed, without invoking
    [launch] or [check]. Same-workspace recovery resumes the pending key;
    foreign-workspace reconciliation clears it. Resource_read failure
    attribution is applied exactly once. Every launched read has a fresh owner;
    a superseded response cannot settle a later request for the same key. *)
val launch_read
  :  Masc_tui_types.state
  -> host:string
  -> launch:
       (deliver:
          ((Masc_tui_resource_catalog.reading, string) result
           -> Masc_tui_async_protocol.async_msg)
        -> (unit -> (Masc_tui_resource_catalog.reading, string) result)
        -> unit)
  -> check:(unit -> (unit, string) result)
  -> key:Masc_tui_resource_catalog.key
  -> unit
