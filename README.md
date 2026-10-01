# jnix85.unifi

Ansible collection for standing up Ubiquiti UniFi OS Server on a Debian/Ubuntu
VM: dependency install, version auto-resolution, a locked-down ufw firewall,
and (optionally) an auto-renewing Let's Encrypt certificate for the web UI
(acme.sh, DNS-01).

```bash
ansible-galaxy collection install jnix85.unifi
```

Roles: [`jnix85.unifi.unifi_os_server`](roles/unifi_os_server/README.md).
This repo also carries an example playbook + inventory wrapper (excluded from
the built collection via `build_ignore` in `galaxy.yml`).

## Layout

```
.
├── site.yml                    # playbook applying the role
├── ansible.cfg                 # roles path + vault password file location
├── inventory/
│   ├── hosts.yaml.example      # unifi_os_server group — copy to hosts.yaml
│   └── group_vars/unifi_os_server/
│       ├── vars.yml.example    # per-site settings — copy to vars.yml
│       └── vault.yml.example   # secrets template — copy, fill, vault-encrypt
│       # hosts.yaml, vars.yml, vault.yml are gitignored: your real config
│       # stays local; commit only the .example copies
└── roles/
    └── unifi_os_server/        # the role itself — see its README for full details
        ├── defaults/main.yml   # all configurable variables
        ├── tasks/main.yml      # install + firewall
        ├── tasks/ssl.yml       # Let's Encrypt via acme.sh (DNS-01), when enabled
        ├── templates/          # cert import script (acme.sh --reloadcmd)
        └── molecule/default/   # Molecule test scenario (Docker driver)
```

## Requirements

- Control node: Ansible core 2.14+, `community.general` collection (used for
  the `ufw` module)
- Target: Ubuntu 22.04/24.04 or Debian 12/13, x86_64 or aarch64 (e.g. a
  Raspberry Pi), ~2 vCPU / 4GB RAM / 25GB disk minimum
- Outbound HTTPS from the target to `fw-update.ui.com` and
  `fw-download.ubnt.com` (no Ubiquiti account/auth needed)

## Quickstart

```bash
# 1. Inventory: your target host(s)
cp inventory/hosts.yaml.example inventory/hosts.yaml

# 2. Site config: FQDNs, ACME email, DNS provider, connection user
cp inventory/group_vars/unifi_os_server/vars.yml.example \
   inventory/group_vars/unifi_os_server/vars.yml

# 3. Secrets: sudo password + DNS API credentials, vault-encrypted
openssl rand -base64 32 > .vault_pass && chmod 600 .vault_pass
cp inventory/group_vars/unifi_os_server/vault.yml.example \
   inventory/group_vars/unifi_os_server/vault.yml
# fill in the CHANGE_ME values, then:
ansible-vault encrypt inventory/group_vars/unifi_os_server/vault.yml

# 4. Run
ansible-playbook -i inventory/hosts.yaml site.yml
```

By default this installs UniFi OS Server (auto-resolving the latest release)
and locks ufw down to deny-all-incoming except SSH and the UniFi ports. See
[`roles/unifi_os_server/README.md`](roles/unifi_os_server/README.md) for the
full variable reference, firewall behavior, and how to enable the Let's
Encrypt integration.

## Testing

The role ships a Molecule scenario covering everything short of the actual
multi-hundred-MB install (impractical to run in a disposable container):

```bash
pip install molecule molecule-plugins[docker] ansible-core docker
cd roles/unifi_os_server
molecule test
```

See that role's README for what is and isn't covered by these tests.
