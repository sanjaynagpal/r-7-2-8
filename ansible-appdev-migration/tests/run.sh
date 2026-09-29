#!/bin/bash
set -u
export PYTHONPATH=$HOME/.anslib ANSIBLE_COLLECTIONS_PATH=$HOME/.anscoll
export ANSIBLE_CONFIG=$PWD/../ansible.cfg ANSIBLE_INVENTORY=$PWD/inventory.yml
export ANSIBLE_ROLES_PATH=$PWD/../roles ANSIBLE_HOST_KEY_CHECKING=False
AP="python3 -m ansible playbook"
python3 -m ansible galaxy collection install -q ansible.posix -p ~/.anscoll >/dev/null 2>&1
echo "== syntax check (real inventory)"
for p in ../playbooks/*.yml; do ANSIBLE_INVENTORY=$PWD/../inventory/hosts.yml $AP --syntax-check "$p" >/dev/null 2>&1 && echo "OK   $p" || { echo "FAIL $p"; ANSIBLE_INVENTORY=$PWD/../inventory/hosts.yml $AP --syntax-check "$p" 2>&1 | tail -5; }; done
echo "== functional run"
export FAKEHOME=$(mktemp -d) PATH=$PWD/fakebin:$PATH
cp -r ../inventory/group_vars .   # use project group_vars with the test inventory
mkdir -p $FAKEHOME/hostkeys && ssh-keygen -q -t ed25519 -N "" -C root@r7 -f $FAKEHOME/hostkeys/ssh_host_ed25519_key
EXTRA="-f 1 -e ansible_become=false -e ansible_python_interpreter=/usr/bin/python3 -e ssh_host_key_dir=$FAKEHOME/hostkeys"
for run in 1 2; do
  echo "-- run $run"
  $AP test.yml --limit 'rhel7,localhost' $EXTRA 2>&1 | grep -E -A8 'PLAY RECAP|fatal|ERROR' 
done
echo "-- check mode run"
$AP test.yml --limit 'rhel7' $EXTRA --check 2>&1 | grep -E '^(r7)|fatal|ERROR'
echo "== RHEL7 appdev files"; for f in authorized_keys known_hosts config; do echo "--- ~/.ssh/$f"; cat $FAKEHOME/.ssh/$f; done
ls -la $FAKEHOME/.ssh
echo "== RHEL8 rendered blocks"; for f in authorized_keys known_hosts ssh_config; do echo "--- $f"; cat $FAKEHOME/rhel8_$f; echo; done
