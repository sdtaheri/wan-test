#!/bin/sh
# Universal Network Connectivity Test Script v2
# Tests all interfaces with default routes
# Supports: Plain DNS, DoH, DoT, DoQ, DNSCrypt via dnslookup
# Works on: OpenWRT, Raspberry Pi, macOS, Linux

# ─── Usage ────────────────────────────────────────────────
# ./wan-test.sh              # Auto-detect interfaces with default routes
# ./wan-test.sh --config config.json
# WAN_TEST_CONFIG=/etc/wan-test/config.json ./wan-test.sh
# ./wan-test.sh eth0         # Test specific interface
# ./wan-test.sh eth0 wlan0   # Test multiple specific interfaces

# ─── Configuration ────────────────────────────────────────

case "$0" in
    */*) SCRIPT_PATH=$0 ;;
    *)   SCRIPT_PATH=$(command -v "$0" 2>/dev/null || echo "$0") ;;
esac
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd)
CONFIG_FILE="${WAN_TEST_CONFIG:-}"
CONFIG_FILE_EXPLICIT=0
CONFIG_LOADED=0
CONFIG_CREATED=0
[ -n "$CONFIG_FILE" ] && CONFIG_FILE_EXPLICIT=1
TEST_FILTERS=""

DNSLOOKUP_VERSION=""
PING_TARGETS=""
DNS_LOOKUP_DOMAINS=""
PLAIN_DNS=""
DOH_DNS=""
DOT_DNS=""
DOQ_DNS=""
DNSCRYPT_DNS=""
HTTP_URLS=""
CDN_USER_AGENT=""
CDN_URLS=""
TCP_TARGETS=""
PROXY_FACADE_USER_AGENT=""
PROXY_FACADES=""

# ─── Colors ───────────────────────────────────────────────

if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    DIM='\033[2m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' DIM='' BOLD='' NC=''
fi

# ─── OS & Architecture Detection ─────────────────────────

detect_os() {
    if [ "$(uname)" = "Darwin" ]; then
        OS="macos"
    elif [ -f /etc/openwrt_release ]; then
        OS="openwrt"
    elif [ -f /etc/alpine-release ] && ! [ -d /proc/net ]; then
        # iSH on iPad: Alpine without /proc/net
        OS="ish"
    else
        OS="linux"
    fi
}

detect_arch() {
    local machine=$(uname -m)
    case "$machine" in
        x86_64|amd64)       ARCH="amd64" ;;
        aarch64|arm64)      ARCH="arm64" ;;
        armv7*|armhf)       ARCH="arm" ;;
        i686|i386|i486)     ARCH="386" ;;
        mips)               ARCH="mips" ;;
        mipsel|mipsle)      ARCH="mipsle" ;;
        *)                  ARCH="" ;;
    esac

    case "$(uname -s)" in
        Darwin)  PLATFORM="darwin" ;;
        Linux)   PLATFORM="linux" ;;
        FreeBSD) PLATFORM="freebsd" ;;
        *)       PLATFORM="" ;;
    esac
}

# ─── JSON Config Loading ──────────────────────────────────

print_usage() {
    printf "Usage: $0 [--config config.json] [--tests list] [test ...] [interface ...]\n"
    printf "  No arguments:          auto-detect interfaces with default routes\n"
    printf "  interface:             test specific interface(s)\n"
    printf "  -c, --config <file>:   read test targets from JSON config\n"
    printf "  -t, --tests <list>:    comma-separated tests to run\n"
    printf "\nTests:\n"
    printf "  all, ping, dns, http, cdn, tcp, proxy, encrypted, doh, dot, doq, dnscrypt\n"
    printf "\nExamples:\n"
    printf "  $0\n"
    printf "  $0 --config ./config.json\n"
    printf "  $0 tcp proxy dnscrypt\n"
    printf "  $0 --tests tcp,proxy,dnscrypt eth0\n"
    printf "  $0 eth0\n"
    printf "  WAN_TEST_CONFIG=/etc/wan-test.json $0 eth0 wlan0\n"
}

default_config_file() {
    case "$SCRIPT_DIR" in
        /opt/homebrew/bin|/opt/homebrew/sbin)
            printf "/opt/homebrew/etc/wan-test/config.json"
            ;;
        /usr/local/bin|/usr/local/sbin)
            printf "/usr/local/etc/wan-test/config.json"
            ;;
        /bin|/sbin|/usr/bin|/usr/sbin)
            if [ "$OS" = "macos" ]; then
                printf "/usr/local/etc/wan-test/config.json"
            else
                printf "/etc/wan-test/config.json"
            fi
            ;;
        /opt/bin|/opt/sbin)
            printf "/opt/etc/wan-test/config.json"
            ;;
        *)
            printf "%s/config.json" "$SCRIPT_DIR"
            ;;
    esac
}

write_bare_config() {
    cat > "$1" <<'EOF'
{
  "dnslookupVersion": "",
  "pingTargets": [],
  "dns": {
    "lookupDomains": [],
    "plain": [],
    "doh": [],
    "dot": [],
    "doq": [],
    "dnscrypt": []
  },
  "http": {
    "urls": []
  },
  "cdn": {
    "userAgent": "",
    "urls": []
  },
  "tcpTargets": [],
  "proxyFacadeUserAgent": "",
  "proxyFacades": []
}
EOF
}

create_bare_config() {
    local config_dir tmp_file
    config_dir=$(dirname "$CONFIG_FILE")

    if mkdir -p "$config_dir" 2>/dev/null && [ -w "$config_dir" ]; then
        write_bare_config "$CONFIG_FILE" || return 1
    else
        tmp_file="/tmp/wan-test-config.$$"
        write_bare_config "$tmp_file" || return 1
        run_privileged mkdir -p "$config_dir" 2>/dev/null || {
            rm -f "$tmp_file"
            return 1
        }
        run_privileged cp "$tmp_file" "$CONFIG_FILE" 2>/dev/null || {
            rm -f "$tmp_file"
            return 1
        }
        rm -f "$tmp_file"
    fi

    CONFIG_CREATED=1
    printf "${YELLOW}Created bare config file:${NC} $CONFIG_FILE\n"
    printf "${YELLOW}Edit it to add ping, DNS, HTTP, CDN, or proxy facade targets.${NC}\n\n"
}

ensure_config_file() {
    if [ -z "$CONFIG_FILE" ]; then
        CONFIG_FILE=$(default_config_file)
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        create_bare_config || {
            printf "${RED}ERROR: Could not create config file: $CONFIG_FILE${NC}\n"
            exit 1
        }
    fi
}

normalize_test_name() {
    case "$1" in
        all) echo "all" ;;
        ping|icmp|reachability) echo "ping" ;;
        dns|plain|plain-dns|plain_dns) echo "dns" ;;
        http|http-connectivity) echo "http" ;;
        cdn) echo "cdn" ;;
        tcp|socket|sockets|direct) echo "tcp" ;;
        proxy|proxies|facade|facades|ws|websocket) echo "proxy" ;;
        encrypted|encrypted-dns|encrypted_dns|edns) echo "encrypted" ;;
        doh|doH) echo "doh" ;;
        dot|doT) echo "dot" ;;
        doq|doQ) echo "doq" ;;
        dnscrypt|dns-crypt|dns_crypt) echo "dnscrypt" ;;
        *) return 1 ;;
    esac
}

add_test_filter() {
    local raw=$1
    local normalized

    normalized=$(normalize_test_name "$raw") || return 1
    if [ "$normalized" = "all" ]; then
        TEST_FILTERS="all"
        return 0
    fi
    if [ "$TEST_FILTERS" = "all" ]; then
        return 0
    fi
    case " $TEST_FILTERS " in
        *" $normalized "*) ;;
        *) TEST_FILTERS="${TEST_FILTERS:+$TEST_FILTERS }$normalized" ;;
    esac
    return 0
}

add_test_filters() {
    local list=$1
    local item
    list=$(printf "%s" "$list" | tr ',' ' ')
    for item in $list; do
        add_test_filter "$item" || {
            printf "${RED}ERROR: Unknown test selector: $item${NC}\n"
            exit 1
        }
    done
}

test_enabled() {
    local test_name=$1

    if [ -z "$TEST_FILTERS" ] || [ "$TEST_FILTERS" = "all" ]; then
        return 0
    fi

    case " $TEST_FILTERS " in
        *" $test_name "*) return 0 ;;
    esac

    case "$test_name" in
        doh|dot|doq|dnscrypt)
            case " $TEST_FILTERS " in
                *" encrypted "*) return 0 ;;
            esac
            ;;
    esac

    return 1
}

selected_tests_label() {
    if [ -z "$TEST_FILTERS" ] || [ "$TEST_FILTERS" = "all" ]; then
        printf "all"
    else
        printf "%s" "$TEST_FILTERS"
    fi
}

check_jq_dependency() {
    if command -v jq > /dev/null 2>&1; then
        HAS_JQ=1
        return 0
    fi

    printf "${BLUE}Checking dependencies...${NC}\n"
    printf "  jq:        ${YELLOW}not found${NC} — installing...\n"
    install_jq
    if command -v jq > /dev/null 2>&1; then
        HAS_JQ=1
        printf "  jq:        ${GREEN}installed${NC}\n\n"
        return 0
    fi

    HAS_JQ=0
    printf "  jq:        ${RED}unavailable${NC}\n\n"
    printf "${RED}ERROR: jq is required to read config: $CONFIG_FILE${NC}\n"
    exit 1
}

json_has_array() {
    jq -e "$1? | type == \"array\"" "$CONFIG_FILE" > /dev/null 2>&1
}

json_has_string() {
    jq -e "$1? | type == \"string\"" "$CONFIG_FILE" > /dev/null 2>&1
}

json_string() {
    jq -r "$1" "$CONFIG_FILE"
}

json_string_array() {
    jq -r "$1[]?" "$CONFIG_FILE" | tr '\n' ' '
}

json_cdn_entries() {
    jq -r '
        .cdn.urls[]? |
        if type == "string" then
            .
        else
            "\(.label)|\(.url)"
        end
    ' "$CONFIG_FILE" | tr '\n' ' '
}

json_proxy_facade_entries() {
    jq -r '
        .proxyFacades[]? |
        if type == "string" then
            .
        else
            "\(.label)|\(.url)|\(.mode // "ws")"
        end
    ' "$CONFIG_FILE" | tr '\n' ' '
}

json_tcp_target_entries() {
    jq -r '
        .tcpTargets[]? |
        if type == "string" then
            .
        else
            "\(.label)|\(.host)|\(.port)"
        end
    ' "$CONFIG_FILE" | tr '\n' ' '
}

json_dnscrypt_entries() {
    jq -r '
        .dns.dnscrypt[]? |
        if type == "string" then
            .
        else
            "\(.label)|\(.server)"
        end
    ' "$CONFIG_FILE" | tr '\n' ' '
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return 0
    fi

    if ! command -v jq > /dev/null 2>&1; then
        printf "${BLUE}Config file found. jq is required to read it.${NC}\n"
        if ! install_jq; then
            printf "${RED}ERROR: Could not install jq for config file: $CONFIG_FILE${NC}\n"
            printf "Install jq or pass --config with a readable JSON config file.\n"
            exit 1
        fi
    fi

    if ! jq empty "$CONFIG_FILE" > /dev/null 2>&1; then
        printf "${RED}ERROR: Invalid JSON config: $CONFIG_FILE${NC}\n"
        exit 1
    fi

    json_has_string '.dnslookupVersion' && DNSLOOKUP_VERSION=$(json_string '.dnslookupVersion')
    json_has_array '.pingTargets' && PING_TARGETS=$(json_string_array '.pingTargets')
    json_has_array '.dns.lookupDomains' && DNS_LOOKUP_DOMAINS=$(json_string_array '.dns.lookupDomains')
    json_has_array '.dns.plain' && PLAIN_DNS=$(json_string_array '.dns.plain')
    json_has_array '.dns.doh' && DOH_DNS=$(json_string_array '.dns.doh')
    json_has_array '.dns.dot' && DOT_DNS=$(json_string_array '.dns.dot')
    json_has_array '.dns.doq' && DOQ_DNS=$(json_string_array '.dns.doq')
    json_has_array '.dns.dnscrypt' && DNSCRYPT_DNS=$(json_dnscrypt_entries)
    json_has_array '.http.urls' && HTTP_URLS=$(json_string_array '.http.urls')
    json_has_string '.cdn.userAgent' && CDN_USER_AGENT=$(json_string '.cdn.userAgent')
    json_has_array '.cdn.urls' && CDN_URLS=$(json_cdn_entries)
    json_has_array '.tcpTargets' && TCP_TARGETS=$(json_tcp_target_entries)
    json_has_string '.proxyFacadeUserAgent' && PROXY_FACADE_USER_AGENT=$(json_string '.proxyFacadeUserAgent')
    json_has_array '.proxyFacades' && PROXY_FACADES=$(json_proxy_facade_entries)

    CONFIG_LOADED=1
}

# ─── Privilege Helper ─────────────────────────────────────

# Run command with sudo if needed (skip if already root)
run_privileged() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo > /dev/null 2>&1; then
        sudo "$@"
    else
        "$@"
    fi
}

install_jq() {
    if [ "$OS" = "macos" ] && command -v brew > /dev/null 2>&1; then
        printf "  Trying Homebrew for jq... "
        brew install jq > /dev/null 2>&1 && { printf "${GREEN}OK${NC}\n"; return 0; }
        printf "${YELLOW}failed${NC}\n"
    elif [ "$OS" = "openwrt" ] && command -v opkg > /dev/null 2>&1; then
        printf "  Trying opkg for jq... "
        opkg update > /dev/null 2>&1
        opkg install jq > /dev/null 2>&1 && { printf "${GREEN}OK${NC}\n"; return 0; }
        printf "${YELLOW}failed${NC}\n"
    elif command -v apt-get > /dev/null 2>&1; then
        printf "  Trying apt for jq... "
        run_privileged apt-get install -y jq > /dev/null 2>&1 && { printf "${GREEN}OK${NC}\n"; return 0; }
        printf "${YELLOW}failed${NC}\n"
    elif command -v yum > /dev/null 2>&1; then
        printf "  Trying yum for jq... "
        run_privileged yum install -y jq > /dev/null 2>&1 && { printf "${GREEN}OK${NC}\n"; return 0; }
        printf "${YELLOW}failed${NC}\n"
    elif command -v apk > /dev/null 2>&1; then
        printf "  Trying apk for jq... "
        run_privileged apk add jq > /dev/null 2>&1 && { printf "${GREEN}OK${NC}\n"; return 0; }
        printf "${YELLOW}failed${NC}\n"
    elif command -v pacman > /dev/null 2>&1; then
        printf "  Trying pacman for jq... "
        run_privileged pacman -S --noconfirm jq > /dev/null 2>&1 && { printf "${GREEN}OK${NC}\n"; return 0; }
        printf "${YELLOW}failed${NC}\n"
    fi

    return 1
}

# ─── dnslookup Management ────────────────────────────────

HAS_JQ=0
DNSLOOKUP_BIN=""

find_dnslookup() {
    # Check PATH first
    if command -v dnslookup > /dev/null 2>&1; then
        DNSLOOKUP_BIN=$(command -v dnslookup)
        return 0
    fi
    # Check common locations
    for path in /usr/local/bin/dnslookup /usr/bin/dnslookup /tmp/dnslookup ./dnslookup; do
        if [ -x "$path" ]; then
            DNSLOOKUP_BIN="$path"
            return 0
        fi
    done
    return 1
}

install_dnslookup() {
    printf "${BLUE}dnslookup not found. Attempting auto-install...${NC}\n"

    if [ -z "$PLATFORM" ] || [ -z "$ARCH" ]; then
        printf "  ${RED}Cannot determine platform/architecture for download${NC}\n"
        return 1
    fi

    # Try Homebrew on macOS
    if [ "$PLATFORM" = "darwin" ] && command -v brew > /dev/null 2>&1; then
        printf "  Trying Homebrew... "
        if brew install ameshkov/tap/dnslookup > /dev/null 2>&1; then
            printf "${GREEN}OK${NC}\n"
            find_dnslookup
            return $?
        fi
        printf "${YELLOW}failed${NC}\n"
    fi

    # Try Snap on Linux (not OpenWRT)
    if [ "$OS" = "linux" ] && [ "$OS" != "openwrt" ] && command -v snap > /dev/null 2>&1; then
        printf "  Trying Snap... "
        if run_privileged snap install dnslookup > /dev/null 2>&1; then
            printf "${GREEN}OK${NC}\n"
            find_dnslookup
            return $?
        fi
        printf "${YELLOW}failed${NC}\n"
    fi

    # Download binary from GitHub releases
    local url="https://github.com/ameshkov/dnslookup/releases/download/v${DNSLOOKUP_VERSION}/dnslookup-${PLATFORM}-${ARCH}-v${DNSLOOKUP_VERSION}.tar.gz"

    # Choose install location
    local install_path="/usr/local/bin"
    if [ "$OS" = "openwrt" ]; then
        install_path="/tmp"
    fi

    printf "  Downloading ${DIM}dnslookup-${PLATFORM}-${ARCH}-v${DNSLOOKUP_VERSION}${NC}... "

    local tmp_dir=$(mktemp -d 2>/dev/null || echo "/tmp/dnslookup_install_$$")
    mkdir -p "$tmp_dir"

    # Download
    local dl_ok=0
    if command -v curl > /dev/null 2>&1; then
        curl -sL "$url" -o "$tmp_dir/dnslookup.tar.gz" 2>/dev/null && dl_ok=1
    elif command -v wget > /dev/null 2>&1; then
        wget -q "$url" -O "$tmp_dir/dnslookup.tar.gz" 2>/dev/null && dl_ok=1
    else
        printf "${RED}no curl or wget${NC}\n"
        rm -rf "$tmp_dir"
        return 1
    fi

    if [ "$dl_ok" -eq 0 ]; then
        printf "${RED}download failed${NC}\n"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Extract
    tar -xzf "$tmp_dir/dnslookup.tar.gz" -C "$tmp_dir" 2>/dev/null

    # Find the binary (might be in a subdirectory)
    local bin_path=$(find "$tmp_dir" -name "dnslookup" -type f 2>/dev/null | head -1)

    if [ -z "$bin_path" ]; then
        printf "${RED}binary not found in archive${NC}\n"
        rm -rf "$tmp_dir"
        return 1
    fi

    chmod +x "$bin_path"

    # Install to target path
    if [ -w "$install_path" ]; then
        mv "$bin_path" "$install_path/dnslookup"
    elif command -v sudo > /dev/null 2>&1; then
        sudo mv "$bin_path" "$install_path/dnslookup" 2>/dev/null || {
            install_path="/tmp"
            mv "$bin_path" "$install_path/dnslookup"
        }
    else
        install_path="/tmp"
        mv "$bin_path" "$install_path/dnslookup"
    fi

    rm -rf "$tmp_dir"

    DNSLOOKUP_BIN="$install_path/dnslookup"
    if [ -x "$DNSLOOKUP_BIN" ]; then
        printf "${GREEN}OK${NC} → ${DIM}$install_path/dnslookup${NC}\n"
        return 0
    else
        printf "${RED}install failed${NC}\n"
        DNSLOOKUP_BIN=""
        return 1
    fi
}

# ─── DNS Tool Installation (dig/nslookup) ────────────────

install_dns_tools() {
    if [ "$OS" = "macos" ]; then
        # dig and nslookup ship with macOS
        return 0
    elif [ "$OS" = "openwrt" ]; then
        printf "  Trying opkg... "
        opkg update > /dev/null 2>&1
        opkg install bind-dig > /dev/null 2>&1 && { printf "${GREEN}OK${NC}\n"; return 0; }
        # Try knot-dig as alternative (smaller)
        opkg install knot-dig > /dev/null 2>&1 && { printf "${GREEN}OK (kdig)${NC}\n"; return 0; }
        printf "${YELLOW}failed${NC}\n"
    elif command -v apt-get > /dev/null 2>&1; then
        printf "  Trying apt... "
        run_privileged apt-get install -y dnsutils > /dev/null 2>&1 && { printf "${GREEN}OK${NC}\n"; return 0; }
        run_privileged apt-get install -y bind9-dnsutils > /dev/null 2>&1 && { printf "${GREEN}OK${NC}\n"; return 0; }
        printf "${YELLOW}failed${NC}\n"
    elif command -v yum > /dev/null 2>&1; then
        printf "  Trying yum... "
        run_privileged yum install -y bind-utils > /dev/null 2>&1 && { printf "${GREEN}OK${NC}\n"; return 0; }
        printf "${YELLOW}failed${NC}\n"
    elif command -v apk > /dev/null 2>&1; then
        printf "  Trying apk... "
        run_privileged apk add bind-tools > /dev/null 2>&1 && { printf "${GREEN}OK${NC}\n"; return 0; }
        printf "${YELLOW}failed${NC}\n"
    elif command -v pacman > /dev/null 2>&1; then
        printf "  Trying pacman... "
        run_privileged pacman -S --noconfirm bind > /dev/null 2>&1 && { printf "${GREEN}OK${NC}\n"; return 0; }
        printf "${YELLOW}failed${NC}\n"
    fi
    return 1
}

check_dependencies() {
    printf "${BLUE}Checking dependencies...${NC}\n"

    HAS_DIG=0
    HAS_NSLOOKUP=0
    HAS_JQ=0
    command -v jq > /dev/null 2>&1 && HAS_JQ=1
    command -v dig > /dev/null 2>&1 && HAS_DIG=1
    command -v nslookup > /dev/null 2>&1 && HAS_NSLOOKUP=1

    # jq
    printf "  jq:        "
    if [ $HAS_JQ -eq 1 ]; then
        printf "${GREEN}found${NC}\n"
    else
        printf "${YELLOW}not found${NC} — installing...\n"
        install_jq
        command -v jq > /dev/null 2>&1 && HAS_JQ=1
        if [ $HAS_JQ -eq 1 ]; then
            printf "  jq:        ${GREEN}installed${NC}\n"
        else
            printf "  jq:        ${RED}unavailable${NC}\n"
        fi
    fi

    # dnslookup
    printf "  dnslookup: "
    if [ -n "$DNSLOOKUP_BIN" ]; then
        printf "${GREEN}found${NC} ${DIM}($DNSLOOKUP_BIN)${NC}\n"
    elif [ -z "$DOH_DNS$DOT_DNS$DOQ_DNS$DNSCRYPT_DNS" ]; then
        printf "${DIM}skipped (no encrypted DNS configured)${NC}\n"
    elif [ -z "$DNSLOOKUP_VERSION" ]; then
        printf "${RED}unavailable${NC} ${DIM}(set dnslookupVersion in config to enable auto-install)${NC}\n"
    else
        printf "${YELLOW}not found${NC} — installing...\n"
        install_dnslookup
        find_dnslookup
        if [ -n "$DNSLOOKUP_BIN" ]; then
            printf "  dnslookup: ${GREEN}installed${NC} ${DIM}($DNSLOOKUP_BIN)${NC}\n"
        else
            printf "  dnslookup: ${RED}unavailable${NC} ${DIM}(encrypted DNS tests will be skipped)${NC}\n"
        fi
    fi

    # dig (skip on iSH - it hangs due to socket issues)
    printf "  dig:       "
    if [ "$OS" = "ish" ]; then
        printf "${DIM}skipped (not supported on iSH)${NC}\n"
    elif [ $HAS_DIG -eq 1 ]; then
        printf "${GREEN}found${NC}\n"
    else
        printf "${YELLOW}not found${NC} — installing...\n"
        install_dns_tools
        command -v dig > /dev/null 2>&1 && HAS_DIG=1
        if [ $HAS_DIG -eq 1 ]; then
            printf "  dig:       ${GREEN}installed${NC}\n"
        else
            printf "  dig:       ${RED}unavailable${NC}\n"
        fi
    fi

    # nslookup
    printf "  nslookup:  "
    command -v nslookup > /dev/null 2>&1 && HAS_NSLOOKUP=1
    if [ $HAS_NSLOOKUP -eq 1 ]; then
        printf "${GREEN}found${NC}\n"
    else
        printf "${RED}unavailable${NC}\n"
    fi

    # Verify we have at least one DNS tool
    if [ $HAS_DIG -eq 0 ] && [ $HAS_NSLOOKUP -eq 0 ] && [ -z "$DNSLOOKUP_BIN" ]; then
        printf "\n  ${RED}No DNS tools available! Plain DNS tests will fail.${NC}\n"
    fi

    printf "\n"
}

# ─── Display Helpers ─────────────────────────────────────

# Shorten long server addresses for display (e.g., sdns:// stamps)
short_server() {
    if [ ${#1} -gt 48 ]; then
        printf "%.45s..." "$1"
    else
        printf "%s" "$1"
    fi
}

# ─── DNS Hijack Detection ────────────────────────────────
# Returns 0 (true) if IP is in a private/bogus range (DNS hijacking indicator)

is_private_ip() {
    case "$1" in
        10.*|127.*|192.168.*|0.0.0.0) return 0 ;;
        172.*)
            local second
            second=$(echo "$1" | cut -d. -f2)
            [ "$second" -ge 16 ] 2>/dev/null && [ "$second" -le 31 ] 2>/dev/null && return 0
            ;;
    esac
    return 1
}

# ─── JSON Parsing Helpers ────────────────────────────────
# Minimal JSON extraction without jq dependency

# Extract Rcode from dnslookup JSON (handles both compact and pretty-printed)
json_rcode() {
    echo "$1" | grep -o '"Rcode": *[0-9]*' | head -1 | grep -o '[0-9]*$'
}

# Extract first A record IP
json_ips() {
    echo "$1" | grep -o '"A": *"[^"]*"' | head -1 | sed 's/"A": *"//;s/"//'
}

# Extract elapsed time in ms (dnslookup reports nanoseconds)
json_elapsed_ms() {
    local ns
    ns=$(echo "$1" | grep -o '"elapsed": *[0-9]*' | head -1 | grep -o '[0-9]*$')
    if [ -n "$ns" ] && [ "$ns" -gt 0 ] 2>/dev/null; then
        echo $((ns / 1000000))
    fi
}

# ─── Interface Detection ─────────────────────────────────

detect_interfaces() {
    local ifaces=""

    if [ "$OS" = "macos" ]; then
        # macOS: try netstat for all default route interfaces
        ifaces=$(netstat -rn -f inet 2>/dev/null | awk '/^default/ {print $NF}' | grep -v "^$" | sort -u | tr '\n' ' ')
        # Fallback: single interface from route
        if [ -z "$ifaces" ]; then
            ifaces=$(route -n get default 2>/dev/null | grep "interface:" | awk '{print $2}')
        fi
    elif command -v ip > /dev/null 2>&1; then
        ifaces=$(ip route 2>/dev/null | awk '/^default/ {for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1)}}}' | sort -u | tr '\n' ' ')
    else
        ifaces=$(route -n 2>/dev/null | awk '/^0.0.0.0/ {print $8}' | grep -v "^lo$" | sort -u | tr '\n' ' ')
    fi

    echo "$ifaces" | tr ' ' '\n' | grep -v "^$" | sort -u | tr '\n' ' '
}

# ─── Display Helpers ─────────────────────────────────────

print_header() {
    local iface_count=$1
    local descriptor=$2
    printf "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"
    printf "${BLUE}  Network Connectivity Report${NC}\n"
    printf "${BLUE}  $(date)${NC}\n"
    printf "${BLUE}  System: $OS ($PLATFORM/$ARCH) | $descriptor: $iface_count${NC}\n"
    # Tool summary line
    local tools=""
    if [ $HAS_JQ -eq 1 ]; then tools="jq"; fi
    if [ $HAS_DIG -eq 1 ]; then tools="${tools:+$tools, }dig"; fi
    if [ $HAS_NSLOOKUP -eq 1 ]; then tools="${tools:+$tools, }nslookup"; fi
    if [ -n "$DNSLOOKUP_BIN" ]; then tools="${tools:+$tools, }dnslookup"; fi
    printf "${BLUE}  Tools: ${GREEN}$tools${NC}\n"
    if [ "$CONFIG_LOADED" -eq 1 ]; then
        printf "${BLUE}  Config: ${GREEN}$CONFIG_FILE${NC}\n"
        if [ "$CONFIG_CREATED" -eq 1 ]; then
            printf "${BLUE}  Config status: ${YELLOW}created empty starter${NC}\n"
        fi
    else
        printf "${BLUE}  Config: ${RED}not loaded${NC}\n"
    fi
    printf "${BLUE}  Selected tests: ${GREEN}$(selected_tests_label)${NC}\n"
    printf "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"
    printf "\n"
}

print_section() {
    printf "${YELLOW}━━━ $1 ━━━${NC}\n"
}

test_result() {
    if [ $1 -eq 0 ]; then
        printf "${GREEN}✓ PASS${NC}: $2\n"
        return 0
    else
        printf "${RED}✗ FAIL${NC}: $2\n"
        return 1
    fi
}

# ─── Interface Info ───────────────────────────────────────

get_iface_ip() {
    local iface=$1
    if command -v ip > /dev/null 2>&1; then
        ip -4 addr show dev "$iface" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1
    elif command -v ifconfig > /dev/null 2>&1; then
        if [ "$OS" = "macos" ]; then
            ifconfig "$iface" 2>/dev/null | grep "inet " | awk '{print $2}' | head -1
        else
            ifconfig "$iface" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d: -f2 | head -1
        fi
    fi
}

get_iface_cidr() {
    local iface=$1
    if command -v ip > /dev/null 2>&1; then
        ip -4 addr show dev "$iface" 2>/dev/null | grep inet | awk '{print $2}' | head -1
    else
        get_iface_ip "$iface"
    fi
}

get_iface_gateway() {
    local iface=$1
    if command -v ip > /dev/null 2>&1; then
        local gw=$(ip route show dev "$iface" 2>/dev/null | grep default | awk '{print $3}')
        if [ -z "$gw" ]; then
            gw=$(ip route 2>/dev/null | grep "default.*dev $iface" | awk '{print $3}')
        fi
        echo "$gw"
    elif [ "$OS" = "macos" ]; then
        route -n get default 2>/dev/null | grep "gateway:" | awk '{print $2}'
    else
        route -n 2>/dev/null | grep "^0.0.0.0.*$iface" | awk '{print $2}' | head -1
    fi
}

get_interface_info() {
    local iface=$1

    print_section "Interface: $iface"

    # iSH: virtual iOS interface, no detailed info available
    if [ "$OS" = "ish" ]; then
        printf "  Type:       ${CYAN}iOS Network Stack${NC}\n"
        printf "  Status:     ${GREEN}ACTIVE${NC} (via iSH)\n"
        printf "\n"
        return 0
    fi

    local ip=$(get_iface_cidr "$iface")
    if [ -n "$ip" ]; then
        printf "  IP Address: ${GREEN}$ip${NC}\n"
    else
        printf "  IP Address: ${RED}Not configured${NC}\n\n"
        return 1
    fi

    local gateway=$(get_iface_gateway "$iface")
    if [ -n "$gateway" ]; then
        printf "  Gateway:    $gateway\n"
    else
        printf "  Gateway:    ${YELLOW}Not found${NC}\n"
    fi

    # Metric
    if command -v ip > /dev/null 2>&1; then
        local metric=$(ip route 2>/dev/null | grep "default.*dev $iface" | grep -o "metric [0-9]*" | awk '{print $2}')
        if [ -n "$metric" ]; then
            printf "  Metric:     $metric\n"
        fi
    fi

    # Link status
    local status=""
    if command -v ip > /dev/null 2>&1; then
        status=$(ip link show dev "$iface" 2>/dev/null | grep -o "state [A-Z]*" | awk '{print $2}')
    elif command -v ifconfig > /dev/null 2>&1; then
        if ifconfig "$iface" 2>/dev/null | grep -q "status: active"; then
            status="ACTIVE"
        elif ifconfig "$iface" 2>/dev/null | grep -qE "UP.*RUNNING"; then
            status="UP"
        else
            status="DOWN"
        fi
    fi
    printf "  Status:     $status\n"
    printf "\n"
    return 0
}

# ─── Test Functions ───────────────────────────────────────

test_ping() {
    local iface=$1
    local target=$2

    if [ "$OS" = "ish" ]; then
        # iSH: ping requires raw sockets which aren't supported
        # Use TCP connection test instead (port 53 for DNS servers)
        if command -v nc > /dev/null 2>&1; then
            nc -z -w 2 "$target" 53 > /dev/null 2>&1
        elif command -v curl > /dev/null 2>&1; then
            curl --connect-timeout 2 -s "http://$target" > /dev/null 2>&1
            # curl returns 0 on connect even if HTTP fails, which is fine for reachability
            [ $? -le 7 ]  # 0-7 are connection-related codes
        else
            return 2  # skip
        fi
    elif [ "$OS" = "macos" ]; then
        ping -b "$iface" -c 3 -t 2 "$target" > /dev/null 2>&1
    else
        ping -I "$iface" -c 3 -W 2 "$target" > /dev/null 2>&1
    fi
    return $?
}

# DNS test for encrypted protocols (DoH/DoT/DoQ) — requires dnslookup
test_dns() {
    local domain=$1
    local server=$2
    local protocol_label=$3
    local display_label=${4:-$protocol_label}

    if [ -n "$DNSLOOKUP_BIN" ]; then
        test_dns_dnslookup "$domain" "$server" "$display_label"
    else
        printf "${YELLOW}⊘ SKIP${NC}: $display_label ${DIM}$server${NC} → $domain ${YELLOW}(needs dnslookup)${NC}\n"
        return 2
    fi
    return $?
}

# Plain DNS test with interface binding
# Priority: dig -b (binds to source IP) > dnslookup (no bind, but has latency) > nslookup (no bind)
# On iSH: skip interface binding entirely
test_dns_plain() {
    local iface=$1
    local domain=$2
    local server=$3

    # iSH: no interface binding possible, use dnslookup or nslookup directly
    if [ "$OS" = "ish" ]; then
        if [ -n "$DNSLOOKUP_BIN" ]; then
            test_dns_dnslookup "$domain" "$server" "DNS"
            return $?
        fi
        test_dns_nslookup "$domain" "$server"
        return $?
    fi

    local src_ip
    src_ip=$(get_iface_ip "$iface")

    # Prefer dig — it can bind to a source IP
    if command -v dig > /dev/null 2>&1 && [ -n "$src_ip" ]; then
        test_dns_dig "$iface" "$domain" "$server" "$src_ip"
        return $?
    fi

    # Fall back to dnslookup (no interface binding, but gives latency)
    if [ -n "$DNSLOOKUP_BIN" ]; then
        test_dns_dnslookup "$domain" "$server" "DNS"
        return $?
    fi

    # Last resort: nslookup (no binding, no latency)
    test_dns_nslookup "$domain" "$server"
    return $?
}

test_dns_dig() {
    local iface=$1
    local domain=$2
    local server=$3
    local src_ip=$4
    local result exit_code

    result=$(dig +short +time=5 +tries=1 -b "$src_ip" "@$server" "$domain" A 2>&1)
    exit_code=$?

    # dig +short outputs IPs directly, one per line — take first only
    local ips
    ips=$(echo "$result" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)

    if [ $exit_code -eq 0 ] && [ -n "$ips" ]; then
        if is_private_ip "$ips"; then
            printf "${RED}✗ HIJACK${NC}: DNS ${DIM}$server${NC} → $domain → ${RED}$ips${NC}\n"
            return 1
        fi
        printf "${GREEN}✓ PASS${NC}: DNS ${DIM}$server${NC} → $domain → ${CYAN}$ips${NC}\n"
        return 0
    elif [ $exit_code -eq 0 ]; then
        printf "${GREEN}✓ PASS${NC}: DNS ${DIM}$server${NC} → $domain ${YELLOW}(no A records)${NC}\n"
        return 0
    else
        printf "${RED}✗ FAIL${NC}: DNS ${DIM}$server${NC} → $domain ${RED}(lookup failed)${NC}\n"
        return 1
    fi
}

test_dns_dnslookup() {
    local domain=$1
    local server=$2
    local label=$3
    local json exit_code

    json=$(TIMEOUT=5 JSON=1 "$DNSLOOKUP_BIN" "$domain" "$server" 2>/dev/null)
    exit_code=$?

    local display_server
    display_server=$(short_server "$server")

    if [ $exit_code -ne 0 ] || [ -z "$json" ]; then
        printf "${RED}✗ FAIL${NC}: $label ${DIM}$display_server${NC} → $domain ${RED}(query failed)${NC}\n"
        return 1
    fi

    local rcode=$(json_rcode "$json")
    local ips=$(json_ips "$json")
    local elapsed=$(json_elapsed_ms "$json")

    local time_str=""
    if [ -n "$elapsed" ]; then
        time_str=" ${DIM}(${elapsed}ms)${NC}"
    fi

    if [ "$rcode" = "0" ] && [ -n "$ips" ]; then
        if is_private_ip "$ips"; then
            printf "${RED}✗ HIJACK${NC}: $label ${DIM}$display_server${NC} → $domain → ${RED}$ips${NC}$time_str\n"
            return 1
        fi
        printf "${GREEN}✓ PASS${NC}: $label ${DIM}$display_server${NC} → $domain → ${CYAN}$ips${NC}$time_str\n"
        return 0
    elif [ "$rcode" = "0" ]; then
        printf "${GREEN}✓ PASS${NC}: $label ${DIM}$display_server${NC} → $domain ${YELLOW}(no A records)${NC}$time_str\n"
        return 0
    else
        printf "${RED}✗ FAIL${NC}: $label ${DIM}$display_server${NC} → $domain ${RED}(rcode: $rcode)${NC}$time_str\n"
        return 1
    fi
}

test_dns_nslookup() {
    local domain=$1
    local server=$2

    if ! command -v nslookup > /dev/null 2>&1; then
        printf "${RED}✗ FAIL${NC}: DNS ${DIM}$server${NC} → $domain ${RED}(no DNS tool available)${NC}\n"
        return 1
    fi

    local result exit_code
    result=$(nslookup "$domain" "$server" 2>&1)
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
        local resolved=""
        resolved=$(echo "$result" | awk '/^Address [0-9]+:/ {print $3}' | head -1)
        if [ -z "$resolved" ]; then
            resolved=$(echo "$result" | grep "^Address:" | grep -v "#53" | awk '{print $2}' | head -1)
        fi
        if [ -z "$resolved" ]; then
            resolved=$(echo "$result" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v "^$server$" | head -1)
        fi

        if [ -n "$resolved" ]; then
            if is_private_ip "$resolved"; then
                printf "${RED}✗ HIJACK${NC}: DNS ${DIM}$server${NC} → $domain → ${RED}$resolved${NC}\n"
                return 1
            fi
            printf "${GREEN}✓ PASS${NC}: DNS ${DIM}$server${NC} → $domain → ${CYAN}$resolved${NC}\n"
        else
            printf "${GREEN}✓ PASS${NC}: DNS ${DIM}$server${NC} → $domain\n"
        fi
        return 0
    else
        printf "${RED}✗ FAIL${NC}: DNS ${DIM}$server${NC} → $domain ${RED}(lookup failed)${NC}\n"
        return 1
    fi
}

test_http() {
    local iface=$1
    local url=$2

    # iSH: no interface binding, just test connectivity
    if [ "$OS" = "ish" ]; then
        if command -v curl > /dev/null 2>&1; then
            curl --connect-timeout 5 --max-time 10 -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null | grep -q "200\|204\|301\|302"
            return $?
        elif command -v wget > /dev/null 2>&1; then
            wget --timeout=5 --tries=1 -q -O /dev/null "$url" 2>/dev/null
            return $?
        fi
        return 1
    fi

    local src_ip=$(get_iface_ip "$iface")
    if [ -z "$src_ip" ]; then
        return 1
    fi

    if command -v curl > /dev/null 2>&1; then
        curl --interface "$iface" --connect-timeout 5 --max-time 10 -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null | grep -q "200\|204\|301\|302"
        return $?
    elif command -v wget > /dev/null 2>&1; then
        wget --bind-address="$src_ip" --timeout=5 --tries=1 -q -O /dev/null "$url" 2>/dev/null
        return $?
    else
        local host=$(echo "$url" | sed 's|http://||' | sed 's|/.*||')
        echo -e "GET / HTTP/1.0\r\nHost: $host\r\n\r\n" | nc -w 5 "$host" 80 > /dev/null 2>&1
        return $?
    fi
}

cdn_status_ok() {
    case "$1" in
        2??|3??|403|404) return 0 ;;
    esac
    return 1
}

http_status_reachable() {
    case "$1" in
        [1-5][0-9][0-9]) return 0 ;;
    esac
    return 1
}

test_cdn() {
    local iface=$1
    local label=$2
    local url=$3
    local status exit_code src_ip

    if [ "$OS" != "ish" ]; then
        src_ip=$(get_iface_ip "$iface")
        if [ -z "$src_ip" ]; then
            printf "${RED}✗ FAIL${NC}: CDN $label ${DIM}$url${NC} ${RED}(no source IP)${NC}\n"
            return 1
        fi
    fi

    if command -v curl > /dev/null 2>&1; then
        if [ "$OS" = "ish" ]; then
            status=$(curl -A "$CDN_USER_AGENT" --connect-timeout 5 --max-time 10 -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
        else
            status=$(curl -A "$CDN_USER_AGENT" --interface "$iface" --connect-timeout 5 --max-time 10 -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
        fi
        exit_code=$?

        if [ $exit_code -eq 0 ] && cdn_status_ok "$status"; then
            printf "${GREEN}✓ PASS${NC}: CDN $label ${DIM}$url${NC} → ${CYAN}HTTP $status${NC}\n"
            return 0
        elif [ $exit_code -eq 0 ]; then
            printf "${RED}✗ FAIL${NC}: CDN $label ${DIM}$url${NC} → ${RED}HTTP $status${NC}\n"
            return 1
        else
            printf "${RED}✗ FAIL${NC}: CDN $label ${DIM}$url${NC} ${RED}(connection failed)${NC}\n"
            return 1
        fi
    elif command -v wget > /dev/null 2>&1; then
        if [ "$OS" = "ish" ]; then
            wget --user-agent="$CDN_USER_AGENT" --timeout=5 --tries=1 -q -O /dev/null "$url" 2>/dev/null
        else
            wget --user-agent="$CDN_USER_AGENT" --bind-address="$src_ip" --timeout=5 --tries=1 -q -O /dev/null "$url" 2>/dev/null
        fi
        exit_code=$?

        if [ $exit_code -eq 0 ]; then
            printf "${GREEN}✓ PASS${NC}: CDN $label ${DIM}$url${NC}\n"
            return 0
        fi
        printf "${RED}✗ FAIL${NC}: CDN $label ${DIM}$url${NC} ${RED}(connection failed)${NC}\n"
        return 1
    fi

    printf "${YELLOW}⊘ SKIP${NC}: CDN $label ${DIM}$url${NC} ${YELLOW}(needs curl or wget)${NC}\n"
    return 2
}

test_tcp_target() {
    local iface=$1
    local label=$2
    local host=$3
    local port=$4
    local src_ip exit_code connect_time nc_output nonzero_connect_time

    if [ -z "$label" ] || [ -z "$host" ] || [ -z "$port" ]; then
        printf "${YELLOW}⊘ SKIP${NC}: TCP target ${DIM}$label|$host|$port${NC} ${YELLOW}(expected label|host|port)${NC}\n"
        return 2
    fi

    if [ "$OS" != "ish" ]; then
        src_ip=$(get_iface_ip "$iface")
        if [ -z "$src_ip" ]; then
            printf "${RED}✗ FAIL${NC}: TCP $label ${DIM}$host:$port${NC} ${RED}(no source IP)${NC}\n"
            return 1
        fi
    fi

    if command -v curl > /dev/null 2>&1; then
        if [ "$OS" = "ish" ]; then
            connect_time=$(curl --connect-timeout 5 --max-time 7 -s -o /dev/null -w "%{time_connect}" "telnet://$host:$port" 2>/dev/null)
        else
            connect_time=$(curl --interface "$iface" --connect-timeout 5 --max-time 7 -s -o /dev/null -w "%{time_connect}" "telnet://$host:$port" 2>/dev/null)
        fi
        exit_code=$?
        nonzero_connect_time=$(printf "%s" "$connect_time" | tr -d '0.')

        if [ $exit_code -eq 0 ]; then
            printf "${GREEN}✓ PASS${NC}: TCP $label ${DIM}$host:$port${NC} ${DIM}(connected)${NC}\n"
            return 0
        elif [ $exit_code -eq 28 ] && [ -n "$nonzero_connect_time" ]; then
            printf "${GREEN}✓ PASS${NC}: TCP $label ${DIM}$host:$port${NC} ${DIM}(connected, no data)${NC}\n"
            return 0
        elif [ $exit_code -eq 56 ] && [ -n "$nonzero_connect_time" ]; then
            printf "${GREEN}✓ PASS${NC}: TCP $label ${DIM}$host:$port${NC} ${DIM}(connected, closed by peer)${NC}\n"
            return 0
        fi

        case "$exit_code" in
            7)
                printf "${RED}✗ FAIL${NC}: TCP $label ${DIM}$host:$port${NC} ${RED}(connection refused)${NC}\n"
                return 1
                ;;
            28)
                printf "${RED}✗ FAIL${NC}: TCP $label ${DIM}$host:$port${NC} ${RED}(connect timed out)${NC}\n"
                return 1
                ;;
        esac
    fi

    if command -v nc > /dev/null 2>&1; then
        if [ "$OS" = "ish" ]; then
            nc_output=$(nc -zv -w 5 "$host" "$port" 2>&1)
        elif nc -h 2>&1 | grep -q -- ' -s '; then
            nc_output=$(nc -s "$src_ip" -zv -w 5 "$host" "$port" 2>&1)
        else
            nc_output=$(nc -zv -w 5 "$host" "$port" 2>&1)
        fi
        exit_code=$?

        if [ $exit_code -eq 0 ] && ! echo "$nc_output" | grep -qiE 'refused|timed out|timeout|failed|closed|unreachable'; then
            printf "${GREEN}✓ PASS${NC}: TCP $label ${DIM}$host:$port${NC} ${DIM}(connected)${NC}\n"
            return 0
        fi
    elif command -v timeout > /dev/null 2>&1; then
        timeout 5 sh -c ": >/dev/tcp/$host/$port" > /dev/null 2>&1
        exit_code=$?

        if [ $exit_code -eq 0 ]; then
            printf "${GREEN}✓ PASS${NC}: TCP $label ${DIM}$host:$port${NC} ${DIM}(connected)${NC}\n"
            return 0
        fi
    fi

    if ! command -v curl > /dev/null 2>&1 && ! command -v nc > /dev/null 2>&1 && ! command -v timeout > /dev/null 2>&1; then
        printf "${YELLOW}⊘ SKIP${NC}: TCP $label ${DIM}$host:$port${NC} ${YELLOW}(needs curl, nc, or timeout)${NC}\n"
        return 2
    fi

    printf "${RED}✗ FAIL${NC}: TCP $label ${DIM}$host:$port${NC} ${RED}(connection failed)${NC}\n"
    return 1
}

test_tcp_target_entry() {
    local iface=$1
    local entry=$2
    local label rest host port

    label=${entry%%|*}
    rest=${entry#*|}
    host=${rest%%|*}
    port=${rest#*|}

    if [ "$rest" = "$entry" ] || [ "$port" = "$rest" ]; then
        printf "${YELLOW}⊘ SKIP${NC}: TCP target ${DIM}$entry${NC} ${YELLOW}(expected label|host|port)${NC}\n"
        count_result 2
        return 0
    fi

    test_tcp_target "$iface" "$label" "$host" "$port"
    count_result $?
}

test_proxy_facade_https() {
    local iface=$1
    local label=$2
    local url=$3
    local mode=$4
    local status exit_code src_ip

    if [ "$OS" != "ish" ]; then
        src_ip=$(get_iface_ip "$iface")
        if [ -z "$src_ip" ]; then
            printf "${RED}✗ FAIL${NC}: Proxy HTTPS $label ${DIM}$url${NC} ${RED}(no source IP)${NC}\n"
            return 1
        fi
    fi

    if command -v curl > /dev/null 2>&1; then
        if [ "$OS" = "ish" ]; then
            status=$(curl -A "$PROXY_FACADE_USER_AGENT" --connect-timeout 5 --max-time 10 -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
        else
            status=$(curl -A "$PROXY_FACADE_USER_AGENT" --interface "$iface" --connect-timeout 5 --max-time 10 -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
        fi
        exit_code=$?

        if [ $exit_code -eq 0 ] && cdn_status_ok "$status"; then
            printf "${GREEN}✓ PASS${NC}: Proxy HTTPS $label ${DIM}$url${NC} → ${CYAN}HTTP $status${NC}\n"
            return 0
        elif [ $exit_code -eq 0 ] && { [ "$mode" = "ws" ] || [ "$mode" = "websocket" ]; } && http_status_reachable "$status"; then
            printf "${GREEN}✓ PASS${NC}: Proxy HTTPS $label ${DIM}$url${NC} → ${CYAN}HTTP $status${NC} ${DIM}(reachable; WS mode)${NC}\n"
            return 0
        elif [ $exit_code -eq 0 ]; then
            printf "${RED}✗ FAIL${NC}: Proxy HTTPS $label ${DIM}$url${NC} → ${RED}HTTP $status${NC}\n"
            return 1
        fi

        printf "${RED}✗ FAIL${NC}: Proxy HTTPS $label ${DIM}$url${NC} ${RED}(connection failed)${NC}\n"
        return 1
    elif command -v wget > /dev/null 2>&1; then
        if [ "$OS" = "ish" ]; then
            wget --user-agent="$PROXY_FACADE_USER_AGENT" --timeout=5 --tries=1 -q -O /dev/null "$url" 2>/dev/null
        else
            wget --user-agent="$PROXY_FACADE_USER_AGENT" --bind-address="$src_ip" --timeout=5 --tries=1 -q -O /dev/null "$url" 2>/dev/null
        fi
        exit_code=$?

        if [ $exit_code -eq 0 ]; then
            printf "${GREEN}✓ PASS${NC}: Proxy HTTPS $label ${DIM}$url${NC}\n"
            return 0
        fi
        printf "${RED}✗ FAIL${NC}: Proxy HTTPS $label ${DIM}$url${NC} ${RED}(connection failed)${NC}\n"
        return 1
    fi

    printf "${YELLOW}⊘ SKIP${NC}: Proxy HTTPS $label ${DIM}$url${NC} ${YELLOW}(needs curl or wget)${NC}\n"
    return 2
}

test_proxy_websocket() {
    local iface=$1
    local label=$2
    local url=$3
    local headers exit_code src_ip status

    if ! command -v curl > /dev/null 2>&1; then
        printf "${YELLOW}⊘ SKIP${NC}: Proxy WS $label ${DIM}$url${NC} ${YELLOW}(needs curl)${NC}\n"
        return 2
    fi

    if [ "$OS" != "ish" ]; then
        src_ip=$(get_iface_ip "$iface")
        if [ -z "$src_ip" ]; then
            printf "${RED}✗ FAIL${NC}: Proxy WS $label ${DIM}$url${NC} ${RED}(no source IP)${NC}\n"
            return 1
        fi
    fi

    if [ "$OS" = "ish" ]; then
        headers=$(curl -A "$PROXY_FACADE_USER_AGENT" --http1.1 --connect-timeout 5 --max-time 10 -s -D - -o /dev/null \
            -H "Connection: Upgrade" \
            -H "Upgrade: websocket" \
            -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
            -H "Sec-WebSocket-Version: 13" \
            "$url" 2>/dev/null)
    else
        headers=$(curl -A "$PROXY_FACADE_USER_AGENT" --interface "$iface" --http1.1 --connect-timeout 5 --max-time 10 -s -D - -o /dev/null \
            -H "Connection: Upgrade" \
            -H "Upgrade: websocket" \
            -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
            -H "Sec-WebSocket-Version: 13" \
            "$url" 2>/dev/null)
    fi
    exit_code=$?
    status=$(echo "$headers" | awk '/^HTTP\// {print $2}' | tail -1)

    if echo "$headers" | grep -q "^HTTP/.* 101"; then
        printf "${GREEN}✓ PASS${NC}: Proxy WS $label ${DIM}$url${NC} → ${CYAN}101 Switching Protocols${NC}\n"
        return 0
    elif [ -n "$status" ]; then
        printf "${RED}✗ FAIL${NC}: Proxy WS $label ${DIM}$url${NC} → ${RED}HTTP $status${NC}\n"
        return 1
    elif [ $exit_code -eq 28 ]; then
        printf "${RED}✗ FAIL${NC}: Proxy WS $label ${DIM}$url${NC} ${RED}(timed out before upgrade)${NC}\n"
        return 1
    fi

    printf "${RED}✗ FAIL${NC}: Proxy WS $label ${DIM}$url${NC} ${RED}(connection failed)${NC}\n"
    return 1
}

test_proxy_facade_entry() {
    local iface=$1
    local entry=$2
    local label rest url mode rc

    label=${entry%%|*}
    rest=${entry#*|}
    if [ "$rest" = "$entry" ] || [ -z "$label" ]; then
        printf "${YELLOW}⊘ SKIP${NC}: Proxy facade ${DIM}$entry${NC} ${YELLOW}(expected label|url|mode)${NC}\n"
        count_result 2
        return 0
    fi

    url=${rest%%|*}
    mode=${rest#*|}
    if [ "$mode" = "$rest" ] || [ -z "$mode" ]; then
        mode="ws"
    fi

    test_proxy_facade_https "$iface" "$label" "$url" "$mode"
    rc=$?
    count_result $rc

    case "$mode" in
        ws|websocket)
            test_proxy_websocket "$iface" "$label" "$url"
            count_result $?
            ;;
        https|http)
            ;;
        *)
            printf "${YELLOW}⊘ SKIP${NC}: Proxy WS $label ${DIM}$url${NC} ${YELLOW}(unknown mode: $mode)${NC}\n"
            count_result 2
            ;;
    esac
}

# ─── Test Counter Helpers ─────────────────────────────────

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

count_result() {
    local rc=$1
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    if [ "$rc" -eq 0 ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
    elif [ "$rc" -eq 2 ]; then
        SKIP_COUNT=$((SKIP_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

reset_counts() {
    PASS_COUNT=0
    FAIL_COUNT=0
    SKIP_COUNT=0
    TOTAL_COUNT=0
}

# ─── Per-Interface Test Runner ────────────────────────────

test_interface_connectivity() {
    local iface=$1

    # iSH: skip interface validation (virtual iOS interface)
    if [ "$OS" != "ish" ]; then
        # Verify interface exists
        if command -v ip > /dev/null 2>&1; then
            ip link show dev "$iface" > /dev/null 2>&1 || {
                print_section "Interface: $iface"
                printf "  ${RED}Interface not found${NC}\n\n"
                return 1
            }
        elif command -v ifconfig > /dev/null 2>&1; then
            ifconfig "$iface" > /dev/null 2>&1 || {
                print_section "Interface: $iface"
                printf "  ${RED}Interface not found${NC}\n\n"
                return 1
            }
        fi
    fi

    get_interface_info "$iface"

    # Skip tests if no IP (but not on iSH where we can't check)
    if [ "$OS" != "ish" ]; then
        local ip=$(get_iface_ip "$iface")
        if [ -z "$ip" ]; then
            printf "  ${RED}Skipping tests — no IP configured${NC}\n\n"
            return 1
        fi
    fi

    reset_counts

    if test_enabled ping && [ -n "$PING_TARGETS" ]; then
        # ── Ping/Reachability Tests ──
        if [ "$OS" = "ish" ]; then
            print_section "TCP Reachability ($iface)"
        else
            print_section "Ping Tests ($iface)"
        fi
        for target in $PING_TARGETS; do
            test_ping "$iface" "$target"
            if [ "$OS" = "ish" ]; then
                test_result $? "TCP :53 $target"
            else
                test_result $? "Ping $target via $iface"
            fi
            count_result $?
        done
        printf "\n"
    fi

    if test_enabled dns && [ -n "$PLAIN_DNS" ] && [ -n "$DNS_LOOKUP_DOMAINS" ]; then
        # ── Plain DNS Tests ──
        print_section "Plain DNS ($iface)"
        for server in $PLAIN_DNS; do
            for domain in $DNS_LOOKUP_DOMAINS; do
                test_dns_plain "$iface" "$domain" "$server"
                rc=$?
                count_result $rc
                # Skip remaining domains if server failed
                [ $rc -ne 0 ] && break
            done
        done
        printf "\n"
    fi

    if test_enabled http && [ -n "$HTTP_URLS" ]; then
        # ── HTTP Tests ──
        print_section "HTTP Connectivity ($iface)"
        for url in $HTTP_URLS; do
            test_http "$iface" "$url"
            test_result $? "HTTP GET $url"
            count_result $?
        done
        printf "\n"
    fi

    if test_enabled cdn && [ -n "$CDN_URLS" ]; then
        # ── CDN HTTPS Tests ──
        print_section "CDN Connectivity ($iface)"
        for cdn in $CDN_URLS; do
            label=${cdn%%|*}
            url=${cdn#*|}
            test_cdn "$iface" "$label" "$url"
            count_result $?
        done
        printf "\n"
    fi

    # ── Direct TCP Target Tests ──
    if test_enabled tcp && [ -n "$TCP_TARGETS" ]; then
        print_section "TCP Targets ($iface)"
        for target in $TCP_TARGETS; do
            test_tcp_target_entry "$iface" "$target"
        done
        printf "\n"
    fi

    # ── VLESS/VMESS CDN Facade Tests ──
    if test_enabled proxy && [ -n "$PROXY_FACADES" ]; then
        print_section "Proxy Facades ($iface)"
        for facade in $PROXY_FACADES; do
            test_proxy_facade_entry "$iface" "$facade"
        done
        printf "\n"
    fi

    # ── Interface Summary ──
    local tested=$((TOTAL_COUNT - SKIP_COUNT))
    local success_rate=0
    if [ $tested -gt 0 ]; then
        success_rate=$((PASS_COUNT * 100 / tested))
    fi

    printf "  ${BOLD}Summary for $iface:${NC} $PASS_COUNT/$tested passed"
    if [ $SKIP_COUNT -gt 0 ]; then
        printf " ${YELLOW}($SKIP_COUNT skipped)${NC}"
    fi
    if [ $TOTAL_COUNT -eq 0 ]; then
        printf " ${YELLOW}(no tests configured)${NC}\n"
        printf "  ${YELLOW}▸ NO TESTS${NC}\n"
        printf "\n\n"
        return 0
    fi
    printf " (${success_rate}%%)\n"

    if [ $success_rate -ge 80 ]; then
        printf "  ${GREEN}▸ HEALTHY${NC}\n"
    elif [ $success_rate -ge 50 ]; then
        printf "  ${YELLOW}▸ DEGRADED${NC}\n"
    else
        printf "  ${RED}▸ CRITICAL${NC}\n"
    fi

    printf "\n\n"
}

# ─── Main ─────────────────────────────────────────────────

# Handle command-line arguments: allow user to specify interfaces manually
MANUAL_IFACES=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            print_usage
            exit 0
            ;;
        -c|--config)
            shift
            if [ -z "$1" ]; then
                printf "${RED}ERROR: --config requires a file path${NC}\n"
                exit 1
            fi
            CONFIG_FILE=$1
            CONFIG_FILE_EXPLICIT=1
            ;;
        --config=*)
            CONFIG_FILE=${1#*=}
            CONFIG_FILE_EXPLICIT=1
            ;;
        -t|--tests)
            shift
            if [ -z "$1" ]; then
                printf "${RED}ERROR: --tests requires a comma-separated list${NC}\n"
                exit 1
            fi
            add_test_filters "$1"
            ;;
        --tests=*)
            add_test_filters "${1#*=}"
            ;;
        *)
            if add_test_filter "$1"; then
                :
            else
                MANUAL_IFACES="$MANUAL_IFACES $1"
            fi
            ;;
    esac
    shift
done

detect_os
detect_arch
ensure_config_file
check_jq_dependency
load_config
find_dnslookup
check_dependencies

# Detect interfaces with default routes (or use manual list)
if [ "$OS" = "ish" ]; then
    # iSH on iPad: use virtual interface name, networking goes through iOS
    INTERFACES="ios"
    printf "${CYAN}Detected iSH on iPad — using iOS network stack${NC}\n\n"
elif [ -n "$MANUAL_IFACES" ]; then
    INTERFACES=$(echo "$MANUAL_IFACES" | tr ' ' '\n' | grep -v "^$" | sort -u | tr '\n' ' ')
else
    INTERFACES=$(detect_interfaces)
fi

if [ -z "$INTERFACES" ]; then
    printf "${RED}ERROR: No interfaces with default routes detected!${NC}\n"
    printf "Possible causes:\n"
    printf "  - No default routes configured\n"
    printf "  - No interfaces have external connectivity\n\n"
    printf "${YELLOW}Debug info (OS: $OS, Platform: $PLATFORM, Arch: $ARCH):${NC}\n"
    printf "\n${CYAN}Routing table:${NC}\n"
    if [ "$OS" = "macos" ]; then
        netstat -rn -f inet 2>/dev/null || printf "  (empty)\n"
    elif command -v ip > /dev/null 2>&1; then
        ip route 2>/dev/null | head -20 || printf "  (empty)\n"
        [ -z "$(ip route 2>/dev/null)" ] && printf "  (empty)\n"
    else
        route -n 2>/dev/null || printf "  (empty)\n"
    fi
    printf "\n${CYAN}Available interfaces:${NC}\n"
    if command -v ip > /dev/null 2>&1; then
        ip -br link 2>/dev/null || ip link 2>/dev/null | grep -E "^[0-9]+:" | head -10
    elif command -v ifconfig > /dev/null 2>&1; then
        ifconfig -a 2>/dev/null | grep -E "^[a-z]" | head -10
    fi
    printf "\n${CYAN}To add a default route:${NC}\n"
    printf "  ip route add default via <gateway_ip> dev <interface>\n"
    printf "  Example: ip route add default via 192.168.1.1 dev eth0\n"
    printf "\n${CYAN}Or specify interface manually:${NC}\n"
    printf "  $0 eth0\n"
    exit 1
fi

IFACE_COUNT=$(echo "$INTERFACES" | wc -w | tr -d ' ')

if [ "$OS" = "openwrt" ]; then
    DESCRIPTOR="WAN interfaces detected"
else
    DESCRIPTOR="Interfaces detected"
fi

print_header "$IFACE_COUNT" "$DESCRIPTOR"
printf "${BLUE}Detected interfaces: $INTERFACES${NC}\n\n"

# Test each interface
for iface in $INTERFACES; do
    test_interface_connectivity "$iface"
done

# ─── Encrypted DNS Tests (global, not per-interface) ─────

if [ -n "$DNSLOOKUP_BIN" ] && [ -n "$DNS_LOOKUP_DOMAINS" ] && {
    { test_enabled doh && [ -n "$DOH_DNS" ]; } ||
    { test_enabled dot && [ -n "$DOT_DNS" ]; } ||
    { test_enabled doq && [ -n "$DOQ_DNS" ]; } ||
    { test_enabled dnscrypt && [ -n "$DNSCRYPT_DNS" ]; }
}; then
    EDNS_PASS=0
    EDNS_FAIL=0
    EDNS_TOTAL=0

    printf "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"
    printf "${BLUE}  Encrypted DNS Tests ${DIM}(via default route)${NC}\n"
    printf "${BLUE}═══════════════════════════════════════════════════════════${NC}\n\n"

    if test_enabled doh && [ -n "$DOH_DNS" ]; then
        print_section "DNS-over-HTTPS"
        for server in $DOH_DNS; do
            for domain in $DNS_LOOKUP_DOMAINS; do
                test_dns "$domain" "$server" "DoH"
                rc=$?
                EDNS_TOTAL=$((EDNS_TOTAL + 1))
                if [ "$rc" -eq 0 ]; then EDNS_PASS=$((EDNS_PASS + 1)); else EDNS_FAIL=$((EDNS_FAIL + 1)); break; fi
            done
        done
        printf "\n"
    fi

    if test_enabled dot && [ -n "$DOT_DNS" ]; then
        print_section "DNS-over-TLS"
        for server in $DOT_DNS; do
            for domain in $DNS_LOOKUP_DOMAINS; do
                test_dns "$domain" "$server" "DoT"
                rc=$?
                EDNS_TOTAL=$((EDNS_TOTAL + 1))
                if [ "$rc" -eq 0 ]; then EDNS_PASS=$((EDNS_PASS + 1)); else EDNS_FAIL=$((EDNS_FAIL + 1)); break; fi
            done
        done
        printf "\n"
    fi

    if test_enabled doq && [ -n "$DOQ_DNS" ]; then
        print_section "DNS-over-QUIC"
        for server in $DOQ_DNS; do
            for domain in $DNS_LOOKUP_DOMAINS; do
                test_dns "$domain" "$server" "DoQ"
                rc=$?
                EDNS_TOTAL=$((EDNS_TOTAL + 1))
                if [ "$rc" -eq 0 ]; then EDNS_PASS=$((EDNS_PASS + 1)); else EDNS_FAIL=$((EDNS_FAIL + 1)); break; fi
            done
        done
        printf "\n"
    fi

    if test_enabled dnscrypt && [ -n "$DNSCRYPT_DNS" ]; then
        print_section "DNSCrypt"
        for dnscrypt in $DNSCRYPT_DNS; do
            dnscrypt_label=""
            server=$dnscrypt
            if [ "${dnscrypt#*|}" != "$dnscrypt" ]; then
                dnscrypt_label=${dnscrypt%%|*}
                server=${dnscrypt#*|}
            fi
            for domain in $DNS_LOOKUP_DOMAINS; do
                if [ -n "$dnscrypt_label" ]; then
                    test_dns "$domain" "$server" "DNSCrypt" "DNSCrypt $dnscrypt_label"
                else
                    test_dns "$domain" "$server" "DNSCrypt"
                fi
                rc=$?
                EDNS_TOTAL=$((EDNS_TOTAL + 1))
                if [ "$rc" -eq 0 ]; then EDNS_PASS=$((EDNS_PASS + 1)); else EDNS_FAIL=$((EDNS_FAIL + 1)); break; fi
            done
        done
        printf "\n"
    fi

    if [ $EDNS_TOTAL -gt 0 ]; then
        local_rate=$((EDNS_PASS * 100 / EDNS_TOTAL))
        printf "  ${BOLD}Encrypted DNS:${NC} $EDNS_PASS/$EDNS_TOTAL passed (${local_rate}%%)\n\n"
    fi
fi

printf "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"
printf "${BLUE}  Test Complete — $IFACE_COUNT interface(s) tested${NC}\n"
printf "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"
