#!/bin/bash
set -u
export PYTHONPATH=$HOME/.anslib ANSIBLE_COLLECTIONS_PATH=$HOME/.anscoll
export ANSIBLE_CONFIG=$PWD/../ansible.cfg ANSIBLE_INVENTORY=$PWD/inventory.yml ANSIBLE_ROLES_PATH=$PWD/../roles
export FAKEHOME=$(mktemp -d) PATH=$PWD/fakebin:$PATH
cp -r ../inventory/group_vars .
mkdir -p $FAKEHOME/hostkeys $FAKEHOME/.ssh && ssh-keygen -q -t ed25519 -N "" -f $FAKEHOME/hostkeys/ssh_host_ed25519_key
ssh-keygen -q -t ed25519 -N "" -C existing@r7 -f $FAKEHOME/.ssh/id_ed25519
printf 'ssh-rsa AAAAB3EXISTING legacy@rhel7-app02\n' > $FAKEHOME/.ssh/authorized_keys
printf 'Host *\n    User someone_else\n    ServerAliveInterval 30\n' > $FAKEHOME/.ssh/config
X="-f 1 -e ansible_become=false -e ansible_python_interpreter=/usr/bin/python3 -e ssh_host_key_dir=$FAKEHOME/hostkeys"
AP="python3 -m ansible playbook"
echo "== run with pre-existing files"
$AP test.yml --limit rhel7 $X 2>&1 | grep -E '^r7|fatal'
echo "--- authorized_keys"; cat $FAKEHOME/.ssh/authorized_keys
echo "--- config (managed block must be first)"; cat $FAKEHOME/.ssh/config
echo "--- existing key reused, no new key generated:"; ls $FAKEHOME/.ssh/id_* 
echo "== rotate r8a key -> block updated in place"
sed -i "s/FAKEr8akey/ROTATEDr8akey/" host_vars/r8a.yml; trap 'sed -i "s/ROTATEDr8akey/FAKEr8akey/" host_vars/r8a.yml' EXIT
$AP test.yml --limit rhel7 $X 2>&1 | grep -E '^r7|fatal'
grep -c 'BEGIN ANSIBLE' $FAKEHOME/.ssh/authorized_keys; grep r8a $FAKEHOME/.ssh/authorized_keys
echo "== decommission render (rhel7_in_mesh=false): RHEL7 plays skip, RHEL8 blocks drop r7"
$AP test.yml --limit 'rhel7,localhost' $X -e rhel7_in_mesh=false 2>&1 | grep -E '^(r7|localhost)|fatal'
grep -c 'r7' $FAKEHOME/rhel8_authorized_keys $FAKEHOME/rhel8_known_hosts $FAKEHOME/rhel8_ssh_config
echo "== verify playbook report path (expect FAILs: no real sshd here)"
$AP ../playbooks/30_verify_ssh.yml --limit 'rhel7,localhost' $X 2>&1 | grep -E -A12 'Show matrix' | head -14
$AP ../playbooks/30_verify_ssh.yml --limit 'rhel7,localhost' $X 2>&1 | grep -E 'Every path|fatal: \[localhost' | head -3
