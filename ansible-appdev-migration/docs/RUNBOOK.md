# Operator runbook: appdev → svc_appdev SSH trust migration

Audience: the operator running this project against real hosts. For *why*
it works this way, see [`DESIGN.md`](DESIGN.md) and `../README.md`.

## 1. Before you start

- [ ] Controller has **ansible-core ≥ 2.15**.
- [ ] `ansible-galaxy collection install -r requirements.yml` has been run
      (installs `ansible.posix`, needed for firewalld).
- [ ] You have an admin account (`ansible_user`) that can SSH to all 8 hosts
      and has sudo. If sudo needs a password, every command below needs `-K`.
- [ ] RHEL8 hosts can reach an AppStream repo (for `python3.11`).
- [ ] TCP/22 is open in both directions between every RHEL7 and RHEL8 host —
      check network ACLs/firewalls now, not after a mid-run failure.
- [ ] `appdev` already exists on RHEL7 with a real login shell (not
      `nologin`).
- [ ] `inventory/hosts.yml` has been edited: real hostnames/IPs, and
      `mesh_address` set on any host whose SSH-reachable address differs from
      `ansible_host` (e.g. behind NAT).
- [ ] `inventory/group_vars/rhel8.yml`: `app_uid`/`app_gid` set to `appdev`'s
      UID/GID **if** RHEL7 and RHEL8 share NFS storage during the migration.
- [ ] If RHEL8 runs FIPS mode: set `ssh_key_type: rsa` in
      `inventory/group_vars/all.yml` **before the first run** (existing keys
      are never replaced, so this can't be fixed retroactively for hosts that
      already got an ed25519 key from this project).

Run from `ansible-appdev-migration/`.

## 2. First-time setup

```bash
# 1. Dry run — the RHEL7 raw scripts honour --check and report what they'd do.
ansible-playbook playbooks/site.yml --check --diff

# 2. Review the diff. Then apply for real.
ansible-playbook playbooks/site.yml

# 3. Confirm the mesh works end-to-end (also runs automatically at the end of site.yml).
ansible-playbook playbooks/30_verify_ssh.yml
```

Expected tail of `30_verify_ssh.yml` output:

```
- 'rhel7-app01 (appdev) -> rhel8-app01: OK'
- 'rhel8-app02 (svc_appdev) -> rhel7-app03: OK'
...
All 48 SSH paths OK
```

(4 RHEL8 sources × 8 targets, plus 4 RHEL7 sources × 4 RHEL8 targets = 48.)

If the assert at the end fails, the task output lists only the failing
paths (`FAIL: ...`) — see §5 Troubleshooting.

## 3. Routine operations during the migration

### Add or rebuild a host

Add it to `inventory/hosts.yml` (RHEL8: also add any `mesh_address`), then:

```bash
ansible-playbook playbooks/site.yml
```

Every existing host — RHEL7 included — learns the new host's key and host
key in the same run, because the collect phase re-runs against the whole
mesh every time.

### Rotate a key

Delete the old key pair on the host itself (or let the operator/app-owner do
it), then:

```bash
ansible-playbook playbooks/20_ssh_trust.yml
```

A fresh key is generated (§2.5 of the design doc — existing keys are never
touched, so the old one must actually be gone first), and every managed
block mesh-wide is rewritten in place with the new public key.

### A host was rebuilt (new host key)

Its old host key is still in everyone's `known_hosts`/`ssh_known_hosts` and
will cause `Host key verification failed` until it's replaced:

```bash
ansible-playbook playbooks/20_ssh_trust.yml
```

This re-collects the current host key from the rebuilt host and rewrites the
managed blocks everywhere. If stray lines for that host exist *outside* the
managed block (e.g. from manual `ssh` use before this project touched the
host), also run `ssh-keygen -R <host>` on affected hosts, or wait for
`restorecon`/normal SSH use to surface the conflict and fix it by hand — the
managed block alone won't clean up lines it doesn't own.

### An application script fails after moving to RHEL8

- **Hard-coded user name** (`appdev@host`, `scp appdev@...`): bypasses the
  `~/.ssh/config` `User` mapping entirely. Find offenders with:
  ```bash
  grep -rn 'appdev@' <app dirs>
  ```
  Fix the script to drop the explicit user (let the config mapping supply
  it), or maintain a parallel `svc_appdev@` copy — the mapping cannot help a
  hardcoded remote user.
