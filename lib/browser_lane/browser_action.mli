(** Closed Firefox interactions. Arguments are parsed before any browser effect. *)
type key = Enter | Tab | Escape | Backspace | Delete | ArrowUp | ArrowDown | ArrowLeft | ArrowRight | Home | End
type interaction =
  | Click of string
  | Fill of { selector : string; text : string }
  | Press of { selector : string; key : key }
  | Select of { selector : string; value : string }
  | Scroll of { x : int; y : int }
  | Upload of { selector : string; paths : string list }
  | Accept_dialog of string option | Dismiss_dialog
  | Back | Forward | Reload | Close_tab
type t = Open_tab of string | On_tab of { tab_id : int; frame_path : string list; interaction : interaction }
val parse : Yojson.Safe.t -> (t, string) result
val to_json : t -> Yojson.Safe.t
val key_name : key -> string
val webdriver_key : key -> string
val parse_frame_path : Yojson.Safe.t -> (string list, string) result
