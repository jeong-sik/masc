(** Runtime_official_client_tool — the dynamic-tool contract the official
    client runtimes share.

    A dynamic tool is one the keeper hands to a running provider session at
    turn time rather than one baked into the runtime. {!Runtime_claude_code}
    and {!Runtime_codex_app_server} both take a list of them, and
    {!Keeper_official_client_host} builds that list; all three declared the
    same record independently, so every hand-off between them needed a
    field-for-field copy to cross the nominal type boundary. The record lives
    here once and the three re-export it by type equation, which makes those
    copies unnecessary rather than merely shorter. *)

type dynamic_tool_result =
  { success : bool
  ; content : string
  ; abort_turn : string option
    (** Host-owned terminal reason. The transport returns the current tool
        outcome, then stops the provider loop instead of admitting another
        tool call. *)
  }

type dynamic_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; call : call_id:string -> Yojson.Safe.t -> dynamic_tool_result
  }

val dynamic_tool_bytes : dynamic_tool list -> int
(** [dynamic_tool_bytes tools] sums the name, description and serialized
    schema lengths. Bytes this process sends, not provider tokens. *)
