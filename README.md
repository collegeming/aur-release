# aur-release

自动化跟踪多个上游 GitHub 仓库的 release，一有新版就重新生成 PKGBUILD +
`.SRCINFO` 并推送到 AUR（Arch User Repository）。

第一个接入的包是 [`siyuan-unlock-bin`](packages/siyuan-unlock-bin/)（源：[appdev/siyuan-unlock](https://github.com/appdev/siyuan-unlock)）。

## 工作原理

```
packages/<pkg>/
├── metadata.toml        # 上游仓库、tag 规则、各架构资产名模板
└── PKGBUILD.template    # 带 {{pkgver}} / {{sha256_x86_64}} … 占位符的模板

.github/workflows/aur-update.yaml   # cron 每 6 小时 + 手动触发
tools/update_package.py             # 检测 → 渲染 → 生成 SRCINFO → 推 AUR
tools/known_hosts                   # aur.archlinux.org 的 SSH host key（防中间人）
```

workflow 每 6 小时跑一次：对 `packages/` 下每个目录

1. 调 GitHub API 取上游 `release/latest`，得到 tag 与各资产文件的 sha256
   （GitHub 对每个资产直接返回 `digest`，**无需下载 200MB+ 的二进制**去算校验和）；
2. 把 tag 去掉前缀得到 `pkgver`，与 AUR 当前 PKGBUILD 中的版本用 `vercmp` 比较；
3. 若上游更新：用模板渲染出新 PKGBUILD，用 `makepkg --printsrcinfo` 生成 `.SRCINFO`；
4. `git clone` AUR 仓库 → 提交 → push（AUR 禁止 force-push，只会线性追加）。

上游 tag 格式、资产命名等差异都收敛在每包的 `metadata.toml` 里，换一个项目基本不用改脚本。

## 首次接入一个新包

**不需要人工网页提交。** AUR 的 git 服务支持「push 到不存在的包名即自动建仓库」：
`git clone ssh://aur@aur.archlinux.org/<pkgbase>.git` 一个尚不存在的包，会返回一个
空的仓库（AUR 官方文档与 aurweb 源码的行为均如此）；往这个空仓库 push 第一个
commit（含 `PKGBUILD` 与 `.SRCINFO`）后，包就在 AUR 上建立了。

本仓库的 workflow 天然覆盖这个场景：脚本 clone 到空仓库、发现没有 PKGBUILD、走
"Initial import" 分支提交建包。**唯一的前置条件是公钥已登记到 AUR 账号**（见下一节），
无需打开 AUR 网页手工传文件。

```bash
# 想在 push 前人工核对产物，可本地渲染看一眼（本机即可，不需 Arch）
python tools/update_package.py render packages/siyuan-unlock-bin --out _render
# 产物在 _render/PKGBUILD 与 _render/.SRCINFO
```

> 安全边界：脚本从不用 force-push（AUR 对非 TU 用户禁止 force-push），
> 只做 fast-forward 线性追加；分支固定 `master`。

## 密钥 / AUR 账号配置（关键）

这里最容易踩坑。SSH 密钥分成两半，**私钥绝不放仓库**：

| 放在哪 | 说明 |
|---|---|
| AUR 账号 | **公钥**：aur.archlinux.org → 登录 → My Account → SSH Public Key，粘贴公钥内容 |
| GitHub Secrets | **私钥**：仓库 → Settings → Secrets and variables → Actions → New repository secret |

- 建议为自动化**单独生成一对 Ed25519 密钥**，别用你日常主密钥：

  ```bash
  ssh-keygen -t ed25519 -C "aur-release" -f ~/.ssh/aur_release_ed25519 -N ""
  cat ~/.ssh/aur_release_ed25519.pub    # 这个给 AUR 账号
  cat ~/.ssh/aur_release_ed25519        # 这个给 GitHub Secrets（千万别提交进仓库）
  ```

- 之所以私钥进 **Secrets 而非仓库文件**：Secrets 仅对 Actions 可见、加密存储、
  不进日志；放在仓库里等于任何能读仓库的人都能登录你的 AUR 账号。fork 之后
  Secrets 也不会被拷贝过去，天然防泄露。

需要建两个 Secret：

| Secret 名 | 内容 |
|---|---|
| `AUR_SSH_PRIVATE_KEY` | 上一步的**私钥**全文（含 `-----BEGIN/END-----` 行） |
| `AUR_KNOWN_HOSTS` | （可选）`tools/known_hosts` 的内容，留空则用仓库内该文件 |

`tools/known_hosts` 里已内置 2026-08 抓取的 aur 官方 host key（ed25519 + rsa），
workflow 用 `StrictHostKeyChecking=yes` 严格校验，防止中间人；如果哪天 AUR 换了 key，
用 `ssh-keyscan aur.archlinux.org > tools/known_hosts` 更新即可。

## 手动触发 / 只跑一个包

- Actions 标签页 → **Update** workflow → **Run workflow**。
- 在 `package` 输入框填 `siyuan-unlock-bin` 可只跑该包；留空跑全部。

## 新增第二个包

1. `packages/<pkg>/` 下新建 `metadata.toml` + `PKGBUILD.template`（照抄现成样例改）；
2. 若 AUR 尚无该包，网页提交一次建仓库；
3. 完事，下次 workflow 自动接管。

## 本地验证（不碰 AUR）

```bash
# 渲染一份看看，产物在 _render/
python tools/update_package.py render packages/siyuan-unlock-bin --out _render
```

完整 `update`（会 clone/push AUR）只应在 Action 容器里跑。

## 依赖

- `tools/update_package.py`：Python 3.11+（`tomllib`），无第三方依赖。
- AUR 侧：`makepkg`、`vercmp`、`git`、`openssh`。workflow 用 `archlinux:latest`
  容器，全部自带/现装。