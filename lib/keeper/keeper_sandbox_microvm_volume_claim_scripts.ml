module Backend = Keeper_microvm_backend
open Keeper_sandbox_microvm_base

(* ── The work volume claims marker ────────────────────────────────────
   Volume names carry the keeper name but not its workspace, so two
   workspaces running same-named keepers share one work volume and neither
   can tell whether the other still wants it. A claim is the base path of a
   workspace whose keeper boots onto the volume, recorded in a marker file
   at the volume root. The marker sits above the keeper's jailed work root
   and is written by root helpers only, so the guest's user can neither
   create nor delete it. *)

let volume_claims_marker_name = ".masc-volume-claims.json"
let claims_guest_root = "/masc-claims"
let volume_claimant_env_var = "MASC_VOLUME_CLAIMANT"

let volume_claim_helper_name ~keeper_name =
  Keeper_sandbox_container_name.make
    (Keeper_sandbox_container_name.Micro_vm_volume_claim { keeper_name })
  |> Keeper_sandbox_container_name.to_string
;;

(* A claimant travels in one [--env] argument and is written inside JSON
   string quotes by the helper scripts, which do no escaping of their own:
   a base path carrying a quote, a backslash or a control character is
   refused here rather than silently mangled. Everything else a real base
   path contains -- spaces, unicode, '$', '%' -- travels as data. *)
let valid_volume_claimant claimant =
  claimant <> ""
  && String.for_all
       (function
         | '"' | '\\' | '\x7f' -> false
         | c -> c >= ' ')
       claimant
;;

(* The marker is one JSON array, one claimant per line, so the scripts can
   match a whole element by quoting it and never drop a claim they read.
   The [add] script only inserts: it re-emits every element it recognized
   and ours. The [release] script filters ours out and regenerates; when
   ours was the last claim the marker file is removed instead. Both refuse
   a marker outside the complete line-oriented array they know how to write,
   and both land the new file with one [mv], which is atomic on the same
   filesystem. Reading is [cat] alone, so the host's strict decoder parses
   that response. The byte comparison requires [cmp]; if the image lacks it,
   an existing marker is refused without modification. *)
let volume_claim_validate_script =
  {sh|validate_claim_line() {
  case "$1" in
    '"'*'"') value=${1#\"}; value=${value%\"} ;;
    *) return 1 ;;
  esac
  case "$value" in
    ''|*'"'*|*\\*|*[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}
validate_marker() {
  state=open
  while :; do
    line=
    if IFS= read -r line; then newline=1
    elif [ -n "$line" ]; then newline=0
    else break; fi
    case "$state" in
      open)
        [ "$line" = '[' ] || return 1
        state=first ;;
      first)
        if [ "$line" = ']' ]; then state=closed
        else validate_claim_line "$line" || return 1; state=next; fi ;;
      next)
        if [ "$line" = ']' ]; then state=closed
        else
          case "$line" in
            ,*) validate_claim_line "${line#,}" || return 1 ;;
            *) return 1 ;;
          esac
        fi ;;
      closed) return 1 ;;
    esac
    if [ "$newline" -eq 1 ]; then printf '%s\n' "$line"
    else printf '%s' "$line"; fi
  done < "$marker"
  [ "$state" = closed ]
}|sh}
;;

let volume_claim_add_script_with ~marker =
  Printf.sprintf
    {sh|set -eu
LC_ALL=C
export LC_ALL
marker=%s
%s
tmp=$marker.tmp
if ! command -v cmp >/dev/null 2>&1; then
  printf 'claims marker byte comparison is unavailable\n' >&2
  exit 1
fi
if [ -f "$marker" ]; then
  if ! validate_marker > "$tmp" || ! cmp -s "$marker" "$tmp"; then
    rm -f "$tmp"
    printf 'claims marker is not a complete supported array\n' >&2
    exit 1
  fi
  rm -f "$tmp"
fi
printf '[\n' > "$tmp"
first=1
present=0
if [ -f "$marker" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '['|']') ;;
      *)
        elem=${line#,}
        case "$elem" in
          '"'*'"')
            elem=${elem#\"}; elem=${elem%%\"}
            if [ "$elem" = "$MASC_VOLUME_CLAIMANT" ]; then present=1
            elif [ "$first" -eq 1 ]; then printf '"%%s"\n' "$elem" >> "$tmp"; first=0
            else printf ',"%%s"\n' "$elem" >> "$tmp"; fi ;;
          *) printf 'claims marker line is not a claimant\n' >&2; rm -f "$tmp"; exit 1 ;;
        esac ;;
    esac
  done < "$marker"
