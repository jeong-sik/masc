(** Closed Firefox interactions. Arguments are parsed before any browser effect. *)
type key = Enter | Tab | Escape | Backspace | Delete | ArrowUp | ArrowDown | ArrowLeft | ArrowRight | Home | End
type interaction =
  | Click of string
  | Fill of { selector : string; text : string }
  | Press of { selector : string; key : key }
  | Select of { selector : string; value : string }
  | Scroll of { x : int; y : int }
  | Back | Forward | Reload | Close_tab
type t = Open_tab of string | On_tab of { tab_id : int; interaction : interaction }
val parse : Yojson.Safe.t -> (t, string) result
val to_json : t -> Yojson.Safe.t
val key_name : key -> string
val webdriver_key : key -> string
