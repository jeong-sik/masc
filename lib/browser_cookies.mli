(** The cookies an owned Firefox tab's page can see, as the W3C WebDriver
    [Get All Cookies] command returns them, without their values. A cookie value is
    a credential, so only what identifies and scopes the cookie is kept. *)

(** At most this many cookies are returned, and the reply says how many there were. *)
val cookies_limit : int

(** Projects the driver's cookie list. A reply that is not a list of cookie
    objects with a name is an error, not an empty answer. *)
val of_driver : Yojson.Safe.t -> (Yojson.Safe.t, string) result
