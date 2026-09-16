#!/bin/sh
exec sshpass -p 1 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PubkeyAuthentication=no -o PreferredAuthentications=password -o ConnectTimeout=20 -p 2222 Administrator@127.0.0.1 "$@"
