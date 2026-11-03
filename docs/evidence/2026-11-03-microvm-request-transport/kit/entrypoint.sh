#!/bin/sh
# Scratch measurement guest: one user, one key, sshd on 22. No masc state.
set -eu
getent passwd probe >/dev/null || { groupadd -g 5100 probe; useradd -m -u 5100 -g 5100 -s /bin/sh -p '*' probe; }
mkdir -p /run/sshd /etc/sshprobe
install -m 0644 /opt/probe/authorized_keys /etc/sshprobe/authorized_keys.probe
[ -f /etc/sshprobe/host_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f /etc/sshprobe/host_ed25519
cat > /etc/sshprobe/sshd_config << 'CFG'
Port 22
ListenAddress 0.0.0.0
HostKey /etc/sshprobe/host_ed25519
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
AuthorizedKeysFile /etc/sshprobe/authorized_keys.%u
AllowUsers probe
UsePAM no
CFG
exec /usr/sbin/sshd -D -e -f /etc/sshprobe/sshd_config
