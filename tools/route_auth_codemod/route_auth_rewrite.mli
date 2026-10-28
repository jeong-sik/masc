(** Rewrites route registrations to the typed form of [Server_route].

    A registration like

    {[
      |> Http.Router.get "/x" (fun request reqd ->
           with_public_read (fun state req reqd -> ...) request reqd)
    ]}

    becomes

    {[
      |> Server_route.get Server_route.Public_read "/x" (fun state req reqd -> ...)
    ]}

    The edit is made on the source text. The compiler parser gives the byte range
    of the registration function, of the handler and of the handler inside the
    wrapper; the first is replaced by the typed function with its kind, the
    second by the text of the third, and every other byte stays as it was. This is
    what [Server_route] does at run time, so the route answers as before:
    [wrapper args h] is [fun request reqd -> wrapper args h request reqd] for each
    wrapper of [Server_auth], because each takes [request] and [reqd] as its last
    two parameters, computes nothing before it has them, and hands the same
    [request] and [reqd] on to the handler.

    Four things the plain unwrapping does not cover:

    - The wrapped handler reads the [request] or [reqd] of the function that is
      removed. Those names would be unbound. The parameter of the wrapped handler
      in the same position holds the same value, so it takes the outer name when
      it is unused, and the handler starts with [let request = req in] when it is
      used. A handler that also binds the name deeper down is left alone.
    - A comment sits between the removed function and the wrapper. It moves,
      verbatim, above the line of the registration.
    - The handler is a name, and the file defines it as
      [let name request reqd = wrapper ... request reqd] (or [let name = wrapper
      ...]). The wrapper moves to the registrations: the definition becomes
      [let name = <inner handler>] and each registration takes the kind. This
      is done only when the file has one binding of the name, all its uses are
      later registration handlers within the definition's lexical structure,
      and the moved wrapper arguments have no intervening lexical ambiguity. The
      source-only check conservatively
      skips later shadowing, opens, includes, extensions and unsupported argument
      forms. A name that other code calls with a request and a reqd is left
      alone. The caller must separately check for uses in other files, which
      this file-local analysis cannot see.
    - The wrapper's argument ([~permission], [~tool_name]) is a computation, not a
      constant. A typed route records it at registration, where before it was
      evaluated on every request. The registration is left alone unless
      [~early:true] says that is acceptable, and then it is listed in
      [report.early] so the expressions can be read.

    The tool finds a wrapper by the last component of its name, so it assumes no
    file defines or aliases [with_read_auth] and the other six itself. That holds
    for lib/server today and is the first thing to check again before a run.
    The rewrite can leave [open Server_auth] unused; the compiler names those
    (warning 33) and the lines go.

    A registration the tool cannot rewrite without a decision is left as it is and
    listed with the reason. *)

type site =
  { line : int
  ; path : string  (** The route path, or ["<non-literal>"]. *)
  ; note : string
  }

type report =
  { converted : int  (** Registrations rewritten. *)
  ; definitions : int  (** Named handlers that lost their wrapper. *)
  ; unhandled : site list  (** Left as they were; [note] is the reason. *)
  ; early : site list
        (** Converted; [note] is the argument now evaluated once. For a named
            handler, [path] is its name. *)
  }

(** [rewrite ~file source] returns the rewritten source and what was done, or the
    parse error. [file] is only used in that error. Running [rewrite] on its own
    output converts nothing. *)
val rewrite : ?early:bool -> file:string -> string -> (string * report, string) result
