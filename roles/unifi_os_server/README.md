# unifi_os_server

Installs Ubiquiti UniFi OS Server on a Debian/Ubuntu VM, locks the host down
with ufw, and (optionally) obtains and auto-renews a Let's Encrypt
certificate for the web UI via acme.sh (DNS-01).

## Installation

This role ships as part of the `jnix85.unifi` collection:

```bash
ansible-galaxy collection install jnix85.unifi
```

(`community.general` is pulled in automatically as a collection dependency.)
Then use it as `jnix85.unifi.unifi_os_server` in your playbook's `roles:`.

## Requirements

- Target: Ubuntu 22.04/24.04 or Debian 12/13, x86_64 or aarch64 (e.g. a
  Raspberry Pi), min ~2 vCPU / 4GB RAM / 25GB disk
- Outbound HTTPS access from the target host to `fw-update.ui.com` (firmware
  metadata API) and `fw-download.ubnt.com` (installer binary) — no Ubiquiti
  account or auth is required for either
- `community.general` collection installed for the `ufw` module (used by
  default — see Firewall below)

## Role Variables

See `defaults/main.yml`. No variables are required — by default the role
queries Ubiquiti's public firmware API (`fw-update.ui.com/api/firmware-latest`)
for the current `unifi-os-server` release matching the host's architecture
(`linux-x64` or `linux-arm64`, via `unifi_os_server_arch_platforms`) on the
`release` channel, and installs it.

To pin an exact version instead of auto-resolving, set
`unifi_os_server_installer_url` to a specific `_links.data.href` value from
that API (or `unifi_os_server_channel: beta-public` to track beta releases).

## Firewall

By default (`unifi_os_server_manage_ufw: true`) this role installs `ufw` and
locks the host down to deny-all-incoming except:

- SSH, on the port(s) in `unifi_os_server_ssh_ports` (default `[22]`) — set
  this to your actual SSH port(s) *before* running the role if you've moved
  SSH off 22, or you'll lock yourself out
- The UniFi OS Server ports in `unifi_os_server_ports` (web UI, device
  inform, guest portal, STUN, discovery)

Outgoing traffic is left allowed. Set `unifi_os_server_manage_ufw: false` if
you manage firewalling elsewhere and don't want this role touching ufw.

## Let's Encrypt Certificate

