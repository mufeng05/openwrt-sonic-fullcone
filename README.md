# openwrt-sonic-fullcone

适用于 OpenWrt 的 SONiC 风格全锥形 NAT（Full Cone NAT），支持 per-zone 和 per-protocol 粒度控制。

## 这是什么

将 [SONiC 的 fullcone NAT 内核补丁](https://github.com/sonic-net/sonic-linux-kernel/blob/master/patches-sonic/Support-for-fullcone-nat.patch)（Akhilesh Samineni / Broadcom）移植到 OpenWrt，并集成了支持细粒度控制的防火墙和 LuCI 界面。

### 工作原理

内核补丁在 conntrack 内部增加了第二张哈希表（`nat_by_manip_src`），以**转换后的 3-tuple**（协议、源 IP、源端口）为索引：

- **SNAT 方向**：3-tuple 唯一性保证——同一个 (proto, src_ip, src_port) 不会被不同连接复用，实现端点无关映射（EIM）
- **DNAT 方向**：反向查找——入站数据包通过哈希表找到原始内部主机，实现端点无关过滤（EIF）
- **全 L4 协议支持**：TCP、UDP、ICMP、GRE、SCTP、DCCP、UDPlite
- **非 fullcone 流量零开销**：fullcone 标志位是 per-rule 的，不是全局的

### 支持的内核版本

6.6、6.12、6.18（三个版本共用同一份补丁——相关的 nf_nat_core.c 结构完全一致）

## 安装

在 OpenWrt 源码目录下执行：

```bash
# 先更新 feeds（LuCI 补丁需要）
./scripts/feeds update -a
./scripts/feeds install -a

# 一键应用所有补丁
curl -sSL https://raw.githubusercontent.com/mufeng05/openwrt-sonic-fullcone/master/add_sonic_fullcone.sh | bash

# 编译
make menuconfig   # 无需额外勾选，补丁直接应用到源码树
make -j$(nproc)
```

脚本会自动 clone 仓库、检测内核版本、复制补丁到对应位置，完成后自动清理临时文件。

## 配置

### 方式一：Web 界面（LuCI）

LuCI 补丁将 fullcone 选项直接集成到 OpenWrt 原生防火墙配置页面中，无需安装额外的 LuCI 应用。

**全局设置**（网络 → 防火墙 → 常规设置）：
- "Fullcone NAT" 复选框 — 为所有启用了伪装（Masquerading）的 zone 开启全锥形 NAT

**Zone 设置**（网络 → 防火墙 → 区域 → 编辑）：
- **常规标签**："Fullcone NAT" 复选框（仅在开启伪装时显示）
- **高级标签**："Fullcone protocols" 多选框（TCP、UDP、UDP-Lite、SCTP、DCCP）
- **高级标签**："Fullcone source IPs" 动态列表（输入需要 fullcone 的内网 IP 或 CIDR）

### 方式二：UCI 命令行

```bash
# 全局启用
uci set firewall.@defaults[0].fullcone='1'

# 仅对 wan zone 启用
uci set firewall.@zone[1].fullcone='1'

# 仅对 UDP 启用 fullcone（推荐用于游戏/P2P）
uci add_list firewall.@zone[1].fullcone_proto='udp'

# 仅对特定 IP 启用 fullcone
uci add_list firewall.@zone[1].fullcone_src='192.168.1.100'
uci add_list firewall.@zone[1].fullcone_src='192.168.1.200'

# 应用
uci commit firewall
/etc/init.d/firewall restart

# 验证
nft list ruleset | grep fullcone
```

### 方式三：UCI 配置文件

#### Level 1：全局默认

为所有启用伪装的 zone 开启 fullcone：

```
# /etc/config/firewall
config defaults
    option fullcone '1'
```

#### Level 2：Per-zone

仅对 WAN zone 启用：

```
config defaults
    # 这里不设 fullcone

config zone
    option name 'wan'
    option masq '1'
    option fullcone '1'        # 仅此 zone 启用 fullcone
```

#### Level 3：Per-protocol

仅对 UDP 启用（推荐用于游戏/P2P 场景）：

```
config zone
    option name 'wan'
    option masq '1'
    option fullcone '1'
    list fullcone_proto 'udp'  # 仅 UDP 走 fullcone
```

生成的 nftables 规则：

```nft
chain srcnat_wan {
    # UDP → fullcone
    meta nfproto ipv4 meta l4proto udp fullcone comment "!fw4: wan IPv4 fullcone udp NAT srcnat"
    # 其余流量 → 标准 masquerade
    meta nfproto ipv4 masquerade comment "!fw4: wan IPv4 masquerade"
}

chain dstnat_wan {
    # 仅 UDP 做反向 fullcone 映射
    meta nfproto ipv4 meta l4proto udp fullcone comment "!fw4: wan IPv4 fullcone udp NAT dstnat"
}
```

多协议：

```
config zone
    option name 'wan'
    option masq '1'
    option fullcone '1'
    list fullcone_proto 'udp'
    list fullcone_proto 'tcp'
```

#### Level 4：Per-source-IP

仅对局域网内指定 IP 启用 fullcone，其余走普通对称 NAT：

```
config zone
    option name 'wan'
    option masq '1'
    option fullcone '1'
    list fullcone_src '192.168.1.100'
    list fullcone_src '192.168.1.200'
```

生成的 nftables 规则：

```nft
chain srcnat_wan {
    # 仅指定 IP 走 fullcone
    meta nfproto ipv4 ip saddr { 192.168.1.100, 192.168.1.200 } fullcone
    # 其余 IP 走普通 masquerade
    meta nfproto ipv4 masquerade
}
chain dstnat_wan {
    # DNAT 无需过滤 IP，内核只会命中有 fullcone 映射的流
    meta nfproto ipv4 fullcone
}
```

可以和 `fullcone_proto` 组合：只对指定 IP 的 UDP 流量启用 fullcone：

```
config zone
    option name 'wan'
    option masq '1'
    option fullcone '1'
    list fullcone_proto 'udp'
    list fullcone_src '192.168.1.100'
    list fullcone_src '192.168.1.200'
```

也支持 CIDR 网段：

```
    list fullcone_src '192.168.1.0/24'
```

#### Level 5：高级 — 手写 nftables 规则

如需按源网段、端口范围等任意条件匹配，可使用 fw4 includes 或 `/etc/nftables.d/`：

```nft
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

注意：使用自定义规则时，应关闭该 zone 的 fw4 fullcone 选项以避免冲突。

## 文件说明

```
kernel/
  984-add-sonic-fullcone-support.patch      # nf_nat_core.c：3-tuple 哈希表、EIM/EIF
  985-add-sonic-fullcone-to-nft.patch       # nft_fullcone.c：nftables 表达式 + Kconfig

patches/
  iptables/901-sonic-fullcone.patch         # libipt_MASQUERADE --fullcone 标志
  libnftnl/001-libnftnl-*.patch             # fullcone 表达式序列化
  nftables/002-nftables-*.patch             # nft CLI "fullcone" 关键字
  luci-app-firewall/001-add-*.patch         # LuCI Web 界面集成

firewall/
  firewall3/001-sonic-fullcone.patch        # fw3：per-zone + per-proto
  firewall4/001-sonic-fullcone.patch        # fw4：per-zone + per-proto
```

## 与其他 fullcone 实现的对比

| | SONiC（本项目） | xt_FULLCONENAT | nft-fullcone | bcm-fullconenat |
|---|---|---|---|---|
| 映射存储 | conntrack 自身内 | 平行哈希表 | 平行哈希表 | conntrack 期望表 |
| 读路径锁 | RCU（无自旋锁） | 全局自旋锁 | 全局自旋锁 | 全局 expect 锁 |
| 查找复杂度 | O(1) 哈希 | O(1) 哈希 | O(1) 哈希 | **O(N) 全表扫描** |
| 协议支持 | 全部 L4 | 仅 UDP | 仅 UDP | 仅 UDP |
| 清理机制 | 自动（conntrack 生命周期） | Workqueue GC | Workqueue GC | 期望超时 |
| Per-rule 控制 | 支持（flag bit） | 不支持 | 不支持 | 不支持 |

## 致谢

- 内核补丁：Akhilesh Samineni (Broadcom)，来自 [sonic-net/sonic-linux-kernel](https://github.com/sonic-net/sonic-linux-kernel)
- nftables/libnftnl 表达式接口：Syrone Wong (fullcone-nat-nftables)
- OpenWrt 集成：openwrt-sonic-fullcone contributors

## 许可证

内核补丁：GPL-2.0（遵循 Linux 内核许可证）
用户态补丁：GPL-2.0
