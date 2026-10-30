(** Loopback Gecko driver command. Each session names its own profile with
    [-profile], so the driver makes none. geckodriver writes
    [marionette.port] 0 into that profile, so each browser picks its own
    Marionette port and reports it in the profile's [MarionetteActivePort]. *)
val argv : driver:string -> port:int -> string list
