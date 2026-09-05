(* The recipe is a string rather than a file in this repository because the
   thing that needs it is a binary installed somewhere else entirely. Keeping
   one copy, inside the binary, is what makes `masc sandbox-image build` work
   on a host that never had a checkout -- and it is why the Dockerfile below
   carries no COPY: `docker build -` reads it on stdin with no context. *)

let default_tag = "masc-sandbox:general"

(* What a Keeper turn needs from any image, read off the argv it is run as
   (keeper_sandbox_docker.ml): `<image> bash -l -s` with the tool script on
   stdin, `--user <host uid>:<gid>`, a read-only rootfs plus one tmpfs, and
   --cap-drop=ALL. So bash has to be here, ripgrep has to be here because Grep
   refuses without it, and git has to be here because a Keeper that cannot read
   history cannot say what changed. Nothing else is assumed: a project's own
   toolchain belongs in that project's image, named per Keeper with
   sandbox_image. *)
let dockerfile =
  {|# MASC general Keeper sandbox.
#
# Built by `masc sandbox-image build`, which pipes this file to
# `docker build -` -- there is no build context and no COPY, so it builds the
# same way from an installed binary as from a checkout.
#
# This is the toolchain a Keeper turn needs to read, search and edit a
# repository, and nothing more. A Keeper that has to build a project needs that
# project's toolchain instead: point it at another image with `sandbox_image`
# in its TOML.
FROM debian:bookworm-slim

# bash: the turn is run as `bash -l -s`, so a shell that is not bash cannot
#       take one.
# ripgrep: the Grep tool refuses without `rg` on PATH.
# git: history and diffs are how a Keeper reports what it changed.
# ca-certificates, curl: anything that reaches the network at all.
# less, procps, findutils: what a shell turn reaches for without thinking.
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
       bash \
       ca-certificates \
       curl \
       findutils \
       git \
       less \
       procps \
       ripgrep \
  && rm -rf /var/lib/apt/lists/*

# The container runs as the host operator's uid, which has no entry here. Give
# that arbitrary uid a readable, writable HOME so a login shell and git both
# have somewhere to land; the rootfs is read-only at run time apart from this
# and the mounted workspace.
RUN mkdir -p /home/keeper && chmod 0777 /home/keeper
ENV HOME=/home/keeper

# Declared for a reader, not enforced: the run command supplies its own user,
# workdir and entrypoint.
CMD ["bash", "-l"]
|}

let build_argv ~tag = [ "build"; "-t"; tag; "-" ]
