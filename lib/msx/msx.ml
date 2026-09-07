(* 스텁 구현. Z80 은 P0, V9938 은 P1 이 만든다. 그때까지는 계약만
   지킨다: 순수, 결정론, 스텝 프레임. 테스트 패턴은 프레임 카운터의
   순수 함수다 — 같은 프레임 번호면 같은 그림이 나온다. *)

type key =
  | Up
  | Down
  | Left
  | Right
  | Space
  | Trigger_a
  | Trigger_b
  | Esc
  | Return
  | Function of int
  | Char of char

type machine = { ram_kb : int; vram_kb : int; roms : string list }

type t = {
  mutable frame : int;
  mutable rom : string option;
  mutable keys : key list; (* 눌림 집합. 순서는 최근 순. *)
  machine : machine;
}

let native_w = 256
let native_h = 212

(* 테스트 패턴용 8색. V9938 팔레트가 아니다. *)
let bars =
  [| (0, 0, 0); (0, 225, 0); (66, 225, 66); (131, 226, 131); (33, 33, 255); (224, 32, 32); (224, 224, 0); (224, 224, 224) |]

let create ~machine = { frame = 0; rom = List.nth_opt machine.roms 0; keys = []; machine }

let name t =
  Printf.sprintf "MSX %dKB RAM / %dKB VRAM (stub)" t.machine.ram_kb
    t.machine.vram_kb

let load_cartridge t rom = t.rom <- Some rom

let set_key t k ~pressed =
  if pressed then (
    if not (List.mem k t.keys) then t.keys <- k :: t.keys)
  else t.keys <- List.filter (fun x -> x <> k) t.keys

let step t ~frames = t.frame <- t.frame + frames

let frame_dims _ = (native_w, native_h)

let frame_rgb t =
  let b = Bytes.make (native_w * native_h * 3) '\000' in
  let put x y (r, g, bl) =
    if x >= 0 && x < native_w && y >= 0 && y < native_h then begin
      let i = (y * native_w + x) * 3 in
      Bytes.set b i (Char.chr r);
      Bytes.set b (i + 1) (Char.chr g);
      Bytes.set b (i + 2) (Char.chr bl)
    end
  in
  let fill x0 y0 w h col =
    for dy = 0 to h - 1 do
      for dx = 0 to w - 1 do
        put (x0 + dx) (y0 + dy) col
      done
    done
  in
  (* 상단 색바: 8칸 × 32px, 높이 48 *)
  for y = 0 to 47 do
    for x = 0 to native_w - 1 do
      put x y bars.(min (x / 32) 7)
    done
  done;
  (* 중단 격자: 16px 간격 십자점 *)
  for y = 64 to native_h - 32 do
    if y mod 16 = 0 then
      for x = 0 to native_w - 1 do
        put x y (40, 40, 40)
      done
  done;
  for x = 0 to native_w - 1 do
    if x mod 16 = 0 then
      for y = 64 to native_h - 32 do
        put x y (40, 40, 40)
      done
  done;
  (* 이동 박스: 위치는 프레임 카운터의 함수 (결정론) *)
  let bx = (t.frame * 3) mod (native_w - 16) in
  fill bx 96 16 16 (224, 224, 224);
  (* 눌린 키 표시: 개수만큼 파란 칩 *)
  let kc = List.length t.keys in
  for n = 0 to min kc 15 - 1 do
    fill (8 + n * 16) (native_h - 24) 12 12 (32, 32, 255)
  done;
  (* 카트리지 표시: 슬롯에 ROM 이 있으면 우상단 흰 박스 *)
  if Option.is_some t.rom then fill (native_w - 24) 8 16 8 (224, 224, 224);
  Bytes.to_string b

let serialize t = Marshal.to_string t []

let restore ~state = Marshal.from_string state 0
