(** How a Keeper prompt writes an age: whole seconds under a minute, whole
    minutes under an hour, then hours and minutes ([4h00m]). A negative age
    reads as [0s]. *)
val of_seconds : float -> string
