# appdev → svc_appdev: RHEL7 → RHEL8 migration with Ansible

## Goal

| | RHEL7 (4 hosts, being retired) | RHEL8 (4 hosts, target) |
|---|---|---|
| App account | `appdev` | `svc_appdev` |
| Managed by Ansible | minimally, `raw` only | fully (role + modules) |

While both platforms run application processes, SSH must work with keys only
and without prompts:

```
RHEL7 appdev ───────────► every RHEL8 host (as svc_appdev)
RHEL8 svc_appdev ───────► every RHEL8 host (as svc_appdev)
RHEL8 svc_appdev ───────► every RHEL7 host (as appdev)
RHEL7 appdev ◄──► RHEL7 appdev      (already exists, left alone)
```

## Design decisions

1. **The user-name difference is handled by the SSH client, not the application.**
   Each account gets a managed `~/.ssh/config` block that maps every mesh host
   (short name, FQDN, IP, inventory name) to the right `User`. A script on RHEL7
   that runs `ssh rhel8-app01` logs in as `svc_appdev`, and a script on RHEL8
   that runs `ssh rhel7-app01` logs in as `appdev`, so application scripts need
   no changes. The block goes at the top of the file because ssh uses the first
   value it finds for each option, so an existing `Host *` cannot override it.

2. **RHEL7 is changed only with `raw` and plain bash.** There is no Python
   dependency, nothing is installed and no packages change on hosts that are
   about to be retired. It also avoids controller version problems:
   ansible-core 2.17 and later cannot manage Python 2.7 targets.

3. **RHEL8 is managed properly.** It uses the `svc_appdev` role (account, home
   permissions, sshd sanity checks, firewalld) plus `blockinfile` for the trust
   files. `00_bootstrap_rhel8.yml` installs `python3.11`, because
   ansible-core 2.17 and later dropped support for platform-python 3.6.

4. **Only managed blocks, never whole files.** Every change is a
   `# BEGIN/END ANSIBLE MANAGED: appdev-migration` block in `authorized_keys`,
   `known_hosts` and `~/.ssh/config`, and existing lines are preserved. The
   same Jinja templates generate the blocks for both platforms, so both sides
   always agree.

5. **Nothing is ever overwritten.** Existing key pairs are reused. A new
   `ed25519` key is generated only when an account has no key at all.

6. **Host keys are verified, not trusted on first use.** Real host keys are
   collected from each server and published to `/etc/ssh/ssh_known_hosts` on
   RHEL8 and to `~appdev/.ssh/known_hosts` on RHEL7. Connections run with
   `StrictHostKeyChecking yes`, so there is no TOFU and no `-o StrictHostKeyChecking=no`.

7. **Keys are limited to their source host.** Each authorized key is prefixed
   with `from="<that host's IPs>"`, so a copied private key is useless anywhere
   else. You can turn this off with `restrict_key_source: false`, for example
   when traffic is NATed.

8. **The mesh is all or nothing.** Every play uses `any_errors_fatal`. If any
   host can't be read, nothing is written.

9. **Decommissioning is a variable change.** With `rhel7_in_mesh: false`, the
   blocks on RHEL8 are rendered again without RHEL7. That removes every RHEL7
   key, host key and alias, and RHEL7 does not need to be powered on.

## Layout

```
ansible.cfg
requirements.yml                      ansible.posix (firewalld)
inventory/hosts.yml                   rhel7 / rhel8 groups
inventory/group_vars/{all,rhel7,rhel8}.yml
roles/svc_appdev/                     RHEL8 service account baseline
playbooks/
  00_bootstrap_rhel8.yml              python3.11 on RHEL8 (raw)
  10_rhel8_baseline.yml               svc_appdev role
  20_ssh_trust.yml                    collect keys everywhere → write managed blocks
  30_verify_ssh.yml                   full N×M ssh test + matrix report
  decommission_rhel7.yml              remove RHEL7 from the mesh
  site.yml                            00 → 10 → 20 → 30
  templates/                          authorized_keys, known_hosts, ssh_config,
                                      rhel7_collect.sh, rhel7_apply.sh
tests/                                offline tests (see tests/README.md)
```

