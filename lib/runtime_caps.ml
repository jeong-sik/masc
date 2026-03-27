type eio_net = [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t

type t = {
  net : eio_net;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  mono_clock : Eio.Time.Mono.ty Eio.Resource.t;
  switch : Eio.Switch.t;
}

let create ~net ~clock ~mono_clock ~switch =
  { net; clock; mono_clock; switch }

let of_eio_context_opt () =
  match
    ( Eio_context.get_net_opt (),
      Eio_context.get_clock_opt (),
      Eio_context.get_mono_clock_opt (),
      Eio_context.get_switch_opt () )
  with
  | Some net, Some clock, Some mono_clock, Some switch ->
      Some (create ~net ~clock ~mono_clock ~switch)
  | _ -> None

let of_eio_context () =
  match of_eio_context_opt () with
  | Some caps -> caps
  | None ->
      invalid_arg
        "Runtime_caps unavailable - ensure Eio context is fully initialized"

let net t = t.net
let clock t = t.clock
let mono_clock t = t.mono_clock
let switch t = t.switch
