# openwrt-sonic-fullcone

适用于 OpenWrt 的 SONiC 风格全锥形 NAT（Full Cone NAT），支持 per-zone、per-protocol、per-source-IP 粒度控制。

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
make menuconfig   # 无需额外勾选，fullcone 编译进 nft_masq 模块
make -j$(nproc)
```

脚本会自动 clone 仓库、检测内核版本、复制补丁到对应位置，完成后自动清理临时文件。

## 配置逻辑

`defaults.fullcone` 是**全局总开关**：

- **关闭时**（默认）：所有 fullcone 功能禁用，zone 里的设置无效
- **开启时**：功能可用，但每个 zone 还需要**单独勾选** fullcone 才会生效

这和 OpenWrt 的 `flow_offloading` 是同样的模式。

## 方式一：Web 界面（LuCI）

LuCI 补丁将 fullcone 选项直接集成到 OpenWrt 原生防火墙配置页面中，无需安装额外的 LuCI 应用。

**全局设置**（网络 → 防火墙 → 常规设置）：
- "Fullcone NAT" 复选框 — 全局总开关

**Zone 编辑**（网络 → 防火墙 → 区域 → 点击编辑）：
- **常规标签**："Fullcone NAT" 复选框（仅在开启伪装时出现），在 zone 列表和编辑弹窗中均可见
- **高级标签**："Fullcone protocols" 多选框（TCP、UDP、UDP-Lite、SCTP、DCCP）— 限定协议
- **高级标签**："Fullcone source IPs" 动态列表 — 限定内网源 IP

## 方式二：UCI 命令行

```bash
# 1. 打开全局总开关（必须）
uci set firewall.@defaults[0].fullcone='1'

# 2. 对 wan zone 启用 fullcone
uci set firewall.@zone[1].fullcone='1'

# 3. 可选：仅对 UDP 启用（推荐用于游戏/P2P）
uci add_list firewall.@zone[1].fullcone_proto='udp'

# 4. 可选：仅对特定内网 IP 启用
uci add_list firewall.@zone[1].fullcone_src='192.168.1.100'
uci add_list firewall.@zone[1].fullcone_src='192.168.1.200'

# 应用
uci commit firewall
/etc/init.d/firewall restart

# 验证
nft list ruleset | grep fullcone
```

## 方式三：UCI 配置文件示例

### 基本用法：全 zone 全协议 fullcone

```
config defaults
    option fullcone '1'           # 全局总开关

config zone
    option name 'wan'
    option masq '1'
    option fullcone '1'           # 此 zone 启用 fullcone
```

### 仅 UDP 启用 fullcone

```
config zone
    option name 'wan'
    option masq '1'
    option fullcone '1'
    list fullcone_proto 'udp'     # 仅 UDP 走 fullcone，其余走标准 masquerade
```

生成的 nftables 规则：

```nft
chain srcnat_wan {
    meta nfproto ipv4 meta l4proto udp fullcone  # UDP → fullcone
    meta nfproto ipv4 masquerade                 # 其余 → 标准 masquerade
}
chain dstnat_wan {
    meta nfproto ipv4 meta l4proto udp fullcone  # 仅 UDP 反向映射
}
```

### 仅特定 IP 启用 fullcone

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
    meta nfproto ipv4 ip saddr { 192.168.1.100, 192.168.1.200 } fullcone
    meta nfproto ipv4 masquerade
}
chain dstnat_wan {
    meta nfproto ipv4 fullcone
}
```

### 组合：特定 IP + 特定协议

```
config zone
    option name 'wan'
    option masq '1'
    option fullcone '1'
    list fullcone_proto 'udp'
    list fullcone_src '192.168.1.100'
    list fullcone_src '192.168.1.200'
```

也支持 CIDR 网段：`list fullcone_src '192.168.1.0/24'`

### 高级：手写 nftables 规则

如需更复杂的匹配条件，可使用 `/etc/nftables.d/`：

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
  985-add-sonic-fullcone-to-ipt.patch       # xt_MASQUERADE.c：iptables FULLCONE target (PRE+POST)
  986-add-sonic-fullcone-to-nft.patch       # nft_masq.c：nftables fullcone 表达式 (PRE+POST)

patches/
  iptables/901-sonic-fullcone.patch         # libxt_NAT.c：注册 FULLCONE 用户态 target
  libnftnl/001-libnftnl-*.patch             # fullcone 表达式序列化
  nftables/002-nftables-*.patch             # nft CLI "fullcone" 关键字
  luci-app-firewall/001-add-*.patch         # LuCI Web 界面集成

translations/
  zh_Hans.po                                # 中文翻译（安装时追加到 po 文件）

firewall/
  firewall3/001-sonic-fullcone.patch        # fw3：per-zone, per-proto, per-IP, EIM+EIF
  firewall4/001-sonic-fullcone.patch        # fw4：per-zone, per-proto, per-IP, EIM+EIF
```

## 已知限制

### fw3 (iptables) 相关

- **fw3 代码只对 IPv4 生成 NAT 规则**：firewall3 的 `zones.c` 里 `print_zone_rule` 在 `FW3_TABLE_NAT` 分支中有 `if (zone->masq && handle->family == FW3_FAMILY_V4)` 判断，IPv6 走不同路径。因此本项目的 fw3 patch 只生成 IPv4 fullcone 规则。

  **手动添加 IPv6 fullcone**：内核侧的 984/985 补丁和 901 用户态补丁都是 IPv4/IPv6 通用的，`FULLCONE` target 对两个协议族都注册了。可以在 `/etc/firewall.user` 里手动加：

  ```bash
  ip6tables -t nat -A POSTROUTING -o wan -j FULLCONE
  ip6tables -t nat -A PREROUTING  -i wan -j FULLCONE
  ```

### 通用限制

- **端口奇偶保持（RFC 4787 REQ-3b）未实现**：fullcone 端口分配不保证奇数端口映射到奇数、偶数映射到偶数。现代应用（游戏、WebRTC、VoIP）几乎不依赖此特性。

- **Hairpinning（NAT 回流）不由本项目处理**：内网主机通过外网地址访问另一个内网主机的场景，需要另行配置 NAT reflection 规则。

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
