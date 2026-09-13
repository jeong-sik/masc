module Reading = Masc.Tui_decode

(* Operator pause outranks the health reading: it is a person's decision about
   a keeper that may well be healthy, and a reader looking for why a keeper is
   quiet wants that answer first. *)
let paused_glyph = "\xe2\x97\x8b" (* ○ hollow: stopped on purpose *)
let unread_glyph = "-"

let health_glyph : Reading.keeper_health_reading -> string = function
  | Reading.Health_running -> "\xe2\x97\x8f" (* ● filled: alive and working *)
  | Reading.Health_idle -> "\xc2\xb7" (* · small: alive, nothing recent *)
  | Reading.Health_offline -> "\xc3\x97" (* × gone *)
  | Reading.Health_stale -> "?" (* the last signal is too old to trust *)
  | Reading.Health_degraded -> "!" (* its own status did not read *)
  | Reading.Health_zombie -> "\xe2\x80\xa1" (* ‡ an entry with no fiber *)

let glyph ~paused reading =
  match reading with
  | None -> unread_glyph
  | Some _ when paused -> paused_glyph
  | Some value -> health_glyph value

let legend =
  [ health_glyph Reading.Health_running, "healthy"
  ; health_glyph Reading.Health_idle, "idle"
  ; paused_glyph, "paused"
  ; health_glyph Reading.Health_stale, "stale"
  ; health_glyph Reading.Health_degraded, "degraded"
  ; health_glyph Reading.Health_zombie, "zombie"
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
  [ "HEALTH", "heartbeat / readiness"
  ; "LIFECYCLE", "the keeper process"
  ; "TURN", "time since the last turn"
  ; "Mode " ^ letters activation_letter activations, words activation_word activations
  ; "S " ^ letters sandbox_letter sandboxes, "sandbox: " ^ words sandbox_word sandboxes
  ]
