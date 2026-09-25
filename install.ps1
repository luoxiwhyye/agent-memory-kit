<#
.SYNOPSIS
    把本仓库 skills/ 下的 Skill 复制部署到运行时目录，让 agent 能加载它们。

.DESCRIPTION
    源：      <本仓库>\skills\
    运行时：  %USERPROFILE%\.agents\skills\   （agent 实际加载 Skill 的位置）

    本脚本 **幂等**：可反复执行，不会产生重复文件。
    策略是「按源镜像目标」—— 复制新增与变更的文件，删除目标里多出来的旧文件。

    ⚠️ 运行时目录是**全机器共享**的：所有项目共用同一份 Skill。
    为避免多份 kit 副本互相覆盖，每个已安装的 Skill 目录里有一个标记文件，
    记录它的**安装来源**（源绝对路径）。据此：

      - 目标里的 Skill 来自**另一个** kit 副本（或不是本脚本装的）
        → 默认**跳过不动**并提示，避免把别人的安装覆盖掉；
      - `-Prune` 只删除**本仓库**安装的、且源里已不存在的 Skill，
        不会碰别人装的、也不会碰你手工放置的。

    想强制让本仓库接管某个 Skill，用 `-Force`（会覆盖运行时副本并改写标记）。

.PARAMETER Prune
    额外删除「已部署但源里已不存在」的 Skill 目录 —— 仅限**本仓库安装**的。

.PARAMETER List
    只列出将要发生的变更，不写入任何文件。

.PARAMETER Force
    接管运行时目录里「来源不是本仓库」的同名 Skill（覆盖 + 改写标记）。
    平时不需要；只在确认另一份 kit 副本已废弃时使用。

.EXAMPLE
    pwsh -File install.ps1
    pwsh -File install.ps1 -List
    pwsh -File install.ps1 -Prune
    pwsh -File install.ps1 -Force

.NOTES
    Windows 上创建目录符号链接需要管理员或开发者模式，所以这里用复制而非 symlink。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Prune,
    [switch]$List,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$Marker = '.installed-by-agent-memory-kit'
$SourceRoot = Join-Path $PSScriptRoot 'skills'
$DestRoot = Join-Path $env:USERPROFILE '.agents\skills'

function Write-Step($msg) { Write-Host $msg }
function Write-Item($tag, $path) {
    $color = switch ($tag) { '+' { 'Green' } '-' { 'Red' } '~' { 'Yellow' } default { 'Gray' } }
    Write-Host ("  {0} {1}" -f $tag, $path) -ForegroundColor $color
}

# 读标记文件里记录的安装来源（Skill 目录的绝对路径）；$null = 无标记文件
function Get-MarkerSource($skillDir) {
    $mp = Join-Path $skillDir $Marker
    if (-not (Test-Path -LiteralPath $mp)) { return $null }
    $m = [regex]::Match([IO.File]::ReadAllText($mp), '(?m)^\s*源[:：]\s*(.+?)\s*$')
    if (-not $m.Success) { return '' }
    return $m.Groups[1].Value.Trim()
}

# ours = 本仓库安装的；other = 另一份 kit 副本安装的；unknown = 有标记但读不出来源；foreign = 无标记（非本脚本安装）
function Test-SkillOwnership($skillDir) {
    $src = Get-MarkerSource $skillDir
    if ($null -eq $src) { return 'foreign' }
    if ($src -eq '') { return 'unknown' }
    $root = Split-Path -Parent $src
    if ($root -and ($root -eq $SourceSkillsFull)) { return 'ours' }
    return 'other'
}

function Get-OwnershipReason($skillDir) {
    switch (Test-SkillOwnership $skillDir) {
        'other' { "已由另一份 kit 副本安装（$((Get-MarkerSource $skillDir))）" }
        'unknown' { '标记文件存在但读不出安装来源' }
        'foreign' { '不是本脚本安装的（无标记文件）' }
        default { '来源不明' }
    }
}

