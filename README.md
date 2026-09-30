# agent-memory-kit

给 AI 编码助手（Cline / GitHub Copilot）用的**项目记忆体系** —— 一套让 AI「记住项目规则」的目录约定、初始化脚本与维护判据。

**核心问题**：AI 每开一个新会话都从零开始。你把规则写进聊天里，下次它就忘了；写在代码注释里，又找不到。这个 kit 提供一套**分层存放规则**的骨架，让两个 agent 都能自动读到。

> **第一次用？** 直接看 [`TUTORIAL.md`](TUTORIAL.md) —— 从安装到日常使用、多项目共存与 FAQ。
> 本文件讲「为什么这么设计」。

---

## 它解决什么（以及不解决什么）

| 解决                                      | 不解决             |
| ----------------------------------------- | ------------------ |
| 项目规则放在哪、怎么分层                  | 不替你写规则内容   |
| 「这条信息该不该记、记到哪一层」的判据    | 不做向量检索 / RAG |
| 跨 agent 共享（Cline + Copilot 读同一份） | 不绑定任何框架     |
| 记忆的防腐（升级 / 回收 / 自查）          | 不需要数据库或服务 |

---

## 快速开始

两个脚本职责不同（区别见下表），所以按「拿到 kit → 装 Skill → 搭骨架」三步来：

```powershell
# 0. 先拿到 kit（只做一次；已有副本就直接用它，别再 clone 第二份）
git clone https://github.com/luoxiwhyye/agent-memory-kit.git D:\tools\agent-memory-kit
cd D:\tools\agent-memory-kit

# 1. 在 kit 目录里装一次 Skill（全机器共享，所有项目共用这一份）
pwsh -File ./install.ps1 -List
pwsh -File ./install.ps1

# 2. 在每个项目里搭记忆骨架（只写该项目内部，先预览）
pwsh -File <kit路径>/init-memory.ps1 -Path D:\code\MyApp -Project MyApp -List
pwsh -File <kit路径>/init-memory.ps1 -Path D:\code\MyApp -Project MyApp
```

> 后两步都建议先跑 `-List` 预览。装完 / 搭完记得**重载窗口**（`Developer: Reload Window`）。

生成：

```
<你的项目>/
├── AGENTS.md                        # 入口：两个 agent 都会自动读
└── .agents/memory/
    ├── knowledge/                   # ① 项目知识（长期有效）
    │   ├── conventions.md           # 约定 / 命名 / 唯一实现
    │   ├── backend.md               # 接口 / 数据 / 鉴权契约（按需）
    │   ├── deploy.md                # 部署 / 发布 / 恢复（按需）
    │   ├── pitfalls.md              # 环境与工具坑
    │   ├── verify.md                # 可复用验证手段
    │   └── log.md                   # 历史流水（详细版）
    └── status/
        └── ops.md                   # ② 个人状态（会过期，闭环后当天删）
```

这是**默认集合，不是必须全有**：`backend.md` / `deploy.md` 各自对应一个业务前提
（有服务端或数据层 / 要上线），不满足就删掉文件与 `AGENTS.md` 索引表里的对应行 ——
两处要一起改，否则入口会指向不存在的文件。

然后**填 `AGENTS.md` 的「结构与启动」「高频铁律」两节**，其余留空即可 —— 它在使用过程中自然长出来。

> ⚠️ 运行后需**重载编辑器窗口**（`Developer: Reload Window`），agent 才会发现 `AGENTS.md`。

---

## 分层判据（这个 kit 的核心）

不是「按重要性分」，而是**按「会不会过期」分**：

```
① 它描述「东西是什么样」，还是「我做到哪了」？
   前者 = 项目知识（长期）      后者 = 个人状态（会过期）

② 这个项目暂停半年后，这条还成立吗？
   成立 = 项目知识              失效 = 个人状态

③ 别处已经有了吗？（代码 / git log / 项目文档）
   有 = 不写，最多留一行指针
```

**反向判据**（什么时候必须写）：

```
「下一次对话没有它，我就会做错事」 → 必须写
「它只是当时怎么做的」            → 不写（git 与代码已经是记录）
```

