(* The contract lives in the .mli; this file adds the one backend that
   exists, over the spectator feed the MSX screen already polls. Game keys
   map to the machine's own vocabulary (up/down/left/right/space/return or
   one character); everything else returns unconsumed so the host's own
   bindings keep working — the spectator's "any other key repaints" stays
   the host's decision, not the surface's. *)

type frame = Pixels of { width : int; height : int; rgb : string }

module type S = sig
  val title : string

  val current : unit -> frame option

  val handle_input : string -> bool
end

(* Keys the shared machine understands. The press sink reports delivery;
   a key the machine refuses (unknown name, nobody loaded) is not consumed,
   so the host can still act on it. *)
let machine_key = function
  | "up" | "down" | "left" | "right" | "space" | "esc" | "return" | "enter"
  | "trigger_a" | "trigger_b" | "f1" | "f2" | "f3" | "f4" | "f5" ->
    true
  | k -> String.length k = 1 && Char.code k.[0] > 32 && Char.code k.[0] < 127
;;

let msx ~fetch ~press =
  (module struct
    let title = "MSX"

    let current () =
      Option.map
        (fun (f : Masc_tui_types.msx_frame) ->
          Pixels { width = f.msx_width; height = f.msx_height; rgb = f.msx_rgb })
        (fetch ())
    ;;

    let handle_input key =
      if key = "esc" then false
      else if machine_key key then press key
      else false
    ;;
  end : S)
;;