fi
if [ "$present" -eq 1 ]; then
  rm -f "$tmp"
  printf 'present\n'
  exit 0
fi
if [ "$first" -eq 1 ]; then printf '"%%s"\n' "$MASC_VOLUME_CLAIMANT" >> "$tmp"
else printf ',"%%s"\n' "$MASC_VOLUME_CLAIMANT" >> "$tmp"; fi
printf ']\n' >> "$tmp"
mv -f "$tmp" "$marker"
printf 'added\n'|sh}
    (Filename.quote marker) volume_claim_validate_script
;;

let volume_claim_release_script_with ~marker =
  Printf.sprintf
    {sh|set -eu
LC_ALL=C
export LC_ALL
marker=%s
%s
if [ ! -f "$marker" ]; then printf 'absent\n'; exit 0; fi
tmp=$marker.tmp
if ! validate_marker > "$tmp" || ! cmp -s "$marker" "$tmp"; then
  rm -f "$tmp"
  printf 'claims marker is not a complete supported array\n' >&2
  exit 1
fi
rm -f "$tmp"
printf '[\n' > "$tmp"
first=1
found=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '['|']') ;;
    *)
      elem=${line#,}
      case "$elem" in
        '"'*'"')
          elem=${elem#\"}; elem=${elem%%\"}
          if [ "$elem" = "$MASC_VOLUME_CLAIMANT" ]; then found=1
          elif [ "$first" -eq 1 ]; then printf '"%%s"\n' "$elem" >> "$tmp"; first=0
          else printf ',"%%s"\n' "$elem" >> "$tmp"; fi ;;
        *) printf 'claims marker line is not a claimant\n' >&2; rm -f "$tmp"; exit 1 ;;
      esac ;;
  esac
done < "$marker"
if [ "$found" -eq 0 ]; then
  rm -f "$tmp"
  printf 'not-claimed\n'
  exit 0
fi
if [ "$first" -eq 1 ]; then
  rm -f "$marker" "$tmp"
  printf 'released-last\n'
  exit 0
fi
printf ']\n' >> "$tmp"
mv -f "$tmp" "$marker"
printf 'kept\n'
cat "$marker"|sh}
    (Filename.quote marker) volume_claim_validate_script
;;

let volume_claims_read_script_with ~marker =
  Printf.sprintf
    {sh|set -eu
marker=%s
if [ -f "$marker" ]; then cat "$marker"; fi|sh}
    (Filename.quote marker)
;;

let volume_claim_marker_guest_path =
  Filename.concat claims_guest_root volume_claims_marker_name
;;

let volume_claim_add_script = volume_claim_add_script_with ~marker:volume_claim_marker_guest_path
let volume_claim_release_script = volume_claim_release_script_with ~marker:volume_claim_marker_guest_path
let volume_claims_read_script = volume_claims_read_script_with ~marker:volume_claim_marker_guest_path

(* The claims helper shares the trim helper's shape -- one [container run
   --rm] of the keeper's own image, root, every capability dropped, no
   network, a read-only root -- but needs no capability at all: it only
   reads and writes files on the mounted volume. The helper name is
   keeper-scoped and shared across workspaces, so two workspaces claiming
   at once collide on the name and the second run fails; that failure, and
   a name observed present before this one starts, both leave the marker
   untouched and are reported rather than retried. *)
let apple_volume_claim_run_argv ?(env = []) ~keeper_name ~volume_name ~image script =
  command_argv_for Backend.Apple_container
  @ [ "run"; "--rm"; "--name"; volume_claim_helper_name ~keeper_name
    ; "--user"; "0"; "--cap-drop"; "ALL"
    ; "--network"; "none"; "--read-only"
    ; "--entrypoint"; "/bin/sh"
    ; "--volume"; volume_name ^ ":" ^ claims_guest_root
    ]
  @ List.concat_map (fun (key, value) -> [ "--env"; key ^ "=" ^ value ]) env
  @ [ image; "-eu"; "-c"; script ]
;;

let apple_volume_claims_read_argv ~keeper_name ~volume_name ~image =
  apple_volume_claim_run_argv ~keeper_name ~volume_name ~image volume_claims_read_script
;;

let apple_volume_claim_add_argv ~keeper_name ~volume_name ~image ~claimant =
  apple_volume_claim_run_argv
    ~env:[ volume_claimant_env_var, claimant ]
    ~keeper_name ~volume_name ~image volume_claim_add_script
;;

let apple_volume_claim_release_argv ~keeper_name ~volume_name ~image ~claimant =
  apple_volume_claim_run_argv
    ~env:[ volume_claimant_env_var, claimant ]
    ~keeper_name ~volume_name ~image volume_claim_release_script
;;
