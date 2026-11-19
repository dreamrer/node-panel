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

### 怎么让订阅走面板

**推荐：给客户端单独设一个订阅地址。** 在 **apex 打包机器人**里给这个品牌单独设置订阅地址，填 `https://你的域名/sub`。这样只有用 App 的用户走面板、拿得到 veil 节点。

> ⚠️ **不要去改机场 Xboard 的「订阅地址 subscribe_url」**——那会让所有老用户的订阅链接跟着变，已经在用的人全要重新订阅。

**不需要额外配任何反代。** 面板会自己去机场 Xboard 取订阅——因为机场的地址和通讯密钥已经填在面板里了：

```
用户 ──► https://你的域名/sub/<订阅路径>/<token>
              │  面板服务器自己向机场 Xboard 发请求
              ▼
         机场 Xboard ──► 订阅原文
              │  只给带 veil/1 的客户端多插一条 veil 节点
              ▼
            返回用户
```

这个转发是面板程序内部的逻辑，不是要你去 nginx / Caddy 里配的东西。流量、到期、用户原有的节点，Xboard 给什么就是什么，面板一个字不改；普通客户端拿到的和直连机场一模一样。

机场自定义过订阅路径也不用管：路径由 Xboard 自己拼在后面，面板只剥掉自己那截 `/sub`，剩下整段原样转发。

## 文件位置

```
/opt/node-panel/node-panel     程序
/opt/node-panel/config.json    监听地址、管理员账号密码（0600）
/opt/node-panel/data/          面板数据（节点、机场、账单、密钥）
/etc/systemd/system/node-panel.service
/etc/caddy/conf.d/node-panel.caddy   反代站点（用 Caddy 时）
```

`np backup` 会把 `config.json` 和 `data/` 一起打包——里面有全部密钥，妥善保管。
