# Security

## Reporting a vulnerability

Please report security issues privately through GitHub: **Security → Report a vulnerability** on this repository. Don't open a public issue for them. You'll get a reply within a few days.

## What's protected

- **Releases** are built from tagged commits on `main` by `scripts/release.sh`. Every release lists SHA-256 checksums (`SHA256SUMS.txt`); check your download with `shasum -a 256 -c SHA256SUMS.txt` before opening it.
- **`main` is protected**: no force-pushes or deletion, and pull requests must pass CI before they can be merged.
- **No secrets in the repository.** Secret scanning with push protection is on.
- **Your data stays local.** Provider logins live only in `~/Library/Application Support/Open IPTV/sources.json` with owner-only permissions. Stream URLs (which contain the password) are never written to caches or logs.
- **Network**: the app talks to your provider, to image hosts for logos and posters, and (optional, can be turned off) to Cinemeta for movie and series details. AirPlay serves the current stream on your local network only while AirPlay is active.
