module Reading = Masc.Tui_decode

(* Operator pause outranks the health reading: it is a person's decision about
   a keeper that may well be healthy, and a reader looking for why a keeper is
   quiet wants that answer first. *)
let paused_glyph = "\xe2\x97\x8b" (* ○ hollow: stopped on purpose *)
let unread_glyph = "-"

let health_glyph : Reading.keeper_health_reading -> string = function
  | Reading.Health_running -> "\xe2\x97\x8f" (* ● filled: keepalive running, has turned *)
  | Reading.Health_idle -> "\xc2\xb7" (* · small: keepalive running, no turn yet *)
  | Reading.Health_failing -> "!" (* keepalive running, its turns failing *)
  | Reading.Health_offline -> "\xc3\x97" (* × gone *)

let glyph ~paused reading =
  match reading with
  | None -> unread_glyph
  | Some _ when paused -> paused_glyph
  | Some value -> health_glyph value

type open_turn = Worked | Worked_while_failing | Left_open

let open_turn = function
  | Some Reading.Health_offline -> Left_open
  | Some Reading.Health_failing -> Worked_while_failing
  | Some (Reading.Health_running | Reading.Health_idle) | None -> Worked

type turn_clock =
  | Open_turn_started of float
  | Last_turn_recorded of float
  | No_turn_recorded

(* The open turn wins because it is what the keeper is doing now. The last
   recorded turn is a finished one: on a failing keeper it is the failure, and
   drawn beside a moving mark its age read as the age of the work in progress
   (code-reviewer, 2026-09-24: "7m45s" was a failure from before a restart,
   under a turn that had run for half a minute). *)
let turn_clock ~(turn : Reading.keeper_turn_state option) ~last_turn_at =
  match turn with
  | Some (Reading.Keeper_turn_running { started_at_unix; _ }) ->
      Open_turn_started started_at_unix
  | Some Reading.Keeper_turn_idle | Some (Reading.Keeper_turn_unavailable _) | None -> (
      match last_turn_at with
      | Some at -> Last_turn_recorded at
      | None -> No_turn_recorded)

let legend =
  [ health_glyph Reading.Health_running, "healthy"
  ; health_glyph Reading.Health_failing, "failing"
  ; health_glyph Reading.Health_idle, "idle"
  ; paused_glyph, "paused"
  ; health_glyph Reading.Health_offline, "offline"
  ; unread_glyph, "unread"
  ]

(* The roster's Mode S cell: a letter for how the keeper is started and a
   letter for the sandbox its row declares. The letters and the words the
   sheet prints for them are declared together, so the cell and its
   explanation cannot drift apart. *)
let activation_letter : Reading.keeper_activation_mode -> string = function
  | Reading.Activation_manual -> "M"
  | Reading.Activation_on_demand -> "D"
  | Reading.Activation_autonomous -> "A"

let activation_word : Reading.keeper_activation_mode -> string = function
  | Reading.Activation_manual -> "manual"
  | Reading.Activation_on_demand -> "on demand"
  | Reading.Activation_autonomous -> "autonomous"

let activations =
  [ Reading.Activation_manual; Reading.Activation_on_demand; Reading.Activation_autonomous ]

type sandbox = Docker | Microvm | Local

let sandbox_of_profile = function
  | "docker" -> Some Docker
  | "microvm" -> Some Microvm
  | "local" -> Some Local
  | _ -> None

let sandbox_letter = function Docker -> "D" | Microvm -> "M" | Local -> "L"
let sandbox_word = function Docker -> "docker" | Microvm -> "microvm" | Local -> "local"
let sandboxes = [ Docker; Microvm; Local ]

let column_legend =
  let letters letter values = String.concat "/" (List.map letter values) in
  let words word values = String.concat " / " (List.map word values) in
  [ "HEALTH", "keepalive / turn history"
  ; "LIFECYCLE", "the keeper process"
  ; "TURN", "open turn's run time, else time since the last turn"
  ; "Mode " ^ letters activation_letter activations, words activation_word activations
  ; "S " ^ letters sandbox_letter sandboxes, "sandbox: " ^ words sandbox_word sandboxes
  ]
