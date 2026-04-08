(** Module-level Eio environment for OAS HTTP calls.
    Set once at server startup via {!init}.

    The switch and net handle are needed by OAS provider completions
    which use cohttp-eio for HTTP transport.

    @since 2.130.0 *)

type t = {
  sw : Eio.Switch.t;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t option;
}

let env : t option Atomic.t = Atomic.make None

let init ~sw ~net ?clock () = Atomic.set env (Some { sw; net; clock })

let get () =
  match Atomic.get env with
  | Some e -> e
  | None -> raise (Failure "Masc_eio_env not initialized: call init at server startup")

let get_opt () = Atomic.get env
