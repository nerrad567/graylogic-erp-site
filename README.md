# 🌐 graylogic.uk – Real Business ERP with Docker, Odoo, and Traefik

[![Live Site](https://img.shields.io/badge/Live-graylogic.uk-success?style=for-the-badge&logo=firefoxbrowser)](https://www.graylogic.uk)
![Platform](https://img.shields.io/badge/Platform-Ubuntu%20VM-blue?style=for-the-badge&logo=ubuntu)
![ERP Stack](https://img.shields.io/badge/Stack-Odoo%20%7C%20PostgreSQL-8E44AD?style=for-the-badge&logo=odoo)
![Containerized](https://img.shields.io/badge/Containers-Docker%20%7C%20Traefik-2496ED?style=for-the-badge&logo=docker)
![Automation](https://img.shields.io/badge/Scripting-Bash%20%7C%20PowerShell-4B275F?style=for-the-badge&logo=gnubash)
![Backups](https://img.shields.io/badge/Backups-GPG%20Encrypted-critical?style=for-the-badge&logo=gnuprivacyguard)
![Security](https://img.shields.io/badge/Secure_by-Design-2ea44f?style=for-the-badge&logo=shield)
![Status](https://img.shields.io/badge/Status-Production-green?style=for-the-badge&logo=server)


A self-hosted, production-grade Odoo stack powering my electrical business website [graylogic.uk](https://www.graylogic.uk). Built in my spare time while working full-time as an electrician, this project showcases my ability to manage infrastructure, automate deployments, and secure live services.

---

## 🔧 What It Is

- **Live ERP Site**: [https://www.graylogic.uk](https://www.graylogic.uk)
- **Purpose**: Manage quotes, invoices, client info, and documents through Odoo.
- **Hosted On**: Hetzner Cloud (Ubuntu VM)
- **Developed**: Evenings/weekends around a full-time job

---

## 🛠️ Tech Stack

| Component       | Tech Used                     |
|----------------|-------------------------------|
| **ERP Platform** | Odoo (latest)                |
| **Containerization** | Docker, Docker Compose   |
| **Reverse Proxy** | Traefik (Let's Encrypt TLS) |
| **Database**    | PostgreSQL                   |
| **Web Server**  | Nginx (for static routes)     |
| **Backup & Automation** | Bash (Linux), PowerShell (Windows) |
| **Security**    | iptables, GPG encryption, SSH hardening |

---

## 💡 Features & Design Choices

### 🔒 Security-First
- Custom iptables rules via `flameon.sh`
  - Drops all IPv6
  - Allows only essential inbound ports: 22, 80, 443, 8080
- Traefik middleware:
  - Rate limiting
  - IP whitelisting
  - Basic Auth for dashboard & database manager
  - HTTPS enforced with TLS challenge

### 📦 Dockerized & Modular
- One `docker-compose.yml` to manage:
  - Odoo app
  - PostgreSQL database
  - Traefik reverse proxy
  - Nginx for static file handling
- Labels and middleware dynamically route requests based on content type

### 🔐 Encrypted Backups
- Linux Bash script:
  - Encrypts backups using GPG
  - Rotates old files after 30 days
- PowerShell retrieval script:
  - Fetches from remote
  - Decrypts using YubiKey
  - Securely deletes decrypted content with SDelete
- Includes fail-safe cleanup mode: `-WipeConfidential`

### 🧠 Password Hygiene
- `genpasswords.sh` creates high-entropy, alphanumeric passwords between 32–64 characters
- Export-friendly format for `.env` usage

---

## 📁 File Tree
```
graylogic-uk/
 ├── docker-compose.yml # Full stack definition
 ├── config/
 │ └── odoo.conf # Sanitized Odoo config
 ├── scripts/
 │ └── backup.sh # GPG backup script (Linux)
 │ └── retrieveBackup.ps1 # GPG restore script (Windows)
 │ └── flameon.sh # Firewall rules (iptables)
 │ └── genpasswords.sh # Random password generator
 │
 ├── static/ # Static files (e.g., DNS challenge)
```
 
---

## 🚀 How It Works

1. **Provision Server**: Fresh Ubuntu VM from Hetzner
2. **Secure VM**: `./scripts/flameon.sh`
3. **Deploy Stack**: `docker-compose up -d`
4. **Auto HTTPS**: Traefik uses Let’s Encrypt (TLS challenge)
5. **Use Odoo**: Handles ERP features like invoices, quotes, and client comms
6. **Backup**: `./scripts/backup.sh` (server) + `retrieveBackup.ps1` (Windows)

---

## 🧩 Why This Matters

This project isn't just a demo—it's powering a real business. It reflects:
- Real-world deployment constraints
- DevOps best practices
- Secure handling of business-critical data
- Self-reliance and adaptability

Built to **learn**, **serve**, and **prove**.

---

---

## 🧠 Under the Hood – Traefik Routing & Middleware Explained

My Traefik setup securely routes and manages traffic for multiple Odoo services using custom rules and middleware. It separates **static assets**, **dynamic content**, and **admin endpoints** to optimize performance and security.

---

### 🧩 1. Dynamic Router (`odoo-dynamic`)

Handles all **interactive, backend-driven content** from Odoo.

#### Rule:
```
Host(www.graylogic.uk) && !PathPrefix(/web/static) && !PathPrefix(/web/assets) && !PathPrefix(/web/image) && !Path(/6fsz4eyx5z5ybanmxzzgrjer6pu4kqb5.txt) && !PathPrefix(/web/database)
```

#### What it serves:
- Main website frontend (pages, forms, dashboards)
- Dynamic routes like contact forms, quote generation
- JSON-RPC and AJAX calls from the browser
- Any logic requiring Odoo's Python backend

#### What it excludes:
- Static files (e.g., CSS, JS, images)
- Static site verification files (e.g., Google/Bing verification)
- Odoo database manager (routed separately)

#### Middleware:
- `odoo-https-header`: Forces HTTPS awareness for Odoo (`X-Forwarded-Proto`)
- `compress`: Enables gzip compression for faster delivery

---

### 🖼️ 2. Static Router (`odoo-static`)

Handles all **static assets** that don’t change often.

#### Rule:
```
Host(www.graylogic.uk) && (PathPrefix(/web/static) || PathPrefix(/web/assets) || PathPrefix(/web/image) || PathPrefix(/unsplash))
```

#### What it serves:
- JavaScript, CSS, fonts, and image files
- Unchanging assets that benefit from aggressive caching

#### Middleware:
- `odoo-cache`: Adds this header to responses:

This allows browsers to cache the files for 1 year.
- `compress`: Reduces size of responses via gzip
- `odoo-https-header`: Maintains Odoo’s HTTPS expectations

---

### 🔐 3. Admin Router (`odoo-db`)

Protects access to the Odoo database manager interface, utlises  rate limiting and ip whitelisting via middleware stack

#### Rule:
```
Host(`www.graylogic.uk`) && PathPrefix(`/web/database`) 
```

#### Middleware Stack:
- `odoo-db-ip`: IP allowlist (only trusted IPs can access)
- `odoo-db-auth`: Basic HTTP authentication using env-stored credentials
- `odoo-db-rate`: Rate limiting (protects against brute-force)
- `odoo-https-header`: Ensures HTTPS context for internal routing

✅ This endpoint is locked down with multiple layers of protection.

---

### 🌐 4. Canonical Redirect Router (`odoo-redirect`)

Redirects traffic from alternate domains to the canonical domain: `www.graylogic.uk`.

#### Rule:
```
Host(graylogic.uk) || Host(graylogic.co.uk) || Host(www.graylogic.co.uk) || Host(colchester-electrician.com) || Host(www.colchester-electrician.com)
```

#### Middleware:
- `redirect-to-canonical`: Uses regex to redirect to:
https://www.graylogic.uk{path}


with a permanent (`301`) redirect.

📈 This ensures SEO consistency and a unified domain structure.

---

## 🛡️ Middleware Strategy Summary

| Middleware             | Purpose                                             |
|------------------------|-----------------------------------------------------|
| `odoo-https-header`    | Sets `X-Forwarded-Proto: https` for Odoo awareness  |
| `compress`             | Enables gzip compression                            |
| `odoo-cache`           | Sets `Cache-Control` headers for static files       |
| `odoo-db-auth`         | Requires login for database manager                 |
| `odoo-db-ip`           | IP allowlist for admin endpoints                    |
| `odoo-db-rate`         | Prevents brute-force attempts via rate limiting     |
| `redirect-to-canonical`| Redirects all non-canonical domains to the main one |

---

### 🏁 Result

Your routing layer:
- Improves performance through compression and caching
- Protects sensitive surfaces with layered security
- Maintains clean domain structure for SEO
- Separates static and dynamic traffic for clarity and scalability

This is a production-grade routing setup, tailored to Odoo’s architecture and hardened for real-world use.


## 📬 Contact

- **GitHub**: [@nerrad567](https://github.com/nerrad567)
- **Email**: darren.g@outlook.com
- **LinkedIn**: [linkedin.com/in/darren-gray-70258a169](https://www.linkedin.com/in/darren-gray-70258a169)

---

> ⚠️ Note: Sensitive values (e.g. passwords, keys, and environment files) are excluded. Replace with your own if replicating this stack.
