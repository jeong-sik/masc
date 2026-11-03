#!/bin/sh
# Non-root sshd: runs as whatever --user the container was given.
set -eu
d=/tmp/sshprobe; mkdir -p $d
ssh-keygen -q -t ed25519 -N '' -f $d/hk
cat > $d/cfg << CFG
Port 2222
ListenAddress 0.0.0.0
HostKey $d/hk
PidFile $d/sshd.pid
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile /opt/probe/authorized_keys
StrictModes no
UsePAM no
CFG
exec /usr/sbin/sshd -D -e -f $d/cfg