三个层次的生命周期：

```
流水（log.md）里的结论
      ↓ 当它变成「以后每次都要遵守」
规则（conventions / pitfalls / …）    ← 搬家，不是复制；原地留一行指针
      ↓ 当它变成「每轮都必须知道」
入口（AGENTS.md）                     ← 只留一行，详情仍在子文件
```

---

## 为什么这样放能被两个 agent 读到

| 文件                               | Cline        | Copilot      |
| ---------------------------------- | ------------ | ------------ |
| `<repo>/AGENTS.md`                 | ✅           | ✅           |
| `<repo>/.agents/skills/*/SKILL.md` | ✅           | ✅           |
| `<repo>/.agents/memory/**`         | ✅（按需读） | ✅（按需读） |

`AGENTS.md` 是**跨 agent 的事实标准**（Copilot 同时认 `AGENTS.md` 与 `CLAUDE.md`，Cline 也认它）。

**默认不入库**：`init-memory.ps1` 会把这三个模式写进忽略规则 ——

```gitignore
/AGENTS.md          # 入口文件
.agents/memory/     # 记忆目录（精确到 memory/，不影响 .agents/skills/）
.clineignore        # Cline 的本机忽略规则
```

写到哪里由 `-IgnoreTarget` 决定（规则内容相同）：

| 模式 | 写进 | 什么时候用 |
| :--- | :--- | :--- |
| `gitignore`（默认） | 项目 `.gitignore` | 希望 clone 你项目的人也能看到这三行（规则对协作者可见） |
| `exclude` | `.git/info/exclude` | **不想在仓库里留痕**（本机专用、永不入库）；换机器 / 新克隆要重配一次 |
| `none` | 不写任何规则 | 自己管忽略规则；`check-memory.ps1` 会提示「记忆可能被提交」 |

```powershell
pwsh -File <kit路径>/init-memory.ps1 -Path D:\code\MyApp -IgnoreTarget exclude
```

想让**仓库级 Skill 也不入库**（第三方 Skill 包、各自带 LICENSE 时常见）：加 `-IgnoreSkills` ——
它会把 `.agents/skills/` 写进忽略，并附一行理由注释（以后要共享，删掉那行即可）。

它们是**本机 AI 约定**，通常不该出现在给别人 clone 的公共仓库里。而两个 agent 读它们走的是
**文件读取，不受忽略规则影响**（已核实 Cline 的规则路径是显式拼出来的）。

> 忽略规则**刻意精确到 `.agents/memory/`** —— 这样 `<项目>/.agents/skills/`（仓库级 Skill）
> 仍可入库、与团队共享。早期版本写的是裸 `.agents`，会连它一起忽略掉；
> 脚本现在会**检测并警告**这种过宽规则，但不会替你改 `.gitignore`（那是你的文件）。
>
> 反过来，让**记忆**入库也是可行的：把 `.agents/memory/status/` 排掉即可 ——
> 长期知识（约定 / 坑 / 验证手段）团队共享，「此刻做到哪了」仍是你自己的。
> 一开始就想要这个形态：用 `-IgnoreTarget none` 初始化，再手工加这条规则。

---

## 内容

```
skills/
└── memory-hygiene/SKILL.md     # 记忆的分层判据与维护流程（把它交给 agent）
memory-template/                # 骨架本体，不含任何项目内容
├── AGENTS.md                   #   ← 落在目标项目的根目录
└── .agents/memory/             #   ← 与目标布局**逐层对应**，脚本只做纯复制
    ├── knowledge/
    └── status/
install.ps1                     # 把 skills/ 部署到 ~/.agents/skills/（-Check 只比哈希）
init-memory.ps1                 # 在目标项目初始化记忆骨架
check-memory.ps1                # 只读回归：校验项目记忆骨架有没有烂
TUTORIAL.md                     # 教程：安装 / 多项目共存 / 日常使用 / FAQ
CHANGELOG.md                    # 版本变更（骨架版本单独记）
_local/                         # 本机私有区（不入库）：kit 自身的评审稿 / 草稿 / 一次性材料
```

