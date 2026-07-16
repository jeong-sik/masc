(** Per-domain Eio environment for OAS HTTP calls.
    Set once per OCaml domain via {!init}.

    The switch and net handle are needed by OAS provider completions
    which use cohttp-eio for HTTP transport. They are stored in
    [Domain.DLS] only; a consumer that needs them must call {!init} in its
    own domain. Falling back to another domain's [Eio.Switch.t] or
    [Eio.Net.t] would let a worker domain borrow handles whose lifetime is
    tied to the originating domain's switch, which is unsafe.

    @since 2.130.0 *)

type t = {
  sw : Eio.Switch.t;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
}

let env_key : t option Domain.DLS.key = Domain.DLS.new_key (fun () -> None)

let init ~sw ~net ~clock () =
  Domain.DLS.set env_key (Some { sw; net; clock })

let reset_for_test () =
  Domain.DLS.set env_key None

let get_opt () = Domain.DLS.get env_key

let get () =
  match get_opt () with
  | Some e -> e
  | None -> invalid_arg "Masc_eio_env.get: not initialized. Call init at server startup."
