module Subscription = Masc.Lane_addon_subscription
type target = { installation_id:string; run_id:string; output_id:string; instance_id:string; title:string }
type reader_state = Unavailable of string | Position of {instance_id:string; acknowledged:int; latest:int; replaced:bool}
type snapshot = {revision:string option; entries:(Subscription.subscription * reader_state) list}
type request = Inspect | Save of {revision:string option; subscriptions:Subscription.subscription list}
type t
val initial : keepers:string list -> targets:target list -> t
val decode : Yojson.Safe.t -> (snapshot,string) result
val request_json : request -> Yojson.Safe.t
val loaded : t -> (snapshot,string) result -> t
val move : t -> int -> t
val add : t -> t
val remove : t -> t
val back : t -> t option
val enter : keepers:string list -> targets:target list -> t -> t * request option
val lines : t -> string list
