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

机场的 Xboard 里把 **订阅地址（subscribe_url）** 填成 `https://你的域名/sub` 即可，**站点 URL（app_url）保持原样不动**。

机场自定义过订阅路径的不用管：路径由 Xboard 自己拼在后面，面板只剥掉自己那截 `/sub`，剩下的整段原样转发。比如订阅路径是 `abc123`，用户链接就是 `https://你的域名/sub/abc123/<token>`，面板照样认。

## 文件位置

```
/opt/node-panel/node-panel     程序
/opt/node-panel/config.json    监听地址、管理员账号密码（0600）
/opt/node-panel/data/          面板数据（节点、机场、账单、密钥）
/etc/systemd/system/node-panel.service
/etc/caddy/conf.d/node-panel.caddy   反代站点（用 Caddy 时）
```

`np backup` 会把 `config.json` 和 `data/` 一起打包——里面有全部密钥，妥善保管。