Set `unifi_os_server_ssl_enabled: true` to have the role obtain (and keep
renewed) a Let's Encrypt certificate for the web UI, via an
[acme.sh](https://github.com/acmesh-official/acme.sh) **DNS-01** challenge —
no inbound port 80 is needed, so it works unchanged with the default-deny ufw
posture above.

```yaml
unifi_os_server_ssl_enabled: true
unifi_os_server_ssl_fqdn: uos.example.com
unifi_os_server_ssl_extra_fqdns: [uos1.example.com, uos2.example.com]
unifi_os_server_ssl_email: admin@example.com
unifi_os_server_ssl_dns_provider: dns_cf
unifi_os_server_ssl_dns_env:
  CF_Token: "{{ vault_cloudflare_api_token }}"
  CF_Zone_ID: "{{ vault_cloudflare_zone_id }}"       # optional
  CF_Account_ID: "{{ vault_cloudflare_account_id }}" # optional
```

- `unifi_os_server_ssl_dns_provider` is an acme.sh DNS API hook name
  (`dns_cf`, `dns_aws`, `dns_dgon`, …) — any of the ~150 providers in
  [acme.sh's dnsapi wiki](https://github.com/acmesh-official/acme.sh/wiki/dnsapi).
- `unifi_os_server_ssl_dns_env` holds the environment variables that hook
  expects, normally referencing ansible-vault variables. For Cloudflare
  (`dns_cf`): `CF_Token` (an API token with `Zone / DNS / Edit`), plus
  optionally `CF_Zone_ID` and `CF_Account_ID` — with a zone-scoped token
  these let the hook skip zone discovery (which would otherwise require
  `Zone / Zone / Read`). The issue task runs with `no_log: true`, and
  acme.sh persists the values into `~/.acme.sh/account.conf` (mode 0600) so
  cron-driven renewals run unattended.
- `unifi_os_server_ssl_extra_fqdns` (optional) lists additional names on the
  **same** certificate as SANs; changing the list makes acme.sh reissue with
  the new set on the next run. Re-runs with an unchanged set are a no-op
  (acme.sh skips certs not yet due for renewal).
- The role installs acme.sh from git (`unifi_os_server_ssl_acme_repo` /
  `_version`, override to pin a release tag) and issues from Let's Encrypt
  (`unifi_os_server_ssl_acme_ca: letsencrypt` — acme.sh's own default would
  be ZeroSSL).
- The cert is imported the same way GlennR's `unifi-easy-encrypt.sh` does it
  for a Podman-based `uosserver` install: acme.sh's `--install-cert` drops
  `fullchain.pem`/`privkey.pem` into `unifi_os_server_ssl_cert_dir`
  (default `/etc/uosserver-ssl`), then runs the import script
  (`templates/unifi-os-server-cert-deploy-hook.sh.j2`, installed to
  `/usr/local/sbin/unifi-os-server-cert-install.sh`), which copies them into
  the `uosserver_data` volume's `eus_certificates/` directory, references
  them from `unifi-core/config/overrides/local.yml`, fixes ownership to
  `uosserver:uosserver`, and restarts the service. The script is registered
  as acme.sh's `--reloadcmd`, so it re-runs automatically after every
  renewal — renewals are handled by acme.sh's own daily cron entry, not by
  Ansible.
- Requires `unifi_os_server_run_installer: true` (i.e. `uosserver` actually
  installed) since the import script calls `systemctl stop`/`start` on
  `uosserver.service`.

## Example Playbook

```yaml
- hosts: unifi_os_server
  become: true
  roles:
    - role: unifi_os_server
      vars:
        unifi_os_server_ssh_ports: [22]
        unifi_os_server_ssl_enabled: true
        unifi_os_server_ssl_fqdn: uos.example.com
        unifi_os_server_ssl_dns_provider: dns_cf
        unifi_os_server_ssl_dns_env:
          CF_Token: "{{ vault_cloudflare_api_token }}"
```

## Notes

- The installer is idempotent-guarded on `/etc/systemd/system/uosserver.service`
  existing — re-running the playbook after a successful install is a no-op for
  the download/install steps.
- The installer only prompts for `y/n` confirmations; this role pipes `yes y`
  into it for unattended runs. There is no officially documented silent-install
  flag.
- First-run setup (naming the server, creating/linking a Ubiquiti account,
  provisioning the Network application) happens in the web UI at
  `https://<host>:11443/` and is **not** automated by this role.
- It's normal to see "unifi-core did not start within 60 seconds" during
  install — the role waits up to `unifi_os_server_startup_timeout` (default
  300s) for the web UI port to open rather than trusting the installer's own
  timeout message.

## Testing

This role has a Molecule scenario (`molecule/default`) that converges on
Ubuntu 22.04 and Debian 12 containers. Actually downloading and running the
real ~880MB installer under Podman-in-a-container isn't practical in CI, so
the scenario sets `unifi_os_server_run_installer: false`, which makes the
role stop short of the download/install/service-start steps while still
exercising: OS/arch assertions, live firmware-API version resolution,
dependency package installation, and the ufw lockdown. `verify.yml` asserts
those outcomes directly, including an independent call to the firmware API
to catch upstream response-shape changes.

```bash
pip install molecule molecule-plugins[docker] ansible-core docker
cd roles/unifi_os_server
molecule test
```

Set `unifi_os_server_run_installer: true` (e.g. against a real VM, not
Molecule's container) to exercise the full install path end to end.

The Let's Encrypt path (`unifi_os_server_ssl_enabled: true`) isn't covered by
Molecule — it needs a real DNS zone, provider credentials, and a running
`uosserver`, none of which fit a disposable CI container.
