# Local tests (no servers needed)

Runs the playbooks against `localhost` with a fake `getent` that points the
application user's home at a temp dir, so the RHEL7 `raw` scripts and all
templates are exercised for real without touching any server or your own ~/.ssh.

Requires Linux/WSL with ansible-core and `ansible.posix` installed.

    ./run.sh    # syntax-check all playbooks, run trust play twice (idempotency) + check mode
    ./edge.sh   # existing-content preservation, key rotation, decommission render, verify report
