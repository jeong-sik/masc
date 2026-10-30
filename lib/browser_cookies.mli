(** The cookies an owned Firefox tab's page can see, as the W3C WebDriver
    [Get All Cookies] command returns them, without their values. A cookie value is
    a credential, so only what identifies and scopes the cookie is kept. *)

(** At most this many cookies are returned, and the reply says how many there were. *)
val cookies_limit : int

(** Projects the driver's cookie list. A reply that is not a list of cookie
    objects with a name is an error, not an empty answer. *)
val of_driver : Yojson.Safe.t -> (Yojson.Safe.t, string) result

(** Web storage and IndexedDB names for the page's origin. Only key names,
    database names and counts are read, never a value. *)
val storage_names_limit : int
val storage_name_chars : int
val storage_script : string
(** Synchronous: [{origin, localStorage, sessionStorage}], each area
    [{count, keys, truncated}] or [{error}]. *)

val indexeddb_script : string
(** Asynchronous (WebDriver [execute/async]): [{count, names, truncated}],
    [{unsupported}] or [{error}]. *)

val with_storage : web:Yojson.Safe.t -> indexeddb:Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t
(** Adds both under [storage] to a projected cookie reply. *)
