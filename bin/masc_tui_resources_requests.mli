(** MCP resource and published report requests. [launch] is the caller's workspace
    JSON read boundary: it captures the expected root before dispatch, owns
    cancellation and stamps completion. Report GETs use [get_json] under that
    binding and require the server's admission receipt, including cache reuse. [check]
    rechecks the same captured authority after obtaining an MCP session. The
    list combines independent sources with their failure diagnostics. Reports
    use the token-bound admin API with a fixed revision and verified original body.
    Every list dispatch allocates a fresh owner before launching; superseded
    replies cannot replace a newer catalog or its completeness evidence. *)

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