> `memory-template/` 的结构**就是**目标项目的结构 —— 所以其它平台直接手工复制它也是对的，
> 不会出现「复制到错位置」。脚本会校验这一点，模板被改扁时直接报错退出。

### 脚本分工（三个脚本，各只做一件事）

前两个脚本的区别（重要）：

|          | `install.ps1`                                                       | `init-memory.ps1`                                 |
| -------- | ------------------------------------------------------------------- | ------------------------------------------------- |
| 作用     | 把 Skill 复制到运行时目录                                           | 在项目里搭记忆骨架                                |
| 作用域   | **全机器共享**（`~/.agents/skills/`）                               | **仅目标项目内部**                                |
| 冲突策略 | **镜像**（源删了，目标也删）                                        | **绝不覆盖**（记忆填过就是用户内容）              |
| 为什么   | Skill 是源文件                                                      | 记忆是用户内容                                    |
| 多副本   | 按标记文件里的**安装来源**判定：不是本仓库装的不动，`-Force` 可接管 | 天然互不影响（各写各的项目）                      |
| `-Prune` | 只删**本仓库**安装的、且源里已删的 Skill                            | 无此选项                                          |
| `-Force` | 接管运行时目录里别的副本装的 Skill                                  | 覆盖与模板不同的文件（先备份为 `*.bak-<时间戳>`） |

两者都**幂等**，都可 `-List` 预览。它们**只管「建」和「装」**；骨架用久了会不会烂，由下面这个脚本回答。

### `check-memory.ps1`：日常回归（第三个脚本，只读）

```powershell
pwsh -File <kit路径>/check-memory.ps1 -Path D:\code\MyApp     # 只读体检
pwsh -File <kit路径>/check-memory.ps1 -Backup                 # 整理前先落快照（唯一的写操作）
pwsh -File <kit路径>/check-memory.ps1 -Strict                 # 有警告也算失败（收尾 / CI）
```

**检查项清单的唯一来源是 `check-memory.ps1` 头部注释**（下面是速览；要改检查项请先改那里）：

| 组 | 检查 |
| :--- | :--- |
| 结构与体量 | ① 索引表 ↔ `knowledge/` · `status/` 一对一；② `AGENTS.md` 行数上限 |
| 内容卫生 | ③ 非 BMP 字符；④ `status/` 新鲜度与形态（过期 / `状态: 已闭环` / 「更像日志」） |
| 引用 | ⑤ 悬空引用（**文件 + 小节锚点，不看行号**；只查反引号内；`文件:行` 报 WARN；行内 `[已失效]` 按标注处理） |
| 环境与入库 | ⑥ 忽略规则（过宽 / 记忆与入口是否真被忽略）；⑦ 仓库级 Skill 入库状态；⑧ `-Backup` 快照；⑨ 入库文件不得引用本机专属目录（在 kit 自身仓库里跳过） |

退出码：`0` 无错误 / `1` 有错误（`-Strict` 时警告也算）/ `2` 没找到记忆骨架。
`-Strict` 下另外两条也算失败：**存在 `memory-check:` 门槛覆盖**、**骨架版本落后于模板**。
它只做**机械可判定**的检查；「内容对不对、该不该写」仍归 `memory-hygiene`。

**项目可以自己放宽门槛**（写在自己的 `AGENTS.md` 里，检查器会读；命令行参数仍可临时覆盖）。
**理由要写在同一个注释块里** —— 只有 `key=value` 而没写理由会被判 WARN：

```markdown
<!-- memory-check: max-agents-lines=130
     入口确实需要更长：§1 表是唯一的结构索引，压到 100 行会丢掉定位信息 -->
<!-- memory-check: stale-days=14
     status 只在发版前更新，14 天更贴近实际节奏 -->
<!-- memory-check: max-status-lines=120
     status 天然偏长（运维台账），120 行是这台机器实测的合理线 -->
```
（`max-status-lines=0` = 关闭 status 的形态检查。）

