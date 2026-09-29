# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

The repository root currently contains a single project, `ansible-appdev-migration/`. All commands below are run from that directory.

## What this project does

An Ansible project that migrates an application account from RHEL7 (`appdev`) to RHEL8 (`svc_appdev`), building a full N×M SSH trust mesh between every RHEL7 and RHEL8 host so application scripts work unmodified regardless of which platform they run on (the username difference is resolved entirely via `~/.ssh/config` `User` mapping, not by changing scripts). Full design rationale is in `ansible-appdev-migration/README.md` — read it before making changes; it documents *why* each decision was made (e.g. why RHEL7 is touched only via `raw`, why blocks are `blockinfile`-managed instead of whole files, why host keys are verified instead of TOFU'd).

## Commands

Run from `ansible-appdev-migration/`:

```bash
# Install required collections (ansible.posix, for firewalld)
ansible-galaxy collection install -r requirements.yml

# Dry run against real inventory (raw scripts on RHEL7 honour --check)
ansible-playbook playbooks/site.yml --check --diff

# Full apply: 00 bootstrap -> 10 baseline -> 20 ssh trust -> 30 verify
ansible-playbook playbooks/site.yml

# Re-verify the mesh only (read-only, safe to run anytime)
ansible-playbook playbooks/30_verify_ssh.yml

# Decommission RHEL7 from the mesh (re-renders RHEL8 blocks without RHEL7; RHEL7 not contacted)
ansible-playbook playbooks/decommission_rhel7.yml
```

### Local tests (no real servers needed; requires Linux/WSL, ansible-core, ansible.posix)

Run from `ansible-appdev-migration/tests/`:

```bash
./run.sh    # syntax-checks all playbooks; runs the trust play twice against localhost
            # (proves idempotency) plus a --check mode run
./edge.sh   # edge cases: preserving existing authorized_keys/config content, key
            # rotation updating a block in place, decommission re-render dropping
            # RHEL7 entries, and the verify playbook's report path
```

Both scripts fake the target environment: `tests/fakebin/getent` redirects the app user's home into a temp dir (`$FAKEHOME`) so real servers and the operator's own `~/.ssh` are never touched, `tests/inventory.yml` uses `ansible_connection: local` hosts (`r7a`/`r7b`/`r8a`/`r8b`), and `tests/test.yml` renders the RHEL8-side blocks into `$FAKEHOME/rhel8_*` files for inspection. There is no CI config in this repo — these scripts are the only test entry points.

## Architecture

**Playbook execution order** (`playbooks/site.yml` imports all four in sequence):

1. `00_bootstrap_rhel8.yml` — installs `python3.11` on RHEL8 via `raw` (ansible-core ≥2.17 dropped support for RHEL8's platform-python 3.6).
2. `10_rhel8_baseline.yml` — applies the `svc_appdev` role (account, group, home dir permissions, sshd sanity assertions, firewalld).
3. `20_ssh_trust.yml` — the core of the project, in two phases:
   - **Collect**: gathers user public keys, host public keys, and connect addresses from every RHEL8 host (via Ansible modules) and every RHEL7 host (via a `raw`-executed bash script templated from `templates/rhel7_collect.sh.j2`), storing them as a `mesh_node` fact per host.
   - **Apply**: renders `templates/authorized_keys.j2`, `templates/known_hosts.j2`, and `templates/ssh_config.j2` from the collected `mesh_node` data and writes them as `blockinfile`-managed blocks (marker from `managed_marker`, default `appdev-migration`) — using `ansible.builtin.blockinfile` on RHEL8 and a `raw`-executed script (`templates/rhel7_apply.sh.j2`) on RHEL7. The same Jinja templates back both platforms so their content always agrees.
   - Every play in this file sets `any_errors_fatal: true` — the mesh is all-or-nothing; a host that can't be reached blocks all writes.
4. `30_verify_ssh.yml` — proves the mesh end-to-end by SSHing from every source to every target using only the host alias (never `user@host`) and checking the remote `id -un`, which validates both connectivity and the user-mapping. Produces a connectivity matrix via `ansible.builtin.assert` on the `localhost` play.

**RHEL7 vs RHEL8 asymmetry** is the key thing to preserve when editing: RHEL7 hosts are never managed with standard modules that require Python — everything there goes through `ansible.builtin.raw` running bash scripts (`templates/rhel7_*.sh.j2`), because RHEL7 is being retired and must not gain new package/Python dependencies. RHEL8 is fully module-managed. Both playbooks in `20_ssh_trust.yml` and `30_verify_ssh.yml` therefore have parallel RHEL8 and RHEL7 plays that must stay in sync when logic changes.

**Decommissioning** (`playbooks/decommission_rhel7.yml`) works by re-importing `20_ssh_trust.yml` and `30_verify_ssh.yml` with `rhel7_in_mesh: false` overridden — this re-renders the RHEL8-side managed blocks without RHEL7 entries and never contacts RHEL7 hosts, so it works even after RHEL7 is powered off. The permanent switch-over is then `rhel7_in_mesh: false` in `inventory/group_vars/all.yml`.

**Variable layering**: `inventory/group_vars/all.yml` (mesh-wide: `rhel7_in_mesh`, `ssh_key_type`, `restrict_key_source`, `managed_marker`) + `inventory/group_vars/{rhel7,rhel8}.yml` (per-platform `app_user`, and for RHEL8 also `app_group`/`app_home`/`ansible_python_interpreter`) + `roles/svc_appdev/defaults/main.yml` (role-internal defaults like `app_directories`, `app_legacy_home_symlink`). Per-host `mesh_address` (in `inventory/hosts.yml`) overrides the address other mesh hosts use to reach that host.
