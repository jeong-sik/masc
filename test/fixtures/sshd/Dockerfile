FROM alpine:3.21

RUN apk add --no-cache \
      github-cli \
      git \
      openssh-server \
      procps \
      ripgrep \
      sudo \
 && adduser -D -s /bin/sh masc \
 && passwd -d masc \
 && install -d -m 0700 -o masc -g masc /home/masc/.ssh \
 && install -d -m 0755 /run/sshd /srv/masc/playground \
 && install -d -m 0700 -o masc -g masc \
      /srv/masc/playground/keeper-a/.config/gh \
 && printf '%s\n' 'masc ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/masc \
 && chmod 0440 /etc/sudoers.d/masc \
 && printf '%s\n' \
      'Port 22' \
      'ListenAddress 0.0.0.0' \
      'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' \
      'PermitRootLogin no' \
      'PubkeyAuthentication yes' \
      'MaxSessions 10' \
      'AllowUsers masc' \
      > /etc/ssh/sshd_config \
 && printf '%s\n' \
      '#!/bin/sh' \
      'if [ "$1" = "auth" ] && [ "$2" = "status" ]; then exit 0; fi' \
      'exec /usr/bin/gh "$@"' \
      > /usr/local/bin/gh \
 && chmod 0755 /usr/local/bin/gh \
 && printf '%s\n' \
      'remote_root=/srv/masc/playground' \
      'env_allowlist=FOO,PATH' \
      > /etc/masc-exec-shim.conf

COPY --chmod=0755 masc-exec-shim /usr/local/bin/masc-exec-shim
COPY --chmod=0600 fixture.pub /home/masc/.ssh/authorized_keys
COPY --chmod=0755 entrypoint.sh /usr/local/bin/masc-sshd-entrypoint

RUN chown masc:masc /home/masc/.ssh/authorized_keys

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/masc-sshd-entrypoint"]
