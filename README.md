# ansible-role-pssid-data-pipeline

Stands up the **pSSID data analytics pipeline** on an Ubuntu 22 VM via Docker
Compose: OpenSearch + Logstash + Grafana, with optional nginx/Certbot HTTPS and
OpenSearch Dashboards. Grafana is fully provisioned — after the play finishes,
open the VM in a browser and the pSSID dashboard is already wired to the
OpenSearch datasource, **no manual UI steps**.

This role automates the manual runbook in the
[`pssid-data-pipeline`](https://github.com/UMNET-perfSONAR/pssid-data-pipeline)
README. It vendors its own copies of the compose files, Logstash pipeline,
`esnet-matrix-panel` plugin, and example dashboard, so it has no runtime
dependency on that repo.

## Requirements

- Target host: **Ubuntu 22.04 (jammy)**, reachable over SSH with `become` (sudo).
- Control node collections (see [`requirements.yml`](requirements.yml)):

  ```bash
  ansible-galaxy collection install -r requirements.yml
  ```

  - `community.docker` >= 3.6.0
  - `ansible.posix` >= 1.5.0
- `ansible-core` >= 2.15.
- For HTTPS: the DNS name in `pssid_pipeline_hostname` must resolve to the VM
  and ports 80/443 must be reachable from the internet (Let's Encrypt HTTP-01).

## Role variables

See [`defaults/main.yml`](defaults/main.yml) for the full list. The important ones:

| Variable | Default | Notes |
|---|---|---|
| `pssid_pipeline_hostname` | *(required)* | Public FQDN; drives `GF_SERVER_ROOT_URL` + nginx/cert paths |
| `pssid_opensearch_password` | *(required, vault)* | OpenSearch admin password |
| `pssid_grafana_admin_password` | *(required, vault)* | Grafana admin password. Without it Grafana boots on `admin`/`admin` |
| `pssid_grafana_admin_user` | `admin` | Grafana admin username |
| `pssid_pipeline_dir` | `/opt/pssid-data-pipeline` | Where files are staged on the VM (root-owned) |
| `pssid_enable_https` | `false` | nginx + Certbot Let's Encrypt |
| `pssid_certbot_email` | `""` | Required when HTTPS is enabled |
| `pssid_enable_opensearch_dashboards` | `false` | Optional OpenSearch Dashboards on :5601 |
| `pssid_grafana_google_sso_enabled` | `false` | Google OAuth (disables basic auth) |
| `pssid_grafana_smtp_enabled` | `false` | SMTP alerting |
| `pssid_grafana_datasource_uid` | `opensearch-pscheduler` | Pinned datasource UID |

Secrets (`pssid_opensearch_password`, `pssid_grafana_admin_password`,
`pssid_grafana_google_client_secret`, `pssid_grafana_smtp_password`) should come
from **Ansible Vault** — never commit them in plaintext.

> **Grafana admin password:** Grafana only applies `admin_password` on the
> **first** initialization of its database. If an instance already booted with
> the default `admin`/`admin`, setting this variable will not retroactively
> change it — remove the `grafana-data` volume (`docker volume rm
> pssid-data-pipeline_grafana-data`) and re-run, or change it in the UI.

## Usage

### 1. Add to `requirements.yml` (in your playbook repo)

```yaml
- name: ansible-role-pssid-data-pipeline
  src: https://github.com/UMNET-perfSONAR/ansible-role-pssid-data-pipeline.git
  version: main
```

```bash
ansible-galaxy install -r requirements.yml --roles-path roles
```

### 2. Inventory

```ini
[pssid_data_pipeline]
pssid-metrics.example.edu
```

### 3. Variables — `group_vars/pssid_data_pipeline/vars.yml`

```yaml
pssid_pipeline_hostname: pssid-metrics.example.edu
pssid_enable_https: true
pssid_certbot_email: uniqname@umich.edu
pssid_opensearch_password: "{{ vault_pssid_opensearch_password }}"
# optional:
# pssid_grafana_google_sso_enabled: true
# pssid_grafana_google_client_id: "your-client-id"
# pssid_grafana_google_client_secret: "{{ vault_pssid_grafana_google_client_secret }}"
```

### 4. Secrets — `group_vars/pssid_data_pipeline/vault.yml` (encrypt it)

```bash
ansible-vault create group_vars/pssid_data_pipeline/vault.yml
```

```yaml
vault_pssid_opensearch_password: "a-strong-password"
# vault_pssid_grafana_google_client_secret: "..."
```

### 5. Play

```yaml
---
- name: deploy pSSID data pipeline
  hosts: pssid_data_pipeline
  become: true
  roles:
    - ansible-role-pssid-data-pipeline
```

```bash
ansible-playbook -i inventory/hosts playbook.yml --ask-vault-pass
```

## What it does (maps to the manual README)

1. Installs Docker Engine + Compose plugin (custom apt tasks).
2. Tunes `vm.max_map_count` for OpenSearch.
3. Stages compose files, Logstash pipeline, plugin, and Grafana provisioning.
4. Creates the shared Docker network and brings up the stacks in order:
   OpenSearch → Logstash → Grafana (+nginx/Certbot if HTTPS) → optional Dashboards.
5. For HTTPS: bootstraps nginx on HTTP, issues the Let's Encrypt cert once, swaps
   to the HTTPS config, reloads nginx. Reruns are idempotent (cert issuance is
   skipped when a cert already exists).
6. Provisions the OpenSearch datasource (pinned UID) and imports the pSSID
   dashboard via Grafana file provisioning, rewriting the dashboard's hardcoded
   datasource UIDs so every panel resolves on first load.
7. Verifies Grafana health and (when basic auth is available) that the datasource
   and dashboard were provisioned.

## Scope

The role guarantees Grafana is up and the dashboard is visible and wired to the
datasource. Whether panels show **live data** depends on pscheduler probes
shipping data via Filebeat → Logstash (port 9400) → OpenSearch — that is the
separate probe-side pipeline
([`ansible-role-filebeat`](https://github.com/UMNET-perfSONAR/ansible-role-filebeat)),
outside this role's control.

## Notes / caveats

- Verifying idempotency: run the play twice; the second run should report no
  changes except handlers that never fire. `--check` mode is **not** reliable
  here because `docker_compose_v2` / `docker_network` / `docker_container_exec`
  have limited check-mode support — use a live second run.
- With Google SSO enabled, Grafana basic auth is disabled, so the role skips the
  authenticated datasource/dashboard API checks — verify in the browser.
