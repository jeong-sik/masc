(** The effect boundary shared by current persisted-content readers.
    Call only after leaving Fs worker callbacks. *)
val emit : Board_content_json.diagnostic list -> unit
