# Design document: appdev → svc_appdev SSH trust migration

## 1. Intent

The application currently runs as the `appdev` account on four RHEL7 hosts.
It is moving to four RHEL8 hosts, where it will run as `svc_appdev`. During
the migration both platforms are live at once, and the application's own
scripts SSH between hosts (e.g. a batch job on one node reaching over to
another to stage or collect files). Those scripts must keep working, without
being rewritten, whichever platform they happen to run on and whichever
platform they happen to target.

Concretely, four SSH paths must all work, key-only, no prompts:

```
RHEL7 appdev     ───────────►  every RHEL8 host  (as svc_appdev)
RHEL8 svc_appdev ───────────►  every RHEL8 host  (as svc_appdev)
RHEL8 svc_appdev ───────────►  every RHEL7 host  (as appdev)
RHEL7 appdev     ◄─────────►   RHEL7 appdev       (already exists, left alone)
```

The project's job is to stand this mesh up, keep it correct as hosts are
added or keys rotate, and tear the RHEL7 side back out cleanly once the
application has fully moved — all without editing a single application
script, without touching RHEL7 beyond what is strictly necessary on a host
being retired, and without weakening host-key verification or credential
hygiene to get there.

This is a small, self-contained Ansible project (no external CMDB, secrets
manager, or orchestration system) intended to be run by hand from an
operator's workstation or a jump host, against a static inventory.

## 2. Design

Nine decisions shape the whole implementation. Each is a direct answer to a
constraint above; they are recorded here (and in `../README.md`) so future
changes don't accidentally re-open a problem that was already solved.

### 2.1 The username difference is resolved by the SSH client, not the app

Rather than teach application scripts about two account names, every account
in the mesh gets a managed block in `~/.ssh/config` that maps *every* alias a
mesh host is known by (short name, FQDN, inventory name, IP) to the right
`User`. `ssh rhel8-app01` from `appdev` therefore transparently logs in as
`svc_appdev`, and `ssh rhel7-app01` from `svc_appdev` logs in as `appdev`.
The block is written at the **top** of the file (`insertbefore: BOF` on
RHEL8, `pos=top` in the RHEL7 script) because `ssh` uses the first matching
value for each option — a block appended after an existing `Host *` would be
silently ignored.

### 2.2 RHEL7 is touched only with `raw` and plain bash

RHEL7 is being decommissioned, so nothing is installed and no package state
changes there. This is also a hard technical requirement, not just
conservatism: ansible-core 2.17+ dropped support for Python 2.7 targets, so
standard modules cannot run against RHEL7 at all on a current controller.
Every RHEL7-side action is therefore a bash script (`templates/rhel7_*.sh.j2`)
executed via `ansible.builtin.raw`.

### 2.3 RHEL8 is a fully managed platform

RHEL8 gets a normal role (`roles/svc_appdev`) — account/group creation, home
directory permissions, an sshd preflight check, firewalld — plus
`blockinfile` for the trust files. `playbooks/00_bootstrap_rhel8.yml`
installs `python3.11` from AppStream via `raw` first, because ansible-core
2.17+ also dropped support for RHEL8's platform-python (3.6); every module
task in this project after that point depends on `ansible_python_interpreter:
/usr/bin/python3.11` (set in `inventory/group_vars/rhel8.yml`).

### 2.4 Only managed blocks, never whole files

Every change to `authorized_keys`, `known_hosts`, or `~/.ssh/config` is a
`# BEGIN/END ANSIBLE MANAGED: <managed_marker>` block; everything outside the
markers is preserved verbatim, on both platforms. The same three Jinja
templates (`authorized_keys.j2`, `known_hosts.j2`, `ssh_config.j2`) render
the block content for both `blockinfile` (RHEL8) and the RHEL7 shell script,
so the two sides can never drift apart in content — only in *how* they're
written.

### 2.5 Nothing is ever overwritten