> **多项目不冲突**：`init-memory.ps1` 只写目标项目内部，所以对多少个项目分别执行都互不影响；
> 唯一共享的是运行时 Skill 目录，而它现在有来源保护。详见 [`TUTORIAL.md`](TUTORIAL.md) 第 3 节。

### 为什么只有 `memory-hygiene` 一个 Skill

本 kit 只做一个关注点：**项目记忆**。
「跨会话恢复在手任务」是另一个关注点（它需要个人任务状态目录），刻意不包含在内 ——
混在一起会让两边都变复杂。如果你需要，可以照本 kit 的骨架自己写一个 Skill。

---

## 目录约定说明

- **子文件按主题拆，不按项目名命名** —— 所以叫 `pitfalls.md` 而不是 `myapp-pitfalls.md`，
  换项目时骨架能直接复制。
- **每个子文件头部写明层与读取时机**：`> 层：**项目知识**（长期有效，与谁在做无关）`。
- **模板里的 `例：…` 是「形式」不是「内容」** —— 它们故意跨领域（前端 / 服务端 / 数据 / 运维 / CLI），
  并用 `<某能力>` 这类占位符写。照抄会跑偏，换成你项目的主题；用不到的小节删掉。
- **按需增删子文件**：骨架给的是默认集合，不用的文件与 `AGENTS.md` 索引表里的对应行**一起删**。
- **不要在 `AGENTS.md` 里堆内容** —— 它每次对话都会被加载，建议 ≤100 行，超出的推到子文件。
- **`_local/` 是本仓库自己的「本机私有区」**（`.gitignore` 里已忽略）：kit 的评审稿、草稿、含真实路径的
  一次性说明放这里，永不入库。判断口径和记忆一致 —— **不确定要不要公开的，先放 `_local/`**；
  确认可公开再移出，并去掉本机路径与第三方信息。它只服务于「维护 kit 自身」，
  与用 kit 给项目搭骨架无关（所以 `TUTORIAL.md` 里不出现它）。

---

## 已知取舍

- **依赖 `AGENTS.md` 被 agent 读到**：如果你用的 agent 不认这个文件，改用其原生规则位置
  （Cline 的 `.clinerules/`、Copilot 的 `.github/copilot-instructions.md`），骨架结构照旧可用。
- **没有自动清理**：`status/` 的回收靠纪律（闭环后当天删），没有工具强制。
  `memory-hygiene` Skill 里有一张「五种腐烂方式」自查表用来定期体检。
- **三个脚本都是 PowerShell（Windows 优先）**：`init-memory.ps1` / `install.ps1` / `check-memory.ps1`。
  脚本自身带 UTF-8 BOM，所以 **PowerShell 7（`pwsh`）与 Windows PowerShell 5.1（`powershell`）都能跑**；
  它们**写出来**的内容文件（记忆 / 骨架）一律是**无 BOM** 的 UTF-8。
  骨架本身（目录 + Markdown）与平台无关 —— 其它平台直接手工复制 `memory-template/` 即可
  （它的结构与目标布局逐层对应，不会复制错位置）。
- **不替你定领域**：骨架本身与语言 / 框架无关，模板里的小节是**按需启用**的形式示例；
  子文件可以自由增删（约定就是文件 + `AGENTS.md` 索引表一处同步）。
- **不管 multi-root 工作区**：同一窗口开了多个项目时，多个 `AGENTS.md` 都可能被加载，
  规则会串。建议一次只开一个项目，或在各自 `AGENTS.md` 顶部注明适用范围。
- **中文为主**：模板与 Skill 用中文书写。骨架结构本身与语言无关。
- **骨架版本与升级**：骨架版本写在 `memory-template/AGENTS.md` 首行的机器可读标记里
  （`<!-- memory-skeleton: v1.1 -->`），仓库级变更见 [`CHANGELOG.md`](CHANGELOG.md)
  ——**每个骨架版本都带「迁移动作」**。`init-memory.ps1`（跑的时候）与 `check-memory.ps1`（每次体检）
  都会提示「目标骨架 vs 当前模板」的版本差，并指向迁移动作 —— **是否合并由你决定，脚本不自动改记忆**。
