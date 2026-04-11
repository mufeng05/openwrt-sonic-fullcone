#!/usr/bin/env bash
# add_sonic_fullcone.sh — Apply SONiC fullcone NAT patches to OpenWrt source tree
#
# Usage:
#   cd /path/to/openwrt && curl -sSL https://raw.githubusercontent.com/mufeng05/openwrt-sonic-fullcone/master/add_sonic_fullcone.sh | bash
#
# Prerequisites:
#   - OpenWrt source tree with kernel 6.6 / 6.12 / 6.18
#   - ./scripts/feeds update -a && ./scripts/feeds install -a
#   - git, curl installed

set -e

# --- Check required tools ---
for tool in git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: '$tool' is required but not found in PATH."
        exit 1
    fi
done

# --- Check environment ---
if ! [ -d "./package" ] || ! [ -d "./target" ]; then
    echo "Error: please run this script from the root of an OpenWrt source tree."
    exit 1
fi

# --- Clone repo to temp dir ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

REPO="https://github.com/mufeng05/openwrt-sonic-fullcone"
echo "Cloning $REPO ..."
if ! git clone --depth=1 --single-branch "$REPO" "$TMPDIR/sonic-fullcone" 2>&1; then
    echo "Error: failed to clone $REPO"
    echo "Check your network connection and try again."
    exit 1
fi
SRC="$TMPDIR/sonic-fullcone"

# --- Detect kernel versions ---
kernel_versions=""
for f in ./include/kernel-[0-9]*; do
    [ -f "$f" ] && kernel_versions="$kernel_versions $(basename "$f" | sed 's/kernel-//')"
done
if [ -z "$kernel_versions" ]; then
    for f in ./target/linux/generic/kernel-[0-9]*; do
        [ -f "$f" ] && kernel_versions="$kernel_versions $(basename "$f" | sed 's/kernel-//')"
    done
fi
kernel_versions="$(echo "$kernel_versions" | xargs)"

if [ -z "$kernel_versions" ]; then
    echo "Error: cannot detect kernel version."
    exit 1
fi
echo "Detected kernel versions: $kernel_versions"

applied=0
skipped=0

# --- Kernel patches ---
#   984: nf_nat_core fullcone (SONiC core, 3-tuple hash)
#   985: xt_MASQUERADE FULLCONE target (iptables, PRE+POST hooks)
#   986: nft_masq fullcone expression (nftables, PRE+POST hooks)
for kv in $kernel_versions; do
    hack_dir="./target/linux/generic/hack-$kv"
    if [ -d "$hack_dir" ]; then
        cp -f "$SRC/kernel/984-add-sonic-fullcone-support.patch"  "$hack_dir/"
        cp -f "$SRC/kernel/985-add-sonic-fullcone-to-ipt.patch"   "$hack_dir/"
        cp -f "$SRC/kernel/986-add-sonic-fullcone-to-nft.patch"   "$hack_dir/"
        echo "[kernel]   hack-$kv: applied (984+985+986)"
        applied=$((applied + 3))
    else
        echo "[kernel]   hack-$kv: directory not found, skipped"
        skipped=$((skipped + 3))
    fi
done

# --- iptables: FULLCONE target userspace support ---
if [ -d "./package/network/utils/iptables" ]; then
    ipt_dir="./package/network/utils/iptables/patches"
    mkdir -p "$ipt_dir"
    cp -f "$SRC/patches/iptables/901-sonic-fullcone.patch" "$ipt_dir/"
    echo "[iptables] applied"
    applied=$((applied + 1))
else
    echo "[iptables] not found, skipped"
    skipped=$((skipped + 1))
fi

# --- libnftnl: fullcone expression serialization ---
if [ -d "./package/libs/libnftnl" ]; then
    nftnl_dir="./package/libs/libnftnl/patches"
    mkdir -p "$nftnl_dir"
    cp -f "$SRC/patches/libnftnl/001-libnftnl-add-fullcone-expression-support.patch" "$nftnl_dir/"
    echo "[libnftnl] applied"
    applied=$((applied + 1))
else
    echo "[libnftnl] not found, skipped"
    skipped=$((skipped + 1))
