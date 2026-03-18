(** Module-level Eio environment for LLM HTTP calls via Llm_provider.
    Set once at server startup via {!init}.

    The switch and net handle are needed by [Llm_provider.Complete.complete]
    which uses cohttp-eio for HTTP transport.

    @since 2.103.0 — v0.49 curl-subprocess replacement *)

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
  | None -> failwith "Llm_eio_env not initialized: call init at server startup"

let get_opt () = Atomic.get env
