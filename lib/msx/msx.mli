(** ocaml-msx 코어 계약.

    코어는 순수하다: 시간, 파일, 난수, 터미널을 스스로 읽지 않는다.
    프레임은 {!step} 호출로만 진행한다. 그래서 같은 상태와 같은 입력
    시퀀스는 항상 같은 프레임을 내고, {!serialize}/{!restore} 로 구간을
    재현할 수 있다. 실시간 재생(60fps)은 클라이언트가 [step] 을 언제
    부를지로 정하는 일이지 코어의 상태가 아니다.

    지금 구현은 스텁이다. Z80 과 V9938 은 아직 없고 {!frame_rgb} 는
    테스트 패턴을 낸다. 함수 모양은 최종본과 같다: 클라이언트(masc TUI
    탭, keeper 도구, bin/msx_demo)는 이 인터페이스를 대상으로 지금부터
    붙는다. *)

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
  | Function of int  (** MSX 기능키 F1–F5 *)
  | Char of char  (** 문자 키. 매트릭스 배선은 코어의 일 *)

type machine = {
  ram_kb : int;  (** 64 / 128 / 256 *)
  vram_kb : int;  (** 128 (MSX2) *)
  roms : string list;  (** 슬롯에 올릴 ROM 바이트. C-BIOS 등 *)
}

type t

val create : machine:machine -> t

val name : t -> string
(** 기계명. UI 표시용. *)

val load_cartridge : t -> string -> unit
(** 카트리지 ROM 바이트를 슬롯에 올린다. *)

val set_key : t -> key -> pressed:bool -> unit
(** 논리 키를 누른다/뗀다. 여러 클라이언트가 같은 키를 함께 누를 수
    있으므로 소유자 구분은 코어 밖의 집합이 관리하고, 코어는 최종
    눌림 상태만 받는다. *)

val step : t -> frames:int -> unit
(** [frames] 프레임만큼 진행. 한 프레임은 1/60 초 상당의 기계 사이클. *)

val frame_dims : t -> int * int
val frame_rgb : t -> string
(** 마지막 프레임의 네이티브 해상도 RGB (row-major, 채널 순서 R,G,B,
    길이 [w * h * 3]). 다운샘플은 클라이언트 몫이다. *)

val serialize : t -> string
(** savestate. 버전 태그를 앞에 붙인다. *)

val restore : state:string -> t
(** {!serialize} 결과로 기계를 되살린다. 포맷이 다르면 실패한다 —
    옛 포맷 변환기는 만들지 않는다 (하드컷). *)
