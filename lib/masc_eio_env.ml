(** Per-domain Eio environment for OAS HTTP calls.
    Set once per OCaml domain via {!init}.

    The switch and net handle are needed by OAS provider completions
    which use cohttp-eio for HTTP transport.  They are stored in
    [Domain.DLS] so each domain holds its own handles; this removes the
    module-level Atomic global and avoids cross-domain [Eio.Switch]
    access errors.

    @since 2.130.0 *)

type t = {
  sw : Eio.Switch.t;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t option;
}

let env_key : t option Domain.DLS.key = Domain.DLS.new_key (fun () -> None)

let init ~sw ~net ?clock () = Domain.DLS.set env_key (Some { sw; net; clock })

let reset_for_test () = Domain.DLS.set env_key None

let get () =
  match Domain.DLS.get env_key with
  | Some e -> e
  | None -> invalid_arg "Masc_eio_env.get: not initialized. Call init at server startup."

let get_opt () = Domain.DLS.get env_key
