# node-panel

给机场主用的中转面板。一条命令装好：程序、systemd、反向代理、HTTPS 全自动。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dreamrer/node-panel/main/install.sh)
```

装完敲 `np` 进管理菜单。

---

## 一条命令做了什么

1. 识别架构（amd64 / arm64），下载程序并校验 SHA256
2. 建系统用户、装到 `/opt/node-panel`、生成随机管理员密码
3. 配好 systemd（开机自启、崩溃自动重启）
4. 反向代理与 HTTPS **自适应**：
   - 80/443 空闲 → 装 Caddy，自动签发证书
   - 已有 nginx / 宝塔 → **不动你的配置**，打印一段现成的反代配置给你贴
   - 域名挂了 CDN → 自动识别并用 **CDN 模式**（回源走 http，避免 308 死循环）
5. 验证面板就绪，打印后台地址与账号密码

非交互安装（适合批量）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dreamrer/node-panel/main/install.sh) -d panel.example.com
# 域名挂了 CDN：
bash <(curl -fsSL .../install.sh) -d panel.example.com cdn
```

## 管理命令 `np`

直接敲 `np` 是菜单，也可以带子命令：

| 命令 | 作用 |
| --- | --- |
| `np` | 管理菜单 |
| `np status` | 状态、后台地址、账号密码 |
| `np log` | 实时日志 |
| `np start` / `stop` / `restart` | 起停 |
| `np update` | 升级到最新版（校验 + 失败自动回滚） |
| `np domain <域名> [cdn]` | 更换域名、重签证书 |
| `np backup` / `np restore <文件>` | 备份 / 恢复数据 |
| `np uninstall` | 卸载（数据可选保留） |

## 要求

- Linux + systemd，x86_64 或 arm64
- root
- 一个解析到本机的域名（**必须用 HTTPS**：节点令牌和机场通讯密钥都在请求里）
- 需要 `curl tar coreutils iproute2`

## 装完以后

打开 `https://你的域名/admin/`，左边 **「使用说明」** 有从 0 到 1 的完整教程：添加机场 Xboard → 登记节点 → 给落地装节点后端 → 让订阅走本面板。

### 怎么让 veil 节点进到用户订阅里

veil 节点在机场 Xboard 里只是一个普通 VLESS，机场自己不认识 veil（密钥、流量形状只存在面板里），所以得由面板把它补进订阅。按机场装没装 **apex 加密插件**二选一。

#### ① 机场装了 apex 加密插件（推荐，订阅地址完全不用改）

在插件设置的「③ veil 节点」里填两样：

| 配置项 | 填什么 |
| --- | --- |
| 中转面板地址 | `https://你的域名` |
| 面板令牌 | 面板「机场面板 →（这家）→ 插件令牌」点生成后复制 |

```
客户端 → Xboard（加密插件）
            ├ 渲染订阅明文
            ├ 送到面板 → 补上 veil 节点 → 还回来
            ├ 用机场自己的密钥加密
            └ 返回客户端
```

**机场的加密密钥不会发给面板**，订阅地址、打包机器人、客户端都不用动。面板连不上或超时 → 插件原样加密下发，**订阅绝不中断**。

#### ② 机场没装插件 —— 让订阅经过面板

在「机场面板 →（这家）→ veil 接入」里配**订阅域名**（把机场现有订阅域名指到面板，用户 URL 不变）或**路径前缀**；也可以直接用内置地址，把机场 Xboard 的**订阅地址 subscribe_url** 填成 `https://你的域名/sub`。

> ⚠️ 用方式②要改机场的订阅地址，**所有老用户的订阅链接会跟着变**。站点地址 `app_url` 保持机场原域名不要动。

**两种方式都不需要额外配反代**：面板会自己去机场 Xboard 取订阅（机场地址和通讯密钥已经填在面板里）。机场自定义过订阅路径也不用管，面板原样转发。

## 文件位置

```
/opt/node-panel/node-panel     程序
/opt/node-panel/config.json    监听地址、管理员账号密码（0600）
/opt/node-panel/data/          面板数据（节点、机场、账单、密钥）
/etc/systemd/system/node-panel.service
/etc/caddy/conf.d/node-panel.caddy   反代站点（用 Caddy 时）
```

`np backup` 会把 `config.json` 和 `data/` 一起打包——里面有全部密钥，妥善保管。