if (-not (Test-Path -LiteralPath $SourceRoot)) {
    Write-Host "找不到源目录：$SourceRoot" -ForegroundColor Red
    exit 1
}
$SourceSkillsFull = (Resolve-Path -LiteralPath $SourceRoot).Path

if (-not (Test-Path -LiteralPath $DestRoot)) {
    if ($List) { Write-Host "（将创建）$DestRoot" -ForegroundColor Yellow }
    elseif ($PSCmdlet.ShouldProcess($DestRoot, '创建运行时 Skill 目录')) {
        New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null
        Write-Step "已创建 $DestRoot"
    }
}

$sourceSkills = Get-ChildItem -LiteralPath $SourceRoot -Directory
$destSkills = if (Test-Path -LiteralPath $DestRoot) { Get-ChildItem -LiteralPath $DestRoot -Directory } else { @() }

$changedFiles = 0
$unchangedFiles = 0
$processedSkills = @()
$skippedSkills = @()

foreach ($skill in $sourceSkills) {
    $processedSkills += $skill.Name
    $destDir = Join-Path $DestRoot $skill.Name
    $srcFiles = Get-ChildItem -LiteralPath $skill.FullName -Recurse -File

    # ---------- 归属检查：不动别人的安装 ----------
    $owner = if (Test-Path -LiteralPath $destDir) { Test-SkillOwnership $destDir } else { 'none' }
    if (($owner -ne 'none') -and ($owner -ne 'ours') -and (-not $Force)) {
        Write-Step ("  ! {0} —— 跳过：{1}" -f $skill.Name, (Get-OwnershipReason $destDir))
        Write-Host "      如需本仓库接管：pwsh -File install.ps1 -Force（会覆盖该 Skill 的运行时副本）" -ForegroundColor DarkGray
        $skippedSkills += [pscustomobject]@{ Name = $skill.Name; Reason = (Get-OwnershipReason $destDir) }
        continue
    }

    $skillChanges = @()
    foreach ($f in $srcFiles) {
        $rel = $f.FullName.Substring($skill.FullName.Length).TrimStart('\', '/')
        $target = Join-Path $destDir $rel
        $same = (Test-Path -LiteralPath $target) -and
                ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq
                 (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash)
        if ($same) { $unchangedFiles++; continue }

        $tag = if (Test-Path -LiteralPath $target) { '~' } else { '+' }
        $skillChanges += [pscustomobject]@{ Tag = $tag; Rel = $rel; Src = $f.FullName; Dst = $target }
    }
    # 目标里多出来的文件（源已删）——镜像掉，避免陈旧副本被加载
    if (Test-Path -LiteralPath $destDir) {
        foreach ($df in (Get-ChildItem -LiteralPath $destDir -Recurse -File)) {
            $rel = $df.FullName.Substring($destDir.Length).TrimStart('\', '/')
            if ($rel -eq $Marker) { continue }
            if (-not (Test-Path -LiteralPath (Join-Path $skill.FullName $rel))) {
                $skillChanges += [pscustomobject]@{ Tag = '-'; Rel = $rel; Src = $null; Dst = $df.FullName }
            }
        }
    }

    # 标记文件的内容是否还需要（重）写：缺失、读不出、或来源不是本仓库
    $markerPath = Join-Path $destDir $Marker
    $needMarker = $true
    if (Test-Path -LiteralPath $markerPath) {
        $src = Get-MarkerSource $destDir
        $needMarker = ($null -eq $src) -or ($src -eq '') -or ((Split-Path -Parent $src) -ne $SourceSkillsFull)
    }

    if ($skillChanges.Count -eq 0) {
        if ($needMarker -and (Test-Path -LiteralPath $destDir)) {
            Write-Step ("  ~ {0}（内容已是最新，补写安装标记以标明归属）" -f $skill.Name)
            $changedFiles++
            if (-not $List -and $PSCmdlet.ShouldProcess($markerPath, '写标记')) {
                $content = "由 agent-memory-kit/install.ps1 安装`n源：$($skill.FullName)`n请勿手工编辑，改源文件后重新运行 install.ps1。`n"
                [IO.File]::WriteAllText($markerPath, $content, [Text.UTF8Encoding]::new($false))
            }
        } else {
            Write-Step ("= {0}（已是最新）" -f $skill.Name)
        }
        continue
    }

    Write-Step ("  {0}" -f $skill.Name)
    foreach ($c in $skillChanges) {
        Write-Item $c.Tag (Join-Path $skill.Name $c.Rel)
        if ($List -or $c.Tag -eq '-') { continue }
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        $parent = Split-Path -Parent $c.Dst
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        if ($PSCmdlet.ShouldProcess($c.Dst, '复制')) { Copy-Item -LiteralPath $c.Src -Destination $c.Dst -Force }
    }
    $changedFiles += $skillChanges.Count

    # 删除源已移除的文件（镜像策略）
    if (-not $List) {
        foreach ($c in ($skillChanges | Where-Object Tag -eq '-')) {
            if ($PSCmdlet.ShouldProcess($c.Dst, '删除')) { Remove-Item -LiteralPath $c.Dst -Force }
        }
    }

    # 标记文件：既是安装凭证（记录来源），也让 -Prune 有据可依
    if ($needMarker -and (-not $List) -and $PSCmdlet.ShouldProcess($markerPath, '写标记')) {
        $content = "由 agent-memory-kit/install.ps1 安装`n源：$($skill.FullName)`n请勿手工编辑，改源文件后重新运行 install.ps1。`n"
        [IO.File]::WriteAllText($markerPath, $content, [Text.UTF8Encoding]::new($false))
    }
}

# ---------- -Prune：只清理「本仓库安装的、源里已不存在」的 Skill ----------
if ($Prune) {
    foreach ($d in $destSkills) {
        if ($processedSkills -contains $d.Name) { continue }
        if ((Test-SkillOwnership $d.FullName) -ne 'ours') {
            $reason = Get-OwnershipReason $d.FullName
            Write-Host ("  跳过（{0}）：{1}" -f $reason, $d.Name) -ForegroundColor DarkGray
            $skippedSkills += [pscustomobject]@{ Name = $d.Name; Reason = $reason }
            continue
        }
        Write-Step ("  将移除已废弃的 Skill：{0}" -f $d.Name)
        $changedFiles++
        if (-not $List -and $PSCmdlet.ShouldProcess($d.FullName, '删除')) {
            Remove-Item -LiteralPath $d.FullName -Recurse -Force
        }
    }
}

# ---------- 汇总 ----------
Write-Host ''
if ($List) {
    Write-Host "（-List 模式，未写入任何文件）待变更：$changedFiles 个文件，已最新：$unchangedFiles 个文件。" -ForegroundColor Yellow
} else {
    if ($changedFiles -eq 0) {
        Write-Host "已是最新：$unchangedFiles 个文件未变，无任何改动（幂等验证：重复执行无副作用）。" -ForegroundColor Green
    } else {
        Write-Host "完成：变更 $changedFiles 个文件，$unchangedFiles 个文件已是最新。" -ForegroundColor Green
    }
}

if ($skippedSkills.Count -gt 0) {
    Write-Host ''
    Write-Host ("⚠️ 跳过 {0} 个 Skill（不属于本仓库安装，未做任何改动）：" -f $skippedSkills.Count) -ForegroundColor Yellow
    foreach ($s in $skippedSkills) { Write-Host ("     {0} —— {1}" -f $s.Name, $s.Reason) -ForegroundColor Yellow }
    Write-Host '   运行时目录是全机器共享的：多个项目里各有一份 kit 时，只有最先安装的那份会生效。' -ForegroundColor DarkGray
    Write-Host '   建议只在一个固定位置维护 kit，其它项目只运行 init-memory.ps1（它不碰运行时目录）。' -ForegroundColor DarkGray
}

if (-not $List) {
    Write-Host "运行时副本：$DestRoot"
    Write-Host ''
    Write-Host '下一步：重载编辑器窗口（Developer: Reload Window），让 agent 发现新 Skill。' -ForegroundColor Cyan
}