- **Hard-coded path** (`/home/appdev/...`): set `app_legacy_home_symlink:
  true` in `inventory/group_vars/rhel8.yml` (or per-host) and re-run
  `10_rhel8_baseline.yml` — this creates `/home/appdev -> /home/svc_appdev`
  on RHEL8.

## 4. Decommissioning RHEL7

Run once the **last** application process has moved off RHEL7:

```bash
ansible-playbook playbooks/decommission_rhel7.yml
```

This re-renders the RHEL8-side managed blocks with RHEL7 excluded — removing
every RHEL7 key, host key, and alias from `svc_appdev`'s files and
`/etc/ssh/ssh_known_hosts`. RHEL7 hosts are **not contacted**, so this step
still works if they're already powered off.

Then make it permanent, so a later `site.yml` run doesn't re-add RHEL7:

```yaml
# inventory/group_vars/all.yml
rhel7_in_mesh: false
```

(or remove the `rhel7` group from `inventory/hosts.yml` entirely).

## 5. Troubleshooting

| Symptom | Check |
|---|---|
| `Permission denied (publickey)` | `journalctl -u sshd` on the target. Common causes: home/`.ssh` permissions (sshd `StrictModes`), a wrong SELinux context (`restorecon -Rv ~/.ssh`), or the `from="..."` restriction not matching the real source IP (NAT) — set `mesh_extra_addrs` for that host or, as a last resort, `restrict_key_source: false`. |
| `Host key verification failed` | The host was rebuilt. Rerun `playbooks/20_ssh_trust.yml`, and remove stale lines *outside* the managed block with `ssh-keygen -R <host>`. |
| Logs in as the wrong user | Another `Host` entry sits *above* the managed block in `~/.ssh/config` — the managed block is inserted at the very top precisely to prevent this, so look for a second write to that file outside this project. |
| `/usr/bin/python3.11: not found` | Run `playbooks/00_bootstrap_rhel8.yml` (or the full `site.yml`). |
| `ansible-playbook` fails immediately on one unreachable RHEL7/RHEL8 host, no blocks written anywhere | Expected — `any_errors_fatal: true` makes the mesh all-or-nothing (§2.8 of the design doc). Fix connectivity/inventory for that host and re-run; nothing was left half-written. |
| `30_verify_ssh.yml` shows `FAIL: no result - host unreachable?` for a source | That source host itself didn't return facts (unreachable, or excluded by `--limit`) — the assert then treats every one of its paths as failed. Check the source host directly, not the targets. |
| RHEL8 sshd rejects the service account outright | `roles/svc_appdev` fails the run early if `PubkeyAuthentication no`, or if `AllowUsers` is set without `svc_appdev`. It only *warns* if `AllowGroups` is set — confirm `svc_appdev`'s group is in that list by hand. |

## 6. Re-verifying without changing anything

Safe to run at any time, changes nothing:

```bash
ansible-playbook playbooks/30_verify_ssh.yml
```

Useful after any manual change on a host, or periodically to catch drift
(e.g. someone hand-edited `~/.ssh/config` outside the managed block).

## 7. Testing changes to this project itself

Before changing playbooks, roles, or templates, run the offline test suite
(Linux/WSL, ansible-core + `ansible.posix` required — see
`../tests/README.md`):

```bash
cd tests
./run.sh    # syntax-check every playbook; run the trust play twice against
            # localhost to prove idempotency; one --check-mode pass
./edge.sh   # pre-existing-content preservation, key rotation in place,
            # decommission render, and the verify playbook's report/failure path
```

Both scripts run entirely against `localhost` via a faked `getent` — no real
server or your own `~/.ssh` is ever touched. Read the `==` section headers
in the output; each corresponds to one behavior being checked, and the
script prints the relevant rendered files (`authorized_keys`, `known_hosts`,
`config`, the `rhel8_*` block dumps) for manual inspection alongside each
check.

## 8. Security notes to keep in mind operationally

- Private keys never leave the host they were generated on — only public
  keys and host public keys are read by the controller. If you ever see this
  project (or a change to it) reading a *private* key, treat that as a bug.
- Every mesh connection uses `StrictHostKeyChecking yes`; there is
  intentionally no trust-on-first-use anywhere. Don't "fix" a connectivity
  issue by adding `-o StrictHostKeyChecking=no` — re-collect the correct host
  key instead (§5).
- `from="<ip>"` restrictions on authorized keys (§2.7 of the design doc) are
  a real security control, not just hygiene — don't disable
  `restrict_key_source` to work around a connectivity problem without
  confirming NAT is actually the cause.
