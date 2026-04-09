#!/usr/bin/env bash
# add_sonic_fullcone.sh — Apply SONiC fullcone NAT patches to OpenWrt source tree
# Run from the root of your OpenWrt/LEDE source checkout.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! [ -d "./package" ] || ! [ -d "./target" ]; then
    echo "Error: run this script from the root of an OpenWrt source tree."
    exit 1
fi

# --- Detect kernel version ---
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

# --- Apply kernel patches ---
for kv in $kernel_versions; do
    hack_dir="./target/linux/generic/hack-$kv"
    if [ -d "$hack_dir" ]; then
        echo "Applying kernel patches to hack-$kv ..."
        cp -f "$SCRIPT_DIR/kernel/984-add-sonic-fullcone-support.patch" "$hack_dir/"
        cp -f "$SCRIPT_DIR/kernel/985-add-sonic-fullcone-to-nft.patch"  "$hack_dir/"
    else
        echo "Warning: $hack_dir not found, skipping kernel $kv"
    fi
done

# --- Apply iptables patch ---
ipt_dir="./package/network/utils/iptables/patches"
mkdir -p "$ipt_dir"
echo "Applying iptables patch ..."
cp -f "$SCRIPT_DIR/patches/iptables/901-sonic-fullcone.patch" "$ipt_dir/"

# --- Apply libnftnl patch ---
nftnl_dir="./package/libs/libnftnl/patches"
mkdir -p "$nftnl_dir"
echo "Applying libnftnl patch ..."
cp -f "$SCRIPT_DIR/patches/libnftnl/001-libnftnl-add-fullcone-expression-support.patch" "$nftnl_dir/"

# --- Apply nftables patch ---
nft_dir="./package/network/utils/nftables/patches"
mkdir -p "$nft_dir"
echo "Applying nftables patch ..."
cp -f "$SCRIPT_DIR/patches/nftables/002-nftables-add-fullcone-expression-support.patch" "$nft_dir/"

# --- Apply firewall patches ---
# Detect fw3 or fw4
if [ -d "./package/network/config/firewall4" ]; then
    fw4_dir="./package/network/config/firewall4/patches"
    mkdir -p "$fw4_dir"
    echo "Applying firewall4 patch (per-zone + per-proto fullcone) ..."
    cp -f "$SCRIPT_DIR/firewall/firewall4/001-sonic-fullcone.patch" "$fw4_dir/"
fi

if [ -d "./package/network/config/firewall" ]; then
    fw3_dir="./package/network/config/firewall/patches"
    mkdir -p "$fw3_dir"
    echo "Applying firewall3 patch (per-zone + per-proto fullcone) ..."
    cp -f "$SCRIPT_DIR/firewall/firewall3/001-sonic-fullcone.patch" "$fw3_dir/"
fi

# --- Apply LuCI patch ---
luci_fw_dir="./feeds/luci/applications/luci-app-firewall/patches"
if [ -d "./feeds/luci/applications/luci-app-firewall" ]; then
    mkdir -p "$luci_fw_dir"
    echo "Applying luci-app-firewall patch (web UI fullcone options) ..."
    cp -f "$SCRIPT_DIR/patches/luci-app-firewall/001-add-fullcone-options.patch" "$luci_fw_dir/"
else
    echo "Note: luci-app-firewall not found in feeds. Run ./scripts/feeds update -a first,"
    echo "      then re-run this script, or apply the LuCI patch manually."
fi

# --- Enable NFT_FULLCONE in kernel config ---
for kv in $kernel_versions; do
    kconfig="./target/linux/generic/config-$kv"
    if [ -f "$kconfig" ]; then
        if ! grep -q "CONFIG_NFT_FULLCONE" "$kconfig"; then
            echo "CONFIG_NFT_FULLCONE=y" >> "$kconfig"
            echo "Added CONFIG_NFT_FULLCONE=y to config-$kv"
        fi
    fi
done

echo ""
echo "Done. Now run 'make menuconfig' and build."
echo ""
echo "UCI configuration example:"
echo "  # Global default (all zones)"
echo "  uci set firewall.@defaults[0].fullcone='1'"
echo ""
echo "  # Per-zone"
echo "  uci set firewall.@zone[1].fullcone='1'"
echo ""
echo "  # Per-protocol (only UDP gets fullcone)"
echo "  uci add_list firewall.@zone[1].fullcone_proto='udp'"
echo ""
echo "  uci commit firewall"
echo "  /etc/init.d/firewall restart"
