type eio_net = [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t

type t = {
  net : eio_net;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  mono_clock : Eio.Time.Mono.ty Eio.Resource.t;
  switch : Eio.Switch.t;
}

let create ~net ~clock ~mono_clock ~switch =
  { net; clock; mono_clock; switch }

let of_eio_context () =
  create
    ~net:(Eio_context.get_net ())
    ~clock:(Eio_context.get_clock ())
    ~mono_clock:(Eio_context.get_mono_clock ())
    ~switch:(Eio_context.get_switch ())

let net t = t.net
let clock t = t.clock
let mono_clock t = t.mono_clock
let switch t = t.switch
