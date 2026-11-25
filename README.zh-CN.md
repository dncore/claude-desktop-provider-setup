# claude-desktop-provider-setup

让 Claude Desktop 使用与 Claude Code CLI 相同的第三方 AI Gateway —— 一条命令完成，
不需要重新填写 Base URL、Token 或模型 ID。

```
$ ./install.command

  backup: …/backups/20261123T013710Z
  helper: …/helper/credential-helper.sh

Claude Desktop is configured.
  provider:   gateway
  base URL:   https://gw.example.com/api/anthropic
  auth:       bearer
  credential: helper script (token read from settings.json, 21 bytes)
  models:     4 configured
  config id:  7b4b4385-dabb-4fbe-af5d-6786f91d1e12
```

[English](README.md)

---

## 一、项目介绍

Claude Desktop 的供应商设置来自它自己的「第三方推理配置」，
**不会**读取 `ANTHROPIC_BASE_URL` 或你的 `~/.claude/settings.json`。
Anthropic 在
[Move Claude Code CLI users](https://support.claude.com/en/articles/18466061-move-claude-code-cli-users)
中明确写了这一点。因此已经把 Claude Code 指向 Gateway 的开发者，必须在 Desktop 里
把同样的东西再填一遍。

本工具读取你现有的 Claude Code 配置，转换成 Claude Desktop 的第三方推理配置，
安装 Credential Helper，映射模型，并在你知情的前提下重启应用。

它不是 Claude Desktop 的替代品，也不是代理或 Gateway。它只做一件事：
把一份配置从一个地方搬到另一个地方，并且能完整撤回。

## 二、支持平台

| 平台 | 版本 | 状态 |
|---|---|---|
| macOS | 13 Ventura 及以上，Apple Silicon 与 Intel | 已实现；一致性测试与生命周期测试通过 |
| Windows | 10 build 19041 及以上、Windows 11，PowerShell 5.1+ | 已实现；在 Windows 10 22H2 / PS 5.1 上通过 |

不支持 Linux。Claude Desktop 有 Linux 版本，但本项目没有测试过，也不假装支持。

## 三、系统要求

- 已安装 Claude Desktop，并且**至少启动过一次**（配置目录在首次运行时创建）。
  未安装时工具会提示官方下载地址，不会下载任何安装包。
- 已在 `~/.claude/settings.json` 中配置好 Gateway 的 Claude Code。
- 不需要管理员权限，不需要 Homebrew、Node.js、Python 或 PowerShell 7。

详见 [macOS 安装](docs/macos-installation.md) 与
[Windows 安装](docs/windows-installation.md)。

## 四、安装与使用

```sh
git clone https://github.com/dncore/claude-desktop-provider-setup.git
cd claude-desktop-provider-setup
./install.command          # macOS
.\install.bat              # Windows
```

先看清楚它会做什么（不写入任何东西）：

```sh
./install.command plan
```

然后重启 Claude Desktop 即可。

### 4.1 一次运行会打印什么

```
  backup: …/backups/20261123T013710Z      改动前的配置库副本
  helper: …/helper/credential-helper.sh   Desktop 取 token 时调用的脚本

Claude Desktop is configured.
  provider:   gateway                     本工具唯一写入的 provider
  base URL:   https://gw.example.com/api/anthropic
  auth:       bearer                      与 Claude Code 当前发送的一致
  credential: helper script (token read from settings.json, 21 bytes)
  models:     4 configured                第一条是 Desktop 的默认模型
  config id:  7b4b4385-…                  本工具拥有的那一条
```

以上没有一处是密钥；`21 bytes` 是 token 的字节数，不是 token 本身。

### 4.2 命令

| 命令 | 作用 | 是否写入 |
|---|---|---|
| `plan` | 以 JSON 输出解析结果 | 否 |
| `install` | 配置 Claude Desktop（默认） | 是 |
| `update` | 修改 Claude Code 配置后重新应用 | 是 |
| `verify` | 检查已安装配置是否完整可用 | 否 |
| `diagnose` | 输出脱敏诊断报告，可安全贴到 issue | 否 |
| `backup` / `restore` / `list-backups` | 备份与还原配置库 | 是 |
| `magpie` | 把 provider 导出给 magpie，见 [§八](#八交给-magpie) | 仅 `--apply` |
| `uninstall` | 只删除本工具创建的内容 | 是 |

### 4.3 日常情况

**换了 token。** 不用做任何事。配置里存的是助手脚本路径而不是密钥，Desktop 下次请求会读到新值。

**改了模型列表。** 运行 `./install.command update`：重读 `settings.json`，覆盖同一条目，改动前先备份。

**感觉哪里不对。** `./install.command verify` 检查文件与助手协议；`diagnose` 输出可贴进 issue 的脱敏报告。

**想彻底移除。** `./uninstall.command`。Claude Code 的文件从未被修改，那边不需要还原。

### 4.4 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 2 | 参数错误 |
| 3 | Claude Code 配置不可用（没有 URL、没有模型，或映射点名了文件里没有的模型） |
| 4 | 两个凭据不一致；用 `--auth-scheme bearer\|x-api-key` 指定 |
| 5 | 环境问题：没装 Claude Desktop、没有可还原的备份 |
| 6 | 写入失败，或写入后的校验失败 |
| 7 | 凭据助手没有按约定应答 |

失败只打印一行 `error: <kind>: <detail>` 到 stderr，不会留下半成品；`restore` 能把上一条配置放回去。

### 4.5 Windows 上

路径在 `%LOCALAPPDATA%` 下。当前 MSIX 版 Claude Desktop 把数据放在虚拟化目录里，本工具运行时解析真实路径。在仓库目录里运行 `.\install.bat`，那里没有 macOS 的 `./install.command`。

完整参数：`./install.command --help`。

## 五、工作原理

```
~/.claude/settings.json
        │  只读，绝不修改
        ▼
   解析 ──── settings.json 的 env 块优先于 shell 环境变量
        │   （这正是 Claude Code 的实际行为，见 docs/research-findings.md §6）
        ▼
   计划 ──── 校验 URL；两种凭证冲突时拒绝猜测
        │
        ├──► <Claude-3p>/configLibrary/<uuid>.json     文件内不含任何密钥
        ├──► <state>/helper/credential-helper.{sh,cmd} 每次运行重新读取 settings.json
        └──► <state>/state.json                        记录创建了什么，供卸载使用
```

三个需要说明的设计决定：

**配置文件里没有密钥。** 使用 `inferenceCredentialKind: helper-script`，
Token 始终留在 Claude Code 本来就在读的那个文件里。在那里更换 Token，
Desktop 下一次请求就会用上新的 —— 不需要重装、不需要重启、也不存在第二份密钥要同步。

**写入用户级配置库，而不是托管策略。** 在 Windows 上写入 `HKCU` 策略会让
Claude Desktop 把设备视为「受管理」，官方文档写明这会导致 WSL 中的 Code 会话被拒绝
（只有机器级策略能重新开启）、远程文件下载降级、Code 会话的 shell 出网被沙箱限制。
用户级配置库没有这些副作用，而且应用内的配置窗口写的也正是这个位置。
权衡过程见 [docs/research-findings.md](docs/research-findings.md) 第 7 节。

**拒绝猜测。** 当 `ANTHROPIC_AUTH_TOKEN` 与 `ANTHROPIC_API_KEY` 同时存在且值不同：
Claude Code 会同时发送两个请求头，而 Claude Desktop 只能发一个。工具会停下来问你。

更多：[架构](docs/architecture.md) · [调研结论](docs/research-findings.md) ·
[安全说明](docs/security.md)。

## 六、配置示例

假设 `~/.claude/settings.json` 是：

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://gw.example.com/api/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "…",
    "ANTHROPIC_MODEL": "gw-sonnet-5",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "gw-opus-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "gw-haiku-5"
  }
}
```

工具会向 Claude Desktop 的配置库写入：

```json
{
  "inferenceProvider": "gateway",
  "inferenceGatewayBaseUrl": "https://gw.example.com/api/anthropic",
  "inferenceGatewayAuthScheme": "bearer",
  "inferenceCredentialKind": "helper-script",
  "inferenceCredentialHelper": "/Users/<you>/Library/Application Support/claude-desktop-provider-setup/helper/credential-helper.sh",
  "inferenceCredentialHelperTtlSec": 900,
  "inferenceModels": [
    { "name": "gw-sonnet-5" },
    { "name": "gw-opus-5",  "anthropicFamilyTier": "opus",  "isFamilyDefault": true },
    { "name": "gw-haiku-5", "anthropicFamilyTier": "haiku", "isFamilyDefault": true }
  ],
  "deploymentMode": "3p"
}
```

第一个模型是 Claude Desktop 的默认模型。`anthropicFamilyTier` 让层级别名
（opus/sonnet/haiku/fable）指向你 Gateway 的模型。Windows 上对应字段是
`inferenceCredentialHelperWindows`，路径位于 `%LOCALAPPDATA%`。

这份文件里没有任何 API Key。

## 七、模型映射

模型 ID 原样取自 `ANTHROPIC_MODEL` 与四个 `ANTHROPIC_DEFAULT_*_MODEL` 变量，
不臆造、不规范化、不改大小写。

当网关的模型 ID 不足以说明模型能力时，加一个映射文件：

```sh
cp config/model-mapping.example.json config/model-mapping.json
./install.command --mapping config/model-mapping.json
```

```json
{
  "schemaVersion": 1,
  "models": [
    { "id": "gw-opus-5", "labelOverride": "Opus 5 (gateway)",
      "anthropicFamilyTier": "opus", "supports1m": true, "behavesAs": "claude-opus-5" }
  ]
}
```

`models` 是**数组**而不是以模型 ID 为键的对象。原因是模型 ID 常含点号
（如 `us.anthropic.claude-sonnet-5`），而 macOS 实现用 `plutil` 读 JSON，
它无法定位含点号的字典键。这看起来像风格选择，其实不是，详见
[架构文档](docs/architecture.md)。

映射条目只能提供属性：`labelOverride`、`supports1m`、`prefer1m`、
`anthropicFamilyTier`、`isFamilyDefault`、`behavesAs`、`maxEffort`。
除非加 `--allow-unlisted-models`，否则它不能新增模型 ID，
避免误配你账号实际无法使用的模型。

`config/model-mapping.json` 已被 git 忽略，只有示例文件会被提交。

## 八、交给 magpie

[magpie](https://usemagpie.ai) 是把所有 agent 收在一个本地网关后面的菜单栏应用。如果你更愿意让
magpie 托管 Claude Desktop 的配置，本工具可以把 Claude Code 已经在用的 provider 导出成 magpie
能导入的形式：

```sh
./install.command magpie                      # 打印导入链接，什么都不改
./install.command magpie --apply              # 把链接交给 magpie
./install.command magpie --apply --set-tiers  # 顺带绑定 sonnet/opus/haiku/fable
```

三点须知：

- **链接里不带你的 token。** magpie 会在自己的提示里问一次，所以密钥不会进 shell 历史、进程列表
  或日志。也正因为如此，`--apply` 需要终端：没有终端时它打印链接后退出，而不是做到一半失败。
- **档位要单独绑，而且这一步有代价。** `--set-tiers` 会把 `~/.claude/settings.json` 改成指向
  magpie 的网关，此后 Claude Code 需要 magpie 常驻——用 `magpie daemon install` 让它跑起来。
- **不会替你安装 magpie。** 命令会告诉你本机有没有，没有的话去哪里拿。装第三方软件这件事由你决定。

## 九、卸载与恢复

```sh
./uninstall.command        # macOS
.\uninstall.bat            # Windows
```

只删除本工具创建的那一个配置条目，恢复安装前正在生效的配置，
删除 Helper 与状态文件，保留备份。配置库里的其他条目一律不动，
`~/.claude/settings.json` 从不修改。加 `--purge` 可一并删除备份。

从快照恢复：

```sh
./install.command list-backups
./install.command restore                    # 最近一次
./install.command restore 20261123T013710Z   # 指定某一次
```

恢复前会按备份清单里的 SHA-256 逐文件校验，校验不通过不写入。

## 十、安全说明

- **本工具不写入任何密钥。** 不写进配置、不写进 `state.json`、不写进日志。
  诊断报告只输出字节数。测试套件会在凭证出现在任何输出中时判定失败。
- **Helper 是收紧的。** 不接收参数；settings 路径以单引号字面量烧录在脚本里；
  拒绝跟随符号链接；stdout 只输出 Token；退出码 0/3/4/6；
  任何 `CLAUDE_HELPER_CONTEXT` 下都不会交互阻塞。
- **备份里可能含有你此前在应用内保存的 API Key**，因此备份目录为 `0700`、
  文件为 `0600`，并且永远不会进入诊断输出。
- **已评估并否决了 Keychain / DPAPI**：它们会在 `settings.json` 之外再造一份密钥副本，
  而且要么在静默刷新时弹窗，要么对任何本地进程可读。完整推理见
  [docs/security.md](docs/security.md)。
- **不联网。** 本项目没有任何网络代码。

## 十一、常见问题

**需要重新填写 Token 吗？** 只要它在 `~/.claude/settings.json` 的 `env` 块里，就不需要。
如果它只存在于 shell 环境变量中，工具会停下并告诉你该往哪里补一行 ——
Desktop 不继承你的 shell 环境，Helper 之后读不到。

**会影响 Claude Code 吗？** 不会，只读取，不修改。

**会破坏我原有的 Claude Desktop 配置吗？** 不会。它在原有条目旁边新增一条，
从不改写别人的条目。

**需要 sudo 或管理员权限吗？** 不需要。

**为什么不直接用 `inferenceGatewayApiKey`？** 那会把 Token 明文写进文件，
把配置绑死在一台机器的安全存储上，并且让这个文件不适合分享或贴到 issue 里；
换 Token 还得重装。

**支持 Bedrock / Vertex / Foundry 吗？** 本版本不支持。它面向 Anthropic 兼容的
HTTP Gateway。其他供应商需要的凭证，本工具没有安全的方式获取。

**我的网关没有 `/v1/models`。** 加 `--no-model-discovery`。
工具会提示「层级别名在官方文档中被描述为依赖模型发现」，因为这一交互尚无定论。

**文件都放在哪？**
macOS：`~/Library/Application Support/{Claude-3p/configLibrary,claude-desktop-provider-setup}`；
Windows：`%LOCALAPPDATA%\{Claude-3p\configLibrary,claude-desktop-provider-setup}`。

## 十二、已知限制

- **未在自动化流程中验证真实运行的 Claude Desktop。** 测试证明了文件处理、
  解析计划与 Helper 协议；「应用确实接受这份配置」是根据官方 schema 与
  随附代码推理得出的，不是自动启动验证的。第一次启动才是真正的验收。
- **当前 Windows 版本是 MSIX，数据目录被虚拟化。** 工具在运行时解析真实路径，
  并在应用尚未进入第三方模式时自行创建配置库；已在 Windows 10 22H2 上对
  Claude Desktop 6.28899.6.0 验证，见 `docs/research-findings.md` §7a。
- **端到端没有完成过一次真实模型请求**，因为测试机没有可达的网关。
  但应用确实以第三方模式启动，并读到了工具写入的配置。
- **只提供非 Anthropic 模型 ID 的网关无法指定具体模型。** Claude Desktop 会丢弃
  名称不指向 Anthropic 模型的条目，因此工具会省略 `inferenceModels`，
  改由应用自动发现模型列表。若要固定某个模型，网关侧必须提供 Anthropic 名称的路由别名。
  见 `docs/research-findings.md` §7b。
- **`inferenceGatewayBaseUrl` 的校验规则未公开。** 工具原样透传，不追加 `/v1`。
- **模型发现与层级别名的交互官方未完全说明。**
- **只支持 `gateway` 供应商。**
- **不支持 Linux。**

## 十三、官方参考资料

- [第三方推理配置参考](https://claude.com/docs/third-party/claude-desktop/configuration.md)
- [配置实现与值类型](https://claude.com/docs/third-party/claude-desktop/configuration-format.md)
- [编写 Credential Helper](https://claude.com/docs/third-party/claude-desktop/credential-helper.md)
- [通过 MDM 部署](https://claude.com/docs/third-party/claude-desktop/mdm.md)
- [应用内配置](https://claude.com/docs/third-party/claude-desktop/in-app-configuration.md)
- [安装与设置](https://claude.com/docs/third-party/claude-desktop/installation.md)
- [数据存储](https://claude.com/docs/third-party/claude-desktop/data-storage.md)
- [Claude Code 设置与优先级](https://code.claude.com/docs/en/settings)
- [Claude Code 环境变量](https://code.claude.com/docs/en/env-vars)
- [迁移 Claude Code CLI 用户](https://support.claude.com/en/articles/18466061-move-claude-code-cli-users)

## 参与贡献

`src/common/SPEC.md` 是唯一事实来源。改动顺序：先改规范，再在
`tests/fixtures/common/` 下加用例，然后在两个平台上各实现一次。

```sh
bash tests/run-conformance.sh        # macOS
.\tests\run-conformance.ps1          # Windows
bash tools/sanitize-check.sh         # 推送前必跑
```

## 许可证

MIT，见 [LICENSE](LICENSE)。

本项目与 Anthropic 无隶属关系，也未获其背书。