Key generation checks for an existing key first (`generate_ssh_key: true` on
RHEL8's `user` module; a `has_key` scan in `rhel7_collect.sh.j2` on RHEL7)
and never replaces one. A pre-existing key pair, however old, is reused as-is.

### 2.6 Host keys are verified, never trust-on-first-use

Real host public keys are collected from `/etc/ssh` on every host and
published — to `/etc/ssh/ssh_known_hosts` (system-wide) on RHEL8, and to
`~appdev/.ssh/known_hosts` on RHEL7. Every mesh connection, including the
verify playbook, runs with `StrictHostKeyChecking yes` and no
`-o StrictHostKeyChecking=no` anywhere in the codebase. This means a
rebuilt host (new host key) must be re-collected before it can be reached
again — see the runbook's troubleshooting table.

### 2.7 Keys are source-restricted by default

Unless `restrict_key_source: false` is set (needed when traffic is NATed),
every `authorized_keys` entry is prefixed with `from="<comma-separated source
IPs>"`, generated from each host's `mesh_node.addrs`. A private key copied
off a mesh host is therefore useless from anywhere else.

### 2.8 The mesh is all-or-nothing

Every play in `20_ssh_trust.yml` sets `any_errors_fatal: true`. If any single
host in the collect phase is unreachable or fails its sanity assertion, no
managed block is written anywhere — a partially-updated mesh (some hosts
trusting a new key, others not) is considered worse than no change at all.

### 2.9 Decommissioning is a variable flip, not a teardown script

Because the RHEL8-side blocks are *rendered*, not hand-edited, removing RHEL7
from the mesh is just re-rendering them with `rhel7_in_mesh: false` — RHEL7's
keys, host keys, and aliases fall out of the template loops. RHEL7 itself is
never contacted for this, so decommissioning still works if those hosts are
already powered off.

## 3. Implementation

### 3.1 Data model: `mesh_node`

The whole project pivots on one fact, `mesh_node`, computed once per host
during the collect phase and read back via `hostvars[<host>].mesh_node` when
rendering templates for every other host:

| field | meaning |
|---|---|
| `user` | account name on this host (`appdev` or `svc_appdev`) |
| `connect` | address other hosts should use to reach this host: `mesh_address` (inventory var) → `ansible_host` → `inventory_hostname`, in that order |
| `user_keys` | this account's public keys (list, usually length 1) |
| `host_keys` | this host's SSH host public keys (`ssh-dss` stripped out — see §3.4) |
| `names` | short hostname, FQDN, node name — `localhost`-ish values rejected |
| `addrs` | this host's own IPv4 addresses, plus `mesh_extra_addrs` if set (for NAT) |

All three output templates are pure functions of a list of these structs
(`trust_sources` for `authorized_keys.j2`, `trust_targets` for the other two)
— they don't know or care whether a given `mesh_node` came from a RHEL7 `raw`
script or a RHEL8 `set_fact`.

### 3.2 Playbook pipeline (`playbooks/site.yml`)

```
00_bootstrap_rhel8.yml   raw: install python3.11 if missing               (RHEL8 only)
10_rhel8_baseline.yml    role svc_appdev: account, dirs, sshd check, fw   (RHEL8 only)
20_ssh_trust.yml         collect mesh_node from every host, then render  (RHEL7 + RHEL8)
                         and write the managed blocks on every host
30_verify_ssh.yml        SSH every source -> every target, assert OK     (RHEL7 + RHEL8)
```

`20_ssh_trust.yml` is internally two phases:

1. **Collect** (`hosts: rhel8` then `hosts: rhel7`, both `any_errors_fatal:
   true`): ensure a key pair exists, gather user/host public keys and
   addresses, assert the result looks sane (`assert` on non-empty
   `user_keys`/`host_keys`), and store it as `mesh_node`.
2. **Apply** (`hosts: rhel8` then `hosts: rhel7`): render the three templates
   against `trust_sources`/`trust_targets` (all mesh hosts, or RHEL8-only
   once `rhel7_in_mesh: false`) and write them — `blockinfile` on RHEL8,
   `rhel7_apply.sh.j2` via `raw` on RHEL7.

`30_verify_ssh.yml` has three plays: RHEL8 sources (using `become_user:
{{ app_user }}` so the check runs as the mesh account itself), RHEL7 sources
(`su - appdev -c '...'` inside a `raw` command, since no Python is available
to `become` with), and a final `hosts: localhost` play that stitches every
host's `ssh_check` fact into one matrix and fails the run if any path is not
`OK`.

### 3.3 RHEL7 scripts

Two scripts, run via `raw` with their content passed through as
base64-encoded here-docs (`echo <b64> | base64 -d | /bin/bash`) so no
temporary file needs to be staged on the target:

- **`rhel7_collect.sh.j2`** — resolves `appdev`'s home via `getent passwd`
  (not a hardcoded path), generates an SSH key only if none exists, and
  prints tagged lines (`USERKEY `, `HOSTKEY `, `NAME `, `ADDR `) that the
  playbook parses back into a `mesh_node` fact. Honours `ansible_check_mode`
  itself (`DRY_RUN`), since `raw` does not support Ansible's check-mode
  short-circuiting automatically.
- **`rhel7_apply.sh.j2`** — a small idempotent block-writer (`put_block`)
  that strips any existing `BEGIN`/`END`-delimited region from a file with
  `awk`, re-inserts the new block at the top or bottom, and only rewrites
  the file if the result actually differs (`cmp -s`), reporting
  `RESULT=changed`/`RESULT=unchanged` for Ansible's `changed_when`.

Both scripts run `restorecon -R` after touching `~/.ssh` when available, so
SELinux contexts stay correct without requiring the `community.general`
SELinux modules (which need Python).

### 3.4 Cryptography and policy guards

- `ssh_key_type` defaults to `ed25519` (works on both OpenSSH 7.4/RHEL7 and
  8.0/RHEL8); switch to `rsa` (`ssh_key_bits: 4096`) for RHEL8 FIPS mode,
  where ed25519 is disallowed.
- `rhel7_collect.sh.j2`'s output is filtered in the *playbook* (not the
  script) to drop any `ssh-dss` host key, with a `debug` warning if `appdev`
  on RHEL7 only has a DSA user key — RHEL8's `DEFAULT` crypto policy rejects
  both.
