# MASC Keeper sandbox, `ocaml` recipe. Why each step is here: README.md in this
# directory. Keep comments short: this file's size decides whether Apple's
# container builder accepts it (README.md, first section).

FROM ocaml/opam:ubuntu-24.04-ocaml-5.5

USER root
ENV DEBIAN_FRONTEND=noninteractive

# gh and node come from their vendors' apt repositories; the -dev packages are
# opam depexts (README.md: Vendor apt repositories, System packages).
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && printf 'deb [arch=%s signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
      "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/github-cli.list \
 && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      -o /usr/share/keyrings/nodesource.gpg.armor \
 && gpg --dearmor -o /usr/share/keyrings/nodesource.gpg \
      < /usr/share/keyrings/nodesource.gpg.armor \
 && chmod go+r /usr/share/keyrings/nodesource.gpg \
 && printf 'deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main\n' \
      > /etc/apt/sources.list.d/nodesource.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      coreutils \
      findutils \
      g++ \
      gcc \
      gh \
      git \
      jq \
      less \
      make \
      openssh-client \
      patch \
      pkg-config \
      python3 \
      python3-venv \
      ripgrep \
      rsync \
      tree \
      unzip \
      zip \
      m4 \
      nodejs \
      procps \
      lsof \
      fd-find \
      zsh \
      perl \
      trash-cli \
      file \
      xxd \
      time \
      iproute2 \
      bind9-dnsutils \
      python3-pip \
      python3-yaml \
      libev-dev \
      libgmp-dev \
      libprotobuf-dev \
      libsqlite3-dev \
      libssl-dev \
      libzstd-dev \
      libncurses-dev \
      protobuf-compiler \
      zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

# Commands Keepers were measured invoking (README.md: Measured tool usage).
RUN npm install --global --no-fund --no-audit pnpm@10.31.0 \
 && ln -s "$(command -v timeout)" /usr/local/bin/gtimeout \
 && ln -s "$(command -v fdfind)" /usr/local/bin/fd

# Deliberately absent, with the reason, so the next reader does not "fix" them:
#
#   docker      A keeper invoked it 11 times. The client is useless without the
#               socket, and mounting the socket hands the container the daemon
#               -- every mount boundary in this file becomes advisory at that
#               point (OpenClaw shipped exactly that escape, arXiv 2603.27517).
#               If a keeper needs containers, that is a separate design.
#   playwright  15 uses, and the browsers are the cost, not the CLI. Adding it
#               means several hundred MB of image for one keeper's workflow.
#   ttyd        8 uses, not packaged for this base. TUI PTY work needs its own
#               answer.
#   actionlint  One exec failure in the container logs and 9 mentions. It lints
#               .github/workflows, which CI already does on every push, so a
#               keeper running it locally duplicates a gate rather than
#               unblocking work. Host-only (homebrew). Left out on purpose: if a
#               keeper needs workflow validation before pushing, the answer is
#               to say so, not to grow the image by one binary per habit.
#   md5         macOS spelling. `md5sum` is present but prints a different
#               format, so a symlink would produce output that parses wrong --
#               worse than the command being absent.
#   masc, sb    Host operator wrappers under /Users/dancer/me/scripts. They are
#               not a toolchain; a keeper reaching for them is reaching outside
#               its sandbox, which is the thing being closed.

# The playground bind mount is written by a uid with no account in the image.
RUN mkdir -p /home/keeper/playground && chmod 0777 /home/keeper /home/keeper/playground

USER opam

# The base tag pins an older compiler than masc.opam asks for; unpin and move the
# switch invariant (README.md: Base image and compiler).
# scripts/check-sandbox-ocaml-version.sh reads the version out of the line below.
RUN opam update --yes \
 && opam pin remove ocaml-base-compiler --yes \
 && opam switch set-invariant ocaml-base-compiler.5.5.1 --yes \
 && opam install ocaml-base-compiler.5.5.1 --yes \
 && opam clean -a -c -s --logs

# Package metadata only; the lock's pins are replayed (README.md: Dependencies).
COPY --chown=opam:opam masc.opam masc.opam.locked /tmp/masc/
COPY --chown=opam:opam scripts/opam-pin-from-lock.sh /tmp/opam-pin-from-lock.sh
RUN sh /tmp/opam-pin-from-lock.sh /tmp/masc/masc.opam.locked \
 && opam install --deps-only --with-test --yes /tmp/masc/masc.opam \
 && opam clean -a -c -s --logs \
 && rm -rf /tmp/masc /tmp/opam-pin-from-lock.sh

USER root

# `bash -c` never runs `opam env`, and masc sets HOME=/tmp (README.md: Switch
# environment).
ENV OPAMROOT=/home/opam/.opam \
    OPAM_SWITCH_PREFIX=/home/opam/.opam/5.5 \
    OCAML_TOPLEVEL_PATH=/home/opam/.opam/5.5/lib/toplevel \
    OCAMLTOP_INCLUDE_PATH=/home/opam/.opam/5.5/lib/toplevel \
    CAML_LD_LIBRARY_PATH=/home/opam/.opam/5.5/lib/stublibs:/home/opam/.opam/5.5/lib/ocaml/stublibs:/home/opam/.opam/5.5/lib/ocaml \
    PATH=/home/opam/.opam/5.5/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN test -d "${OPAM_SWITCH_PREFIX}/lib/yojson" \
 || { echo "opam switch prefix drift: ${OPAM_SWITCH_PREFIX} has no lib/yojson" >&2; exit 1; }

# A uid with no account has to traverse /home/opam (README.md: Permissions).
RUN chmod o+rx /home/opam \
 && find /home/opam/.opam -type d -exec chmod o+rx {} + \
 && test -x "${OPAM_SWITCH_PREFIX}/bin/dune" \
 || { echo "chmod failed, or ${OPAM_SWITCH_PREFIX}/bin has no dune" >&2; exit 1; }

VOLUME ["/tmp/keeper-creds"]

# SIGTERM lets bash and any in-flight tool process exit before docker stop escalates.
STOPSIGNAL SIGTERM

CMD ["/bin/bash"]

# A Keeper turn in miniature: no account, HOME=/tmp (README.md: Final check).
USER 60123:60123
RUN HOME=/tmp opam exec -- dune --version \
 || { echo "opam exec fails as a uid with no account -- OPAMROOT or the chmod above is not covering it" >&2; exit 1; }
USER root