fi

# --- nftables: fullcone CLI keyword ---
if [ -d "./package/network/utils/nftables" ]; then
    nft_dir="./package/network/utils/nftables/patches"
    mkdir -p "$nft_dir"
    cp -f "$SRC/patches/nftables/002-nftables-add-fullcone-expression-support.patch" "$nft_dir/"
    echo "[nftables] applied"
    applied=$((applied + 1))
else
    echo "[nftables] not found, skipped"
    skipped=$((skipped + 1))
fi

# --- firewall4 (nftables/fw4): per-zone, per-proto, per-IP fullcone ---
if [ -d "./package/network/config/firewall4" ]; then
    fw4_dir="./package/network/config/firewall4/patches"
    mkdir -p "$fw4_dir"
    cp -f "$SRC/firewall/firewall4/001-sonic-fullcone.patch" "$fw4_dir/"
    echo "[fw4]      applied"
    applied=$((applied + 1))
else
    echo "[fw4]      not found, skipped"
    skipped=$((skipped + 1))
fi

# --- firewall3 (iptables/fw3): per-zone, per-proto, per-IP fullcone ---
if [ -d "./package/network/config/firewall" ]; then
    fw3_dir="./package/network/config/firewall/patches"
    mkdir -p "$fw3_dir"
    cp -f "$SRC/firewall/firewall3/001-sonic-fullcone.patch" "$fw3_dir/"
    echo "[fw3]      applied"
    applied=$((applied + 1))
else
    echo "[fw3]      not found, skipped"
    skipped=$((skipped + 1))
fi

# --- LuCI: web interface fullcone options ---
if [ -d "./feeds/luci/applications/luci-app-firewall" ]; then
    luci_fw_dir="./feeds/luci/applications/luci-app-firewall/patches"
    mkdir -p "$luci_fw_dir"
    cp -f "$SRC/patches/luci-app-firewall/"*.patch "$luci_fw_dir/"
    echo "[luci]     patch applied"

    # Append zh_Hans translations directly to po file (po/ is not in build_dir, patches won't work)
    zh_po="./feeds/luci/applications/luci-app-firewall/po/zh_Hans/firewall.po"
    if [ -f "$zh_po" ] && ! grep -q "Fullcone NAT" "$zh_po"; then
        cat "$SRC/translations/zh_Hans.po" >> "$zh_po"
        echo "[luci]     zh_Hans translation appended"
    fi
    applied=$((applied + 1))
else
    echo "[luci]     not found — run './scripts/feeds update -a && ./scripts/feeds install -a' first"
    skipped=$((skipped + 1))
fi

echo ""
echo "=== Done: $applied applied, $skipped skipped ==="
if [ "$skipped" -gt 0 ]; then
    echo "Warning: some patches were skipped. Run './scripts/feeds update -a && ./scripts/feeds install -a' and re-run this script if LuCI was skipped."
fi
echo ""
echo "Next steps:"
echo "  make menuconfig    # no extra options needed"
echo "  make -j\$(nproc)"
echo ""
echo "After flashing, configure via LuCI (Network > Firewall) or UCI:"
echo ""
echo "  # Step 1: Enable global gate (required)"
echo "  uci set firewall.@defaults[0].fullcone='1'"
echo ""
echo "  # Step 2: Enable fullcone for wan zone"
echo "  uci set firewall.@zone[1].fullcone='1'"
echo ""
echo "  # Optional: restrict to UDP only"
echo "  uci add_list firewall.@zone[1].fullcone_proto='udp'"
echo ""
echo "  # Optional: restrict to specific LAN IPs"
echo "  uci add_list firewall.@zone[1].fullcone_src='192.168.1.100'"
echo "  uci add_list firewall.@zone[1].fullcone_src='192.168.1.200'"
echo ""
echo "  uci commit firewall && /etc/init.d/firewall restart"
echo ""
echo "Verify:"
echo "  # fw4 (nftables)"
echo "  nft list ruleset | grep fullcone"
echo "  # fw3 (iptables)"
echo "  iptables -t nat -L zone_wan_postrouting -n -v | grep FULLCONE"