- `roles/svc_appdev/tasks/main.yml` runs `sshd -T` and asserts
  `pubkeyauthentication yes` and, if `AllowUsers` is set, that it includes
  `svc_appdev`; it only warns (doesn't fail) on `AllowGroups`, since group
  membership can't be verified from `sshd -T` output alone.

### 3.5 Configuration surface

Three layers, narrowest last:

1. `inventory/group_vars/all.yml` — mesh-wide: `rhel7_in_mesh`,
   `ssh_key_type`/`ssh_key_bits`, `restrict_key_source`, `managed_marker`.
2. `inventory/group_vars/{rhel7,rhel8}.yml` — per-platform account identity
   (`app_user`, and on RHEL8 `app_group`/`app_home`/
   `ansible_python_interpreter`).
3. `roles/svc_appdev/defaults/main.yml` — role internals not tied to the
   trust mesh itself (`app_directories`, `app_legacy_home_symlink`,
   `app_manage_firewall`, `app_uid`/`app_gid` for shared-NFS ownership).

Per-host `mesh_address` in `inventory/hosts.yml` overrides the address other
mesh hosts use to reach that specific host (e.g. a private/NAT address
different from `ansible_host`).

### 3.6 `~/.ssh/config`: general purpose and how this project uses it

`~/.ssh/config` is the OpenSSH client's own per-user config file. It maps an
alias to a full connection recipe — `HostName` (real address), `User`,
`IdentityFile`, and behaviour flags like `StrictHostKeyChecking` — so
`ssh <alias>` expands to the right connection without the caller spelling
out every option. It is read top to bottom, and for any given option SSH
keeps the **first** matching value it finds; a later, more general block
(e.g. a trailing `Host *`) never overrides one set earlier.

That read-order rule is what this project's username trick depends on.
[`templates/ssh_config.j2`](../playbooks/templates/ssh_config.j2) renders
one `Host` block per mesh host, listing every alias that host is known by
(short name, FQDN, inventory name, IP) and pointing all of them at the
*correct* `User` for that platform:

```jinja
Host {{ ([h, n.connect] + n.names + n.addrs) | unique | join(' ') }}
    HostName {{ n.connect }}
    User {{ n.user }}
    BatchMode yes
    StrictHostKeyChecking yes
```

The block rendered against `rhel8-app01`'s `mesh_node` sets `User
svc_appdev`; the block rendered against `rhel7-app01`'s sets `User appdev`.
A script never names a user at all — it just runs `ssh rhel8-app01 ...` —
so SSH itself supplies whichever account is correct for the platform it's
running on.

Two implementation choices make this hold up:

- **Inserted at the top, not appended.** The `blockinfile` task in
  `20_ssh_trust.yml` uses `insertbefore: BOF` on RHEL8; `rhel7_apply.sh.j2`'s
  `put_block` does the same with its `top` mode (§3.3). Because SSH takes the
  *first* match, nothing added later in the file — by hand or by another tool
  — can silently override the mapping.
- **A managed block, not the whole file.** Only the marked region is ever
  rewritten (§2.4), so any `Host` entries an admin added themselves stay
  exactly where they are, below the managed block.

`known_hosts`/`ssh_known_hosts` are maintained the same way from the same
`mesh_node` data (`templates/known_hosts.j2`), which is what lets every
block also set `StrictHostKeyChecking yes` (§2.6) without ever prompting.

### 3.7 Testing

There is no CI in this repository; `tests/run.sh` and `tests/edge.sh` are the
only test entry points (Linux/WSL + ansible-core + `ansible.posix` required).
Both fake the target environment rather than mocking Ansible: `tests/
fakebin/getent` redirects the app user's home to a temp dir so the scripts
run for real against `localhost` (`ansible_connection: local`) without
touching the operator's own `~/.ssh` or any server, and `tests/test.yml`
additionally copies the rendered RHEL8-side blocks out to inspectable files.
`run.sh` covers syntax-checking every playbook plus idempotency (running the
trust play twice) and `--check` mode; `edge.sh` covers preserving
pre-existing file content, in-place key rotation, the decommission render,
and the verify playbook's failure-reporting path. See `../tests/README.md`
and the runbook's testing section for how to run them.