## Prerequisites

- A controller with ansible-core 2.15 or later, then run `ansible-galaxy collection install -r requirements.yml`.
- An admin account (`ansible_user`) that can SSH to all 8 hosts and has sudo.
  Pass `-K` if sudo needs a password.
- RHEL8 hosts can reach an AppStream repository (for `python3.11`).
- TCP/22 is open between every RHEL7 and RHEL8 host (check network ACLs and firewalls).
- `appdev` already exists on RHEL7 and has a real login shell.

## Runbook

```bash
# 0. Edit inventory/hosts.yml (names, IPs, optional mesh_address per host)
#    and group_vars (set app_uid/app_gid to appdev's UID/GID if NFS is shared).

# 1. Dry run. The raw scripts honour --check and report what they would change.
ansible-playbook playbooks/site.yml --check --diff

# 2. Apply.
ansible-playbook playbooks/site.yml

# 3. Re-verify at any time (read-only).
ansible-playbook playbooks/30_verify_ssh.yml
```

`30_verify_ssh.yml` logs in from every source to every target as the
application account, using only the host alias. The remote side runs
`id -un`, so the check also proves the user mapping works. Sample output:

```
- 'rhel7-app01 (appdev) -> rhel8-app01: OK'
- 'rhel8-app02 (svc_appdev) -> rhel7-app03: OK'
...
All 48 SSH paths OK
```

(4×8 from RHEL8 plus 4×4 from RHEL7 makes 48 paths.)

## During the migration

- **Adding or rebuilding a RHEL8 host:** add it to the inventory and run
  `site.yml`. Every host, including the RHEL7 ones, learns the new key and host key.
- **Rotating a key:** delete the old key on the host and rerun `20_ssh_trust.yml`.
  The blocks are rewritten in place.
- **Hard-coded user names:** scripts that use `appdev@host` or `scp appdev@...`
  bypass the config mapping and will fail against RHEL8. Find them with
  `grep -rn 'appdev@' <app dirs>`.
- **Hard-coded paths:** if scripts refer to `/home/appdev/...`, set
  `app_legacy_home_symlink: true` to create `/home/appdev -> /home/svc_appdev` on RHEL8.
- **Shared NFS:** use the same UID/GID (`app_uid`/`app_gid`) so ownership stays
  the same from both sides.

## Decommissioning RHEL7

When the last process has moved to RHEL8:

```bash
ansible-playbook playbooks/decommission_rhel7.yml
```

Then set `rhel7_in_mesh: false` in `group_vars/all.yml` or remove the `rhel7`
group from the inventory, so later runs keep RHEL7 out. RHEL7 is never
contacted, so this also works after the servers are powered off.

## Security notes

- **FIPS mode on RHEL8:** ed25519 is not allowed. Set `ssh_key_type: rsa`
  (4096 bits) before the first run.
- **RHEL8 `DEFAULT` crypto policy:** RHEL8 rejects `ssh-dss` and RSA keys
  shorter than 2048 bits. The trust play warns if appdev on RHEL7 only has a
  DSA key.
- **sshd settings:** the role fails early if sshd on RHEL8 has
  `PubkeyAuthentication no` or an `AllowUsers` list without `svc_appdev`, and
  it warns if `AllowGroups` is set.
- **Private keys:** private keys never leave their hosts. Only public keys and
  host public keys pass through the controller.

## Troubleshooting

| Symptom | Check |
|---|---|
| `Permission denied (publickey)` | Look at `journalctl -u sshd` on the target. Common causes are home or `.ssh` permissions (StrictModes), an SELinux context (`restorecon -Rv ~/.ssh`), or the `from=` IP differing from the real source (NAT, so set `mesh_extra_addrs` or `restrict_key_source: false`). |
| `Host key verification failed` | The host was rebuilt. Rerun `20_ssh_trust.yml`, and remove stale lines outside the managed block with `ssh-keygen -R <host>`. |
| Wrong user on login | Another `Host` entry *above* the managed block in `~/.ssh/config`. |
| `/usr/bin/python3.11: not found` | Run `00_bootstrap_rhel8.yml`. |
