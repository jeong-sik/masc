(** What a construct outside the subset means for the caller.

    RFC execute-subset-dispositions §3.1 wrote this module while the subset was
    what ran: every arm of {!Masc_exec.Parsed.reason_too_complex} was a
    refusal, and a caller told only "refused" has one move left, which is to
    send the same text through [sh -c] and lose every guarantee the gate
    applies. So a refusal became a rewrite.

    RFC execute-boundary-is-the-sandbox removed the refusal. [script] is a
    shell and an argv-shaped shell normalises into it, so a caller who wrote
    [$(...)], [$PWD] or a loop wrote something that works. Advice against it
    is not stale, it is wrong -- on 2026-08-31 a keeper was told "this tool
    runs no shell" about a working [$PWD] and rewrote it into an absolute
    path, which is the same trip this module exists to stop.

    What survives is where another form is still the better call:

    - [&] leaves a child the shell's exit orphans, and Spawn is the tool that
      returns a handle for one;
    - a nested pipeline is what {!Connector} names. The typed [pipeline]
      field is gone from the Execute schema, so this arm is unreachable until
      the Shell IR parser judges [script] (RFC-execute-boundary-is-the-sandbox).

    Everything else answers {!Unrepresentable}: the shell runs the line, and
    the only thing worth adding is that argv is the form that gets path
    scope.

    {!of_reason} stays exhaustive. A construct cannot join the excluded list
    without someone choosing whether the caller should have done anything
    else. *)

type field = Connector
(** Where a rewrite points a caller who nested one pipeline inside another:
    at the connector between stages, so each stage is named once.

    Not a field of the Execute schema. It read as one when the schema carried
    a typed [pipeline]; since #32650 the schema is [argv], [script], [shell],
    [cwd], [timeout_sec], and this arm is unreachable until the Shell IR
    parser judges [script] -- the same note {!of_reason} carries above. *)

type call =
  | Spawn
      (** a process that outlives the call needs the handle, not this tool *)

type t =
  | Move_to_field of {
      field : field;
      because : string;
    }  (** the schema already has somewhere to put this *)
  | Call_this_instead of {
      call : call;
      because : string;
    }  (** a call the caller can make now *)
  | Spell_it_as of {
      spelling : string;
      because : string;
    }
      (** the same call, written the way this tool spells it. [&>out] is one
          operator for something the subset writes as two, and neither the
          call nor the field changes. *)
  | Unrepresentable of {
      construct : Masc_exec.Parsed.reason_too_complex;
      because : string;
    }
      (** no rewrite exists. The only arm that is genuinely a refusal, and it
          says why rather than only that. *)

val of_reason : Masc_exec_command_gate.Shell_command_gate.too_complex_reason -> t
(** The rewrite for a construct the subset excluded. Total and exhaustive. *)

val to_string : t -> string
(** One line, for a log or a message back to the caller: what to do, and why
    this construct needs it. *)

val tag : t -> string
(** Closed-vocabulary tag for aggregation, coarser than {!to_string}. *)
