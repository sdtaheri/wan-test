# wan-test

`wan-test` is a portable shell script for testing WAN connectivity across one or more network interfaces. It is useful on routers, Linux hosts, Raspberry Pi, macOS, OpenWRT, and iSH when you want a quick per-interface view of DNS, HTTP, CDN, TCP, and proxy facade reachability.

The script reads targets from `config.json`, auto-detects interfaces with default routes when no interface is provided, and prints pass/fail summaries per interface.

## What It Tests

- **Ping reachability**: ICMP ping per interface, with TCP-style fallbacks where raw sockets are unavailable.
- **Plain DNS**: A/record lookups against configured DNS servers.
- **HTTP connectivity**: Basic HTTP GET checks against captive-portal and connectivity URLs.
- **CDN connectivity**: HTTPS checks against configured CDN URLs with a configurable user agent.
- **TCP targets**: Direct host/port connection checks.
- **Proxy facades**: HTTPS reachability and optional WebSocket upgrade checks for CDN/proxy front doors.
- **Encrypted DNS**: DoH, DoT, DoQ, and DNSCrypt checks through `dnslookup`.

## Requirements

Core requirements:

- POSIX `sh`
- `jq` for reading `config.json`
- `curl` or `wget` for HTTP/CDN/proxy checks

Optional tools:

- `dig` or `nslookup` for DNS checks
- `dnslookup` for encrypted DNS checks
- `nc` or shell `/dev/tcp` support for TCP fallback checks

The script can try to install `jq`, DNS tooling, and `dnslookup` on common platforms when package managers are available.

## Quick Start

Clone and run:

```sh
git clone git@github.com:sdtaheri/wan-test.git
cd wan-test
./wan-test.sh
```

If SSH keys are not set up on that machine, use HTTPS instead:

```sh
git clone https://github.com/sdtaheri/wan-test.git
```

Run against one interface:

```sh
./wan-test.sh eth0
```

Run against multiple interfaces:

```sh
./wan-test.sh eth0 wlan0
```

Run only selected test groups:

```sh
./wan-test.sh --tests tcp,proxy,dns eth0
./wan-test.sh tcp proxy dnscrypt
```

Use a specific config file:

```sh
./wan-test.sh --config ./config.json
WAN_TEST_CONFIG=/etc/wan-test/config.json ./wan-test.sh eth0
```

## Configuration

The public `config.json` is intentionally generic and safe to publish. It includes public DNS resolvers, common connectivity-check URLs, and empty custom target lists.

Important fields:

- `pingTargets`: IPs or hosts used for basic reachability checks.
- `dns.lookupDomains`: domains resolved during DNS tests.
- `dns.plain`: DNS servers for plain DNS.
- `dns.doh`, `dns.dot`, `dns.doq`, `dns.dnscrypt`: encrypted DNS endpoints.
- `http.urls`: HTTP URLs expected to return reachable status codes.
- `cdn.urls`: labeled HTTPS/CDN endpoints.
- `tcpTargets`: custom `{ "label", "host", "port" }` TCP checks.
- `proxyFacades`: custom `{ "label", "url", "mode" }` proxy facade checks. Use `"mode": "ws"` for WebSocket front doors.

Keep private IPs, private domains, customer names, proxy endpoints, and provider profile IDs out of the public `config.json`. Use a separate config file for those.

## Recommended Install Pattern

For machines you control, install the public tool once and keep private targets in a separate private repository.

Public tool:

```sh
sudo mkdir -p /opt/wan-test
sudo git clone git@github.com:sdtaheri/wan-test.git /opt/wan-test
sudo ln -sf /opt/wan-test/wan-test.sh /usr/local/bin/wan-test
```

Private config repository:

```sh
mkdir -p ~/.config
git clone git@github.com:<your-user>/<your-private-wan-config-repo>.git ~/.config/wan-test-private
```

Or, if you use the GitHub CLI on a fresh machine:

```sh
gh auth login
gh repo clone <your-user>/<your-private-wan-config-repo> ~/.config/wan-test-private
```

Run with the private config:

```sh
WAN_TEST_CONFIG=~/.config/wan-test-private/config.json wan-test
```

Update later:

```sh
sudo git -C /opt/wan-test pull --ff-only
git -C ~/.config/wan-test-private pull --ff-only
```

This keeps the test runner public and reusable while the machine-specific targets stay private.

## One-Command Personal Wrapper

If you always use the same private config path, create a wrapper on each machine:

```sh
sudo tee /usr/local/bin/wan-test-private >/dev/null <<'EOF'
#!/bin/sh
WAN_TEST_CONFIG="$HOME/.config/wan-test-private/config.json" exec /usr/local/bin/wan-test "$@"
EOF
sudo chmod +x /usr/local/bin/wan-test-private
```

Then run:

```sh
wan-test-private eth0
```

## Default Config Locations

If `WAN_TEST_CONFIG` and `--config` are not provided, the script chooses a default config path based on where it is installed. For example:

- `/opt/homebrew/etc/wan-test/config.json` for Homebrew-style installs
- `/usr/local/etc/wan-test/config.json` for `/usr/local/bin`
- `/etc/wan-test/config.json` for system locations on Linux/OpenWRT
- `./config.json` when run from a normal checkout

If the default config file is missing, the script creates a bare config that you can edit.

## Notes

- Interface binding is best on Linux/OpenWRT where `ip`, `ping -I`, `curl --interface`, and `dig -b` are available.
- macOS support uses the available platform tools and route information.
- iSH has limited raw socket and interface binding support, so some checks use best-effort fallbacks.
- WebSocket proxy facades can return `HTTP 400` to a plain HTTPS request and still be reachable. The WebSocket upgrade check is the real protocol check for those entries.
