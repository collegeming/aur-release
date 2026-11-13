# aur-release

自动化跟踪多个上游 GitHub 仓库的 release，一有新版就重新生成 PKGBUILD +
`.SRCINFO` 并推送到 AUR（Arch User Repository）。

目前接入的包：

- [`siyuan-unlock-bin`](packages/siyuan-unlock-bin/) — 源 [appdev/siyuan-unlock](https://github.com/appdev/siyuan-unlock)，跟踪稳定版，`x86_64` + `aarch64`。
- [`snishaper-bin`](packages/snishaper-bin/) — 源 [SnishaperTeam/SniShaper](https://github.com/SnishaperTeam/SniShaper)，跟踪稳定版，`x86_64` + `aarch64`（上游自 v1.30.0 起提供 arm64 GUI 包）。
- [`kimi-code-bin`](packages/kimi-code-bin/) — 源 [MoonshotAI/kimi-code](https://github.com/MoonshotAI/kimi-code)，跟踪稳定版，`x86_64` + `aarch64`。
  AUR 上已有一个 `kimi-code`，走 npm 方式安装、运行时要 nodejs；这里做的是官方「独立二进制」
  的 `-bin` 包，不依赖 Node.js。
- [`kimi-code-desktop-bin`](packages/kimi-code-desktop-bin/) — 源 [Kimi Code 官网](https://kimi.com/code) 的**桌面客户端**，
  `x86_64`。注意它和上面的 `kimi-code-bin` 是**两个不同产品、两条版本线**：桌面端是 GUI
  （自带 Electron，版本 1.x），CLI 是终端工具（版本 2.x），两者可同时安装
  （分别占 `/usr/bin/kimi-code` 与 `/usr/bin/kimi`）。上游没有公开仓库、也不发 GitHub
  release，只有官网安装包，所以走的是它自带更新器的 feed（见下文 `kind`）。

  > 桌面端的**内置更新器在 Arch 上不工作**：它按发行版包来区分（`resources/package-type`
  > 是 `deb`），升级时会去调 `dpkg`。装了本包之后请一律用 `pacman -Syu` 升级，应用里若
  > 提示更新失败属预期现象。
- [`dbx-desktop-bin`](packages/dbx-desktop-bin/) — 源 [t8y2/dbx](https://github.com/t8y2/dbx)
  （Tauri/Rust 桌面数据库客户端），跟踪稳定版，`x86_64` + `aarch64`。

  > AUR 上已有两个同上游的包：`dbx`（从源码构建，`makedepends` 需 rust/cargo/nodejs/pnpm，
  > 装一次要拉整套构建工具链）和 `dbx-bin`（**只有 x86_64**，由他人维护）。本包补的是
  > **aarch64**：直接解包官方 `.deb` 预编译产物，双架构都覆盖，安装时无需任何构建依赖。
- [`mark-shot-arch-bin`](packages/mark-shot-arch-bin/) — 源 [jswysnemc/mark-shot](https://github.com/jswysnemc/mark-shot)
  （Qt 6 Wayland 截图/标注工具），`x86_64` + `aarch64`。

  > **自建预编译包**：上游的 aarch64 资产是在 Ubuntu 上编的（FFmpeg 6，`libavcodec.so.60`），
  > Arch Linux ARM 提供的是 FFmpeg 9（`.so.63`），pacman 直接拒绝安装；该资产还缺少
  > `libmark-shot-layer-shell.so`（构建机没装 LayerShellQt，可选插件被静默跳过）。所以本包
  > 不用上游二进制，改由本仓库的 `build` workflow 在 Arch / Arch Linux ARM 里原生编译
  > （aarch64 跑在原生 arm64 runner 上），产物挂在 `aur-built-latest` release，本包只下载
  > 解包，用户端不需要任何构建工具链。

## 工作原理

```
packages/<pkg>/
├── metadata.toml        # 上游仓库、tag 规则、各架构资产名模板
├── PKGBUILD.template    # 带 {{pkgver}} / {{sha256_x86_64}} … 占位符的模板
└── build-<arch>.sh      # 仅自建包：在 Arch / ALARM 里编译（[build] kind = "self"）

.github/workflows/aur-update.yaml   # cron 每 6 小时 + 手动触发 → 推 AUR
.github/workflows/build.yaml        # cron 每 6 小时 + 手动触发 → 编译自建包并发 release
tools/update_package.py             # 检测 → 渲染 → 生成 SRCINFO → 推 AUR
tools/known_hosts                   # aur.archlinux.org 的 SSH host key（防中间人）
```

workflow 每 6 小时跑一次：对 `packages/` 下每个目录

1. 调 GitHub API 取上游 release **列表**，挑出「资产齐全 + tag 能解析成合法 pkgver」
   里版本最高的那个（`prerelease = true` 时连预发布一起纳入候选），得到 tag 与各资产
   文件的 sha256（GitHub 对每个资产直接返回 `digest`，**无需下载 200MB+ 的二进制**
   去算校验和）；`kind = "electron-updater"` 的包则改读厂商更新 feed，同样自带校验和，
   同样不用下载安装包；
2. 去掉 tag 前缀、按可选规则 `sanitize` 成合法 `pkgver`（不含连字符），与 AUR 当前
   版本用 `vercmp` 比较；解析不了的 tag 会被跳过并在日志里列出（见下）；
3. 若上游更新：用模板渲染出新 PKGBUILD，用 `makepkg --printsrcinfo` 生成 `.SRCINFO`；
4. `git clone` AUR 仓库 → 提交 → push（AUR 禁止 force-push，只会线性追加）。

`[build] kind = "self"` 的包多一条构建链路：`build` workflow 在 Arch / Arch Linux ARM
里编译，产物挂到本仓库的 `aur-built-latest` 滚动 release；`aur-update` 只负责「等各架构
产物齐全 → 渲染 PKGBUILD → 推 AUR」，构建完成后会自动触发它，不用干等定时任务。

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
- 自建包（`[build] kind = "self"`）另有 **build** workflow：`package` 同上，`arch` 可只编
  单个架构（留空 = 全部声明的架构）。只有全部架构的产物都发布成功，`aur-update` 才会
  发版；构建成功会自动触发 `aur-update`。

## 新增一个包

1. `packages/<pkg>/` 下新建 `metadata.toml` + `PKGBUILD.template`（照抄现成样例改）；
2. 确保 `AUR_SSH_PRIVATE_KEY` 等 Secret 已配（公钥登记到 AUR 账号即可——首次 push
   到不存在的包名会自动建仓库，**无需网页提交**，见上文「首次接入一个新包」）；
3. 完事，下次 workflow 自动接管。想立刻验证可手动触发一次。

包名按 AUR 惯例取，别随手上后缀：

| 后缀 | AUR 约定含义 | 本项目适用性 |
|---|---|---|
| `-bin` | 装上游**预编译产物**（release 里的二进制/压缩包） | ✅ 本项目的默认形态 |
| `-git` / `-svn` / `-hg` | 从 VCS **最新提交**构建，版本形如 `r1234.abcdef-1` | ❌ 本项目跟的是 release，不是 HEAD |
| 无后缀 | 从源码构建正式版 | 一般留给别人维护的源码包，同名已被占用时只能用 `-bin` |

### `metadata.toml` 选项

| 字段 | 作用 |
|---|---|
| `pkgname` / `maintainer` | 包名与 PKGBUILD 头部维护者署名 |
| `[upstream] kind` | 上游类型。默认 `github-releases`（跟 GitHub release）；`electron-updater` 读厂商更新 feed，用于「没有公开仓库、只有官网安装包」的上游（如 Kimi Code 桌面端） |
| `[upstream] owner` / `repo` | GitHub 上游仓库（`kind = "github-releases"` 时必填） |
| `[upstream] feed` | `latest-linux.yml` 之类的更新 feed 地址（`kind = "electron-updater"` 时必填）。里面直接带版本号和各安装包的校验和，且 URL 是带版本号的，所以「查新版」只要一次几百字节的请求，不用为了看版本下载上百 MB 安装包 |
| `[upstream] prerelease` | `true` 时把预发布也纳入候选。用于「Linux 构建只在 beta 里」这类上游 |
| `[checksum] algorithm` | PKGBUILD 用哪种校验和：`sha256`（默认）或 `sha512`。GitHub 的资产 `digest` 是 sha256，electron-builder 的 feed 是 sha512，模板占位符和 `.SRCINFO` 里的数组名会跟着变（`{{sha512_x86_64}}` / `sha512sums_x86_64`） |
| `[tag] strip_prefix` | 去掉 tag 前缀，`v3.8.1 → 3.8.1`。前缀对不上说明上游改了 tag 格式，该 release 会被跳过并在日志里打印 `warning: ignoring release(s) with unusable tags`，不会拿错版本去推 |
| `[tag] sanitize` | `[正则, 替换]` 二元组，把 tag 进一步规整成合法 pkgver。`-` 在 pkgver 里非法，用它把 `1.29.0-beta.3` 收成 `1.29.0beta3`；按 vercmp 规则 `1.0beta < 1.0`，预发布天然排早于正式版，后续升正式版会被正确识别为新版本 |
| `[assets.<arch>] name` | 各架构对应的资产名模板，`{pkgver}` 会被替换 |
| `[assets.<arch>] names` | 同上，但给一组候选名（上游改过资产命名时用），按顺序取第一个命中的 |
| `[extras.<key>] url` | 额外的源文件（如仓库里而非 release 资产里的 LICENSE）。每次运行都会重新下载并算校验和，所以上游改了文件会自动跟上，不会因为写死的校验和让用户构建失败。URL 里可用 `{{tag}}` / `{{tag_url}}` / `{{tag_ref}}` / `{pkgver}` |
| `[build] kind` | `"self"` 表示产物由本项目编译，不用上游二进制。此时 `[assets.<arch>]` 匹配的是**本仓库产物**的文件名；`resolve` 先查 `[build] repo` 的滚动 release，产物不齐就返回 `pending_build`，AUR 不会抢先发布一个没有产物的版本 |
| `[build] repo` / `[build] release_tag` | 存放自建产物的仓库与滚动 release 标签（如 `collegeming/aur-release` + `aur-built-latest`）。仓库必须公开：用户端 `makepkg` 是匿名下载 |
| `[build] arches` | 需要自建、且要等产物齐全的架构列表；列表里每个架构都有产物后才发布 |

模板占位符：

| 占位符 | 含义 |
|---|---|
| `{{pkgver}}` `{{pkgrel}}` `{{maintainer}}` | 版本、包版本号、维护者署名 |
| `{{tag}}` | 去掉前缀前的原始 tag（`filter`/`sanitize` 之后与 pkgver 不同时用它） |
| `{{tag_url}}` | 同上，但按 URL 路径转义（kimi-code 的 tag 形如 `@moonshot-ai/kimi-code@2.1.1`，裸 `@` 在 URL 里有歧义，转义成 `%40` 后与 GitHub 自己 `browser_download_url` 的形式一致） |
| `{{tag_ref}}` | 同上，但按 raw.githubusercontent 的 ref 段**整段**转义（`/` 也要转成 `%2F`） |
| `{{asset_<arch>}}` | 该架构命中的资产**真实文件名**（上游改名过时，模板不用跟着改） |
| `{{url_asset_<arch>}}` | 该资产的下载 URL（feed 型上游的 URL 才是权威写法） |
| `{{sha256_<arch>}}` / `{{sha512_<arch>}}` | 该资产的校验和，用哪个取决于 `[checksum] algorithm` |
| `{{url_extra_<key>}}` / `{{sha256_extra_<key>}}` | `[extras.<key>]` 的 URL 与校验和 |

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