(** Per-domain Eio environment for OAS HTTP calls.
    Set once per OCaml domain via {!init}.

    The switch and net handle are needed by OAS provider completions
    which use cohttp-eio for HTTP transport.  They are stored in
    [Domain.DLS] so each domain can hold its own handles, with a process-wide
    compatibility fallback for domains that have not been explicitly
    initialized yet.

    @since 2.130.0 *)

type t = {
  sw : Eio.Switch.t;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t option;
}

let env_key : t option Domain.DLS.key = Domain.DLS.new_key (fun () -> None)
let process_env : t option Atomic.t = Atomic.make None

let init ~sw ~net ?clock () =
  let env = { sw; net; clock } in
  Domain.DLS.set env_key (Some env);
  Atomic.set process_env (Some env)

let reset_for_test () =
  Domain.DLS.set env_key None;
  Atomic.set process_env None

let get_opt () =
  match Domain.DLS.get env_key with
  | Some _ as env -> env
  | None -> Atomic.get process_env

let get () =
  match get_opt () with
  | Some e -> e
  | None -> invalid_arg "Masc_eio_env.get: not initialized. Call init at server startup."
