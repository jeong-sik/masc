(** Capability probing that does not write into the keeper's conversation
    (RFC-0374).

    Asking "can keeper K reach tool T" used to cost a real turn, and a real
    turn is durable in the chat transcript, the checkpoint, and — through the
    librarian — the keeper's memory. Measurement therefore changed the thing
    it measured: on 2026-08-12 the librarian read accumulated probe traffic
    and committed a fact prescribing non-response to the probed tools, after
    which a zero result no longer distinguished "the runtime cannot reach the
    tool" from "the keeper declined" (masc#28414).

    This module answers the part of that question that needs no model at all.
    Whether MASC projects a tool into the surface it hands a client is decided
    by the descriptor table, so it is decidable offline, for free, and without
    touching any durable store.

    {1 What a positive answer does not mean}

    Projection is MASC's side of the wire; consumption is the client's. The
    two diverge — the antigravity bridge advertised 97 tools including every
    probed one, [initialize] and [tools/list] both answered, and the models
    still reported no masc tool present. So [Projected] means a turn is worth
    spending, and nothing more. Only observing an actual call establishes
    reachability.

    {1 Which lanes observe a call}

    {!probe_invocation} answers for Agent Core runtimes over HTTP;
    {!probe_official_client_invocation} answers for claude_code and
    codex_app_server by spawning their vendor client. Neither writes under a
    keeper: the Agent Core request carries no session, and the official-client
    entry points take no keeper name, so a probe turn opens a session of its
    own and abandons it.

    Antigravity is the one lane left open. Its entry point declares no tool
    list — MASC reaches it only through the per-turn MCP bridge — so the probe
    refuses with [Tools_only_via_mcp_bridge] rather than answering from a
    surface the client never consulted (masc#28414).

    @since 0.21.3 *)

(** Why a tool is or is not in the keeper-facing surface.

    The three negative cases are kept apart because they have different
    fixes: a name that does not exist is a caller error, an operator tool is
    working as designed, and an alias means the capability is present under
    a different name. Collapsing them into [false] is what made
    [masc_tasks] and [masc_status] look like the same failure during the
    2026-08-12 audit when they are not. *)
type verdict =
  | Projected of { model_facing_name : string }
      (** Reaches the model under this name. *)
  | Not_a_descriptor
      (** No descriptor declares this name, under any projection. *)
  | Operator_only
      (** Declared, but deliberately withheld from the autonomous model. *)
  | Aliased of { projected_by : string }
      (** Declared, but the capability reaches the model under another
          descriptor's name. Probing the requested name measures the alias
          policy rather than the runtime. *)
  | Withheld_by_schema_error of { errors : string list }
      (** Declared model-facing, but the surface drops it because its schema
          does not validate. Distinct from [Operator_only]: nobody chose this,
          and it is a defect in the descriptor rather than a policy. *)

val verdict_to_string : verdict -> string

(** Resolve [tool] against the keeper-facing tool surface.

    Pure: reads the descriptor table and nothing else. No provider call, no
    session, no filesystem write. Accepts either a public or an internal
    descriptor name, because both appear in operator-authored probe lists. *)
val probe_surface : tool:string -> verdict

(** Every name that reaches the keeper model, in descriptor order.

    Used to report what {e was} available when a probe asks for a name that is
    not, so the caller does not have to guess at a typo. *)
val model_facing_names : unit -> string list

(** {1 Invocation}

    [probe_surface] answers whether MASC offers the tool. It cannot answer
    whether the model picks it up, and the two diverge — see the header. This
    is the other half, for the Agent Core (HTTP) lane. *)

(** What one probe turn observed.

    [Replied_no_tool] and [Provider_rejected] are kept apart because the audit
    that motivated this module could not tell them apart: a turn that never
    reached the provider and a turn the model answered in prose both showed up
    as a zero. *)
type invocation =
  | Tool_invoked of
      { tool : string
      ; elapsed_s : float
      }
      (** The response carried a [ToolUse] block for the requested tool. *)
  | Other_tool_invoked of
      { requested : string
      ; invoked : string list
      ; elapsed_s : float
      }
      (** Tools were called, but not the one asked for. Distinct from silence:
          the surface reached the model and the model used it. *)
  | Replied_no_tool of
      { reply_bytes : int
      ; elapsed_s : float
      }
      (** The provider answered and the model called nothing. *)
  | Provider_rejected of { detail : string }
      (** The request never produced a response — quota, auth, transport. *)

val invocation_to_string : invocation -> string

(** Why a probe could not be attempted at all. *)
type invocation_error =
  | Not_on_surface of verdict
      (** [probe_surface] already answers this one; no turn is worth spending. *)
  | Unresolvable_runtime of string
  | Not_agent_core_lane of string
      (** {!probe_invocation} was asked about an official-client runtime.
          Use {!probe_official_client_invocation} instead, which spawns the
          vendor client rather than issuing an HTTP completion. *)
  | Not_official_client_lane of string
      (** {!probe_official_client_invocation} was asked about an Agent Core
          runtime. Use {!probe_invocation}. *)
  | Tools_only_via_mcp_bridge of string
      (** The Antigravity client takes no host-declared tool list: MASC reaches
          it only through the per-turn MCP bridge, so a probe would have to
          stand that bridge up before the question means anything. Reported
          rather than answered from a surface the client never consulted —
          the distinction F1 of the 2026-08-12 audit turned on. *)
  | Tool_schema_rejected of string

val invocation_error_to_string : invocation_error -> string

(** Send one synthetic turn to [runtime_id] and report whether [tool] was
    called.

    Writes nothing. There is no keeper name, no session, and no checkpoint in
    this path: the Agent Core lane is stateless per request, so isolation here
    is the absence of a session rather than a separate one.

    The turn goes through {!Keeper_provider_subcall.complete}, the same
    boundary the vision tool uses, so it inherits the resolved provider
    deadline instead of installing its own. *)
val probe_invocation
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> now:(unit -> float)
  -> runtime_id:string
  -> tool:string
  -> prompt:string
  -> unit
  -> (invocation, invocation_error) result

val probe_official_client_invocation
  :  mgr:_ Eio.Process.mgr
  -> clock:_ Eio.Time.clock
  -> fs:Eio.Fs.dir_ty Eio.Path.t
  -> base_path:string
  -> now:(unit -> float)
  -> runtime_id:string
  -> tool:string
  -> prompt:string
  -> unit
  -> (invocation, invocation_error) result
(** The same question for the claude_code and codex_app_server lanes, which
    answer it by spawning their vendor client rather than by an HTTP
    completion.

    Writes nothing under a keeper. The durable session those lanes own is a
    {i keeper-layer} construct: [Keeper_*_runtime] reads the previous
    settlement and asks for [Resume]. The runtime entry points take no keeper
    name at all, and this probe leaves the session mode at its default, so
    every probe turn opens a session of its own and abandons it. That is the
    isolation — the same shape as {!probe_invocation}'s absence of a session,
    reached differently.

    Evidence is stronger here than on the Agent Core lane: MASC hands the
    client a host-declared tool whose implementation records its own
    invocation, so a call is observed at the callback rather than inferred
    from response content.

    Antigravity is refused with {!Tools_only_via_mcp_bridge}: its entry point
    declares no tool list, so its surface exists only once the per-turn MCP
    bridge is up. Answering from MASC's descriptor table instead would repeat
    the 2026-08-12 mistake of reading advertisement as consumption. *)
