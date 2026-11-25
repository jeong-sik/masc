(** CI, Release, and Front-Door CLI parser and TTY guard for [masc-tui].

    Preserves all verified contracts from [release-build.yml],
    [tui-native-proof.yml], and [bin/masc_front_door.ml]:
    - [--version] prints the build version with the embedded 8-char commit hash
      when available (e.g. [0.81.0 (2a58dc57)], or bare [0.81.0] if unembedded)
      and exits [0] without touching TTY.
    - [--build-commit] prints the embedded Git commit SHA and exits [0] (or
      exits [1] if unembedded) without touching TTY.
    - [--help] / [-h] documents [--port], [--base-path], [--url], [--theme],
      [--lang], [--no-auto-start], [--version], and [--build-commit] and exits
      [0] without touching TTY.
    - Non-TTY stdin/stdout or [TERM=dumb] returns exit code [2] with a clean
      stderr diagnostic. *)

open Masc_tui_core

val default_scheme : string
val default_host : string
val default_port : int

type config = {
  scheme : string;
  host : string;
  port : int;
  base_path : string;
  workspace : string;
  theme : Theme.preset;
  lang : Say.lang;
  theme_explicit : bool;
  lang_explicit : bool;
  auto_start : bool;
}

type info_action =
  | Print_version of string
  | Print_build_commit of string option
  | Print_help of string

type parse_outcome =
  | Run of config
  | Info of info_action
  | Parse_error of string

val help_text : string
(** Complete usage text documenting all supported CLI flags. *)

val parse_theme : string -> Theme.preset option
(** Strict parser accepting [midnight], [arcade] / [arcade_hi] / [arcade-hi],
    [paper] / [paper_light] / [paper-light], [mono], and [muted]. Returns
    [None] for any other string. *)

val parse_lang : string -> Say.lang option
(** Strict parser accepting [ko] and [en]. Returns [None] for any other string. *)

val parse_port : string -> (int, string) result
(** Strict parser accepting integers in [[1; 65535]]. *)

val parse_url : string -> (string * string * int option, string) result
(** Parse an [http://host[:port]] or [https://host[:port]] URL into
    [(scheme, host, port_opt)], rejecting unsupported schemes, blank hosts,
    trailing paths, or out-of-range ports. *)

val parse :
  ?version:string ->
  ?build_commit:string option ->
  ?env:(string -> string option) ->
  ?cwd:string ->
  string list ->
  parse_outcome
(** Pure CLI parser over argument list (excluding [argv.(0)]). Never performs
    TTY checks or calls [exit]. *)

type tty_check =
  | Tty_ok
  | Non_tty of { reason : string; exit_code : int }

val check_tty_pure :
  stdin_is_tty:bool ->
  stdout_is_tty:bool ->
  term_env:string option ->
  tty_check
(** Pure TTY policy check: rejects non-TTY stdin/stdout or [TERM=dumb] with
    [exit_code = 2]. *)

val check_tty : unit -> tty_check
(** Live process check against [Unix.stdin], [Unix.stdout], and [$TERM]. *)

type cli_dispatch =
  | Start of config
  | Exit of int

val parse_and_dispatch :
  ?argv:string array ->
  ?out_channel:out_channel ->
  ?err_channel:out_channel ->
  unit ->
  cli_dispatch
(** Parse [argv] (defaulting to [Sys.argv]), handle [--version],
    [--build-commit], [--help], and parse errors immediately without touching
    TTY, returning either [Start config] or [Exit code]. *)
