type eio_net = [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t

type t

val create :
  net:eio_net ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  mono_clock:Eio.Time.Mono.ty Eio.Resource.t ->
  switch:Eio.Switch.t ->
  t

val of_eio_context : unit -> t

val net : t -> eio_net

val clock : t -> float Eio.Time.clock_ty Eio.Resource.t

val mono_clock : t -> Eio.Time.Mono.ty Eio.Resource.t

val switch : t -> Eio.Switch.t
