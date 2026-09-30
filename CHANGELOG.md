# CHANGELOG

版本节奏：**骨架（`memory-template/`）单独记版本** —— 骨架版本写在 `memory-template/AGENTS.md` 首行的
机器可读标记里（`<!-- memory-skeleton: v1.1 -->`）；初始化到项目后，`init-memory.ps1` 与
`check-memory.ps1` 会提示「目标骨架 vs 当前模板」的版本差，是否合并由你决定（脚本不自动改记忆）。

## [1.1.0] - 2026-09-29

### 新增

- **`check-memory.ps1`**：只读回归脚本（第三个脚本），9 项机械检查 —— ① 索引表 ↔ `knowledge/` 一对一；
  ② `AGENTS.md` 行数上限；③ 非 BMP 字符；④ `status/` 新鲜度与「已闭环」未清理；⑤ 悬空引用
  （**文件 + 小节锚点，不看行号**）；⑥ 忽略规则过宽 / 记忆是否真的被忽略；⑦ 仓库级 Skill 是否静默未入库；
  ⑧ `-Backup` 快照（唯一的写操作，写进 `.agents/memory/.backup/`）；⑨ 入库文件不得引用本机专属目录。
  退出码 `0` 无错误 / `1` 有错误（`-Strict` 时警告也算）/ `2` 没找到骨架。
- **`install.ps1 -Check`**：只读比对运行时副本与源的 SHA256，有漂移以退出码 1 结束。
- **`init-memory.ps1 -IgnoreTarget gitignore|exclude|none`**：忽略规则可写进 `.git/info/exclude`
  （本机专用、永不入库）或不写任何规则。
- `CHANGELOG.md`（本文件）+ 骨架版本标记 `memory-skeleton: v1.1`。
- **项目级门槛覆盖**：`AGENTS.md` 里写 `<!-- memory-check: max-agents-lines=130 -->` 或
  `<!-- memory-check: stale-days=14 -->`，`check-memory.ps1` 会按项目自定的阈值检查
  （命令行 `-MaxAgentsLines` / `-StaleDays` 仍可临时覆盖）。用于「入口确实需要更长」这类**有意放宽**，
  门槛与理由都留在项目自己的记忆里，而不是悄悄超标。
- `_local/` 本机私有区（`.gitignore` 已忽略）：kit 自身的评审稿 / 草稿 / 一次性材料。

### 变更

- `memory-hygiene`：新增「会话开始 / 改完记忆先跑 `check-memory`」；「跨会话任务状态 vs 项目内 `status/`」
  的分工判据；「引用写小节锚点、不写行号」；明确机械检查归脚本、本技能只管「内容对不对」。
- `init-memory.ps1`：过宽规则检查现在同时看 `.gitignore` 与 `.git/info/exclude`；若目标已有骨架，
  提示版本差。
- 三个 `.ps1` 带 **UTF-8 BOM** —— Windows PowerShell 5.1 与 PowerShell 7 都能跑；
  **写出来的内容文件仍然是「无 BOM」UTF-8**。
- 文档：`README.md` / `TUTORIAL.md` 补三个脚本分工与 `check-memory` 用法；命名统一为
  「用户级 Skill 目录（`~/.agents/skills/`）」与「项目级记忆目录（`<repo>/.agents/memory/`）」。
- `check-memory.ps1` 四处误报/噪声修正（消费者实测发现）：
  ④ 的「已闭环」只看**状态字段**（`状态: 已闭环`），不再把正文里提到该词的引用当状态；
  ⑤ 「否定语境」扩充到「删除 / 删掉 / 弃用」等记录性失效（例：「**删除** `旧文件.md`」不再算悬空引用）；
  ⑤ 「锚点只命中正文」不再逐条刷屏，改为一行汇总（最多列 3 个例子）；
  ⑦ 若 `.agents/skills/` 是被**点了名的**规则忽略（例 `.agents/skills/`），算「有意忽略」只提示，
  不再报 FAIL（裸 `.agents` 那种过宽规则仍由 ⑥ + ⑦ 报错）。

### 骨架（`memory-template/`）

- **v1.1**：首行加机器可读版本标记；维护提示补「引用写小节标题、不写行号」与「标记行不要删」。
- v1.0：`AGENTS.md` + `.agents/memory/{knowledge,status}`（早期版本曾把 `knowledge/`、`status/`
  写到项目根，迁移见 `TUTORIAL.md` FAQ Q11）。

## [1.0.0] - 2026-09-24

### 新增

- 骨架模板 `memory-template/`（`AGENTS.md` + `knowledge×6` + `status×1`）。
- `memory-hygiene` Skill：分层判据（「会不会过期」三问 + 反向判据）/ 格式纪律 / 生命周期 /
  五种腐烂自查表。
- `install.ps1`（镜像部署 + 标记文件来源保护 + `-Prune`）、`init-memory.ps1`
  （绝不覆盖 + `-Force` 先备份；含模板布局守卫）。
- `README.md`（为什么这样设计）、`TUTORIAL.md`（从零到日常 + 排错速查 + FAQ）。
