(** Environment inherited by the browser Add-on launcher, worker and its
    browser/driver children. Browser configuration is supplied through the
    private admission, and model credentials are resolved only by the host. *)

val project : string array -> string array
(** Copy only explicitly supported process, locale, desktop and certificate
    settings from a [Unix.environment]-shaped array. Preserve their original
    values, including [HOME]; omit all other entries, including unconfigured
    provider credentials. This does not modify the host environment or create
    an operating-system sandbox. *)
