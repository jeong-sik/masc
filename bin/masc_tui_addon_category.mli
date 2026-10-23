(** Reader-facing names for the shared Add-on role. Navigation information
    only: never a permission, service obligation or On/Off gate. *)
val label : Masc.Lane_addon_category.t -> string
val order : Masc.Lane_addon_category.t list
(** Display order of the groups. *)
val unclassified : string
