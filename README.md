# WordPress + CiviCRM Stack (Traefik, MariaDB, Docker Compose)

A single Bash script that deploys a production-ready stack using:

- **Traefik v3** with Let's Encrypt (auto HTTPS)
- **MariaDB 10.11**
- **WordPress (Apache)**
- **CiviCRM (official civicrm/civicrm image)**

The script provides **interactive prompts** with validation, trimming, retry loops, and a final **review/confirm screen**.  
It also supports a **NONINTERACTIVE mode** for CI/CD pipelines or automated setups.

---

## 🧩 Requirements (simple)

- **OS:** Debian/Ubuntu-based (with `apt`), x86_64
- **Privileges:** Run as `root` or via `sudo`
- **Network:** Ports **80** and **443** open
- **DNS:** Valid A/AAAA records pointing to the server
  - `DOMAIN` (e.g. `example.org`)
  - `CRM_DOMAIN` (e.g. `crm.example.org`)
- **Internet access** for pulling Docker images and Let's Encrypt

> 🐋 Docker and Docker Compose will be automatically installed if not present.

---

## ⚡ Quickstart

### 🧭 Interactive (recommended)

```bash
sudo ./deploy.sh
