(** The masc pad (RFC play-link-for-the-shared-machine §2.9): one gamepad in
    front of every game, laid out per game onto the DOS machine's keys.

    The machine's input does not change. A button stands for a list of
    [masc_dos_press] key names, and pressing it presses those keys, so the
    ledger records machine keys as it always has. A layout names only the
    buttons it binds; any other button is unbound and pressing it is
    refused. *)

(** The buttons, named as Linux names gamepad buttons (evdev [BTN_*]); RFC
    machine-spectating-goes-through-lanes §3 chose that shape. *)
type button =
  | South  (** BTN_SOUTH: A on an Xbox pad, × on a PlayStation pad *)
  | East  (** BTN_EAST *)
  | North  (** BTN_NORTH *)
  | West  (** BTN_WEST *)
  | Dpad_up
  | Dpad_down
  | Dpad_left
  | Dpad_right
  | Start
  | Select
  | Tl  (** BTN_TL: the left shoulder *)
  | Tr  (** BTN_TR: the right shoulder *)

val all_buttons : button list
val button_to_string : button -> string
(** ["BTN_SOUTH"], ["BTN_DPAD_UP"], ... *)

val button_of_string : string -> (button, string) result

type binding =
  { keys : string list  (** non-empty, each one {!Dos_lane.check_key_name} accepts *)
  ; label : string  (** what the button does in this game, for the person holding it *)
  }

type layout

val bindings : layout -> (button * binding) list
(** Bound buttons, in {!all_buttons} order. *)

val binding : layout -> button -> binding option

val parse : string -> (layout, string) result
(** A layout file: one table per bound button, named as {!button_to_string}
    names it, each with [keys] (a non-empty array of key names) and [label]
    (a non-empty string). An unknown table, field or key name is an error,
    not an unbound button: a typo would otherwise leave a button that
    silently does nothing. *)

type source =
  | Workspace  (** [<.masc>/dos/pads/<saves name>.toml] *)
  | Builtin  (** shipped with masc *)

val source_to_string : source -> string

val pads_dir : base_path:string -> string
(** [<.masc>/dos/pads], beside the DOS checkpoints. Not inside a program's
    directory: [masc_dos_load] mounts what sits beside the executable into
    DOS, so a layout there would show up inside the game. *)

val load : base_path:string -> saves_name:string -> ((source * layout) option, string) result
(** The layout for the program loaded under [saves_name]: the workspace file
    when there is one, else the builtin one, else [None]. Only a genuinely
    absent workspace path permits fallback. An unreadable path, dangling link,
    non-regular file or malformed layout is an error. A symlink to a readable
    regular file remains a workspace override. The opened descriptor is checked
    before reading; a FIFO is never accepted as layout contents. *)
