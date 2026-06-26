(** Masc_eio_env — Eio environment for OAS HTTP calls.
    The switch and net handle are needed by OAS provider completions
    which use cohttp-eio for HTTP transport. *)

type t = {
  sw : Eio.Switch.t;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t option;
}
