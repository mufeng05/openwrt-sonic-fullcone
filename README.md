# openwrt-sonic-fullcone

SONiC-style Full Cone NAT for OpenWrt, with per-zone and per-protocol granularity.

## What is this

A forward-port of [SONiC's fullcone NAT kernel patch](https://github.com/sonic-net/sonic-linux-kernel/blob/master/patches-sonic/Support-for-fullcone-nat.patch) (by Akhilesh Samineni / Broadcom) to OpenWrt, plus firewall integration that supports fine-grained control.

### How it works

The kernel patch adds a second hash table inside conntrack (`nat_by_manip_src`) indexed by the **translated 3-tuple** (protocol, source IP, source port). This gives:

- **SNAT**: 3-tuple uniqueness — the same (proto, src_ip, src_port) is never reused across different connections, enabling Endpoint-Independent Mapping (EIM).
- **DNAT**: reverse lookup — inbound packets are matched against the hash to find the original internal host, enabling Endpoint-Independent Filtering (EIF).
- **All L4 protocols**: TCP, UDP, ICMP, GRE, SCTP, DCCP, UDPlite.
- **Zero overhead for non-fullcone flows**: the fullcone flag is per-rule, not global.

### Supported kernel versions

6.6, 6.12, 6.18 (same patch for all three — the relevant nf_nat_core.c structure is identical).

## Install

```bash
cd /path/to/openwrt-source

# Clone this repo
git clone https://github.com/user/openwrt-sonic-fullcone /tmp/openwrt-sonic-fullcone

# Apply patches
bash /tmp/openwrt-sonic-fullcone/add_sonic_fullcone.sh

# Build
make menuconfig   # nothing extra to select — patches are applied directly
make -j$(nproc)
```

## Configuration

### Level 1: Global default

Enable fullcone for all zones that have masquerading:

```
# /etc/config/firewall
config defaults
    option fullcone '1'
```

### Level 2: Per-zone

Enable fullcone only on the WAN zone:

```
config defaults
    # fullcone NOT set here

config zone
    option name 'wan'
    option masq '1'
    option fullcone '1'        # only this zone gets fullcone
```

### Level 3: Per-protocol

Enable fullcone only for UDP (recommended for gaming / P2P):

```
config zone
    option name 'wan'
    option masq '1'
    option fullcone '1'
    list fullcone_proto 'udp'  # only UDP gets fullcone
```

Generated nftables rules:

```
chain srcnat_wan {
    # UDP → fullcone
    meta nfproto ipv4 meta l4proto udp fullcone comment "!fw4: wan IPv4 fullcone udp NAT srcnat"
    # Everything else → standard masquerade
    meta nfproto ipv4 masquerade comment "!fw4: wan IPv4 masquerade"
}

chain dstnat_wan {
    # Only UDP gets reverse fullcone mapping
    meta nfproto ipv4 meta l4proto udp fullcone comment "!fw4: wan IPv4 fullcone udp NAT dstnat"
}
```

Multiple protocols:

```
config zone
    option name 'wan'
    option masq '1'
    option fullcone '1'
    list fullcone_proto 'udp'
    list fullcone_proto 'tcp'
```

### Level 4: Advanced — raw nftables rules

For arbitrary matching (by source subnet, port range, etc.), use fw4 includes or `/etc/nftables.d/`:

```
# /etc/nftables.d/10-fullcone-custom.nft
table inet fullcone-custom {
    chain srcnat {
        type nat hook postrouting priority srcnat + 1; policy accept;
        oifname "eth1" ip saddr 192.168.1.0/24 meta l4proto udp fullcone
    }
    chain dstnat {
        type nat hook prerouting priority dstnat + 1; policy accept;
        iifname "eth1" meta l4proto udp fullcone
    }
}
```

Note: when using raw rules, disable fw4's fullcone for that zone to avoid conflicts.

## UCI commands

```bash
# Enable fullcone globally
uci set firewall.@defaults[0].fullcone='1'

# Enable per-zone
uci set firewall.@zone[1].fullcone='1'

# Restrict to UDP only
uci add_list firewall.@zone[1].fullcone_proto='udp'

# Apply
uci commit firewall
/etc/init.d/firewall restart

# Verify
nft list ruleset | grep fullcone
```

## Files

```
kernel/
  984-add-sonic-fullcone-support.patch   # nf_nat_core.c: 3-tuple hash, EIM/EIF
  985-add-sonic-fullcone-to-nft.patch    # nft_fullcone.c: nftables expression + Kconfig

patches/
  iptables/901-sonic-fullcone.patch      # libipt_MASQUERADE --fullcone flag
  libnftnl/001-libnftnl-*.patch          # fullcone expression serialization
  nftables/002-nftables-*.patch          # nft CLI "fullcone" keyword

firewall/
  firewall3/001-sonic-fullcone.patch     # fw3: per-zone + per-proto
  firewall4/001-sonic-fullcone.patch     # fw4: per-zone + per-proto
```

## Comparison with other fullcone implementations

| | SONiC (this) | xt_FULLCONENAT | nft-fullcone | bcm-fullconenat |
|---|---|---|---|---|
| Mapping storage | In conntrack itself | Parallel hash table | Parallel hash table | conntrack expectations |
| Read-path lock | RCU (no spinlock) | Global spinlock | Global spinlock | Global expect lock |
| Lookup | O(1) hash | O(1) hash | O(1) hash | **O(N) full scan** |
| Protocols | All L4 | UDP only | UDP only | UDP only |
| Cleanup | Automatic (conntrack lifecycle) | Workqueue GC | Workqueue GC | Expectation timeout |
| Per-rule control | Yes (flag bit) | No (target replacement) | No (expression replacement) | No (masquerade mode) |

## Credits

- Kernel patch: Akhilesh Samineni (Broadcom) via [sonic-net/sonic-linux-kernel](https://github.com/sonic-net/sonic-linux-kernel)
- nftables/libnftnl expression interface: Syrone Wong (fullcone-nat-nftables)
- OpenWrt integration: openwrt-sonic-fullcone contributors

## License

Kernel patches: GPL-2.0 (follows Linux kernel license)
Userspace patches: GPL-2.0
