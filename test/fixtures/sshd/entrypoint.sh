#!/bin/sh
set -eu

ssh-keygen -A
exec /usr/sbin/sshd -D -e
