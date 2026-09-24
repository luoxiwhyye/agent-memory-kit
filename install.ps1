<#
.SYNOPSIS
    把本仓库 skills/ 下的 Skill 复制部署到运行时目录，让 agent 能加载它们。

.DESCRIPTION
    源：      <本仓库>\skills\
    运行时：  %USERPROFILE%\.agents\skills\   （agent 实际加载 Skill 的位置）

    本脚本 **幂等**：可反复执行，不会产生重复文件。
    策略是「按源镜像目标」—— 复制新增与变更的文件，删除目标里多出来的旧文件。
    只有本脚本安装过的 Skill 才带标记文件，`-Prune` 也只删除这些，
    避免误删你手工放置的其它 Skill。

.PARAMETER Prune
    额外删除「已部署但源里已不存在」的 Skill 目录（仅限带本脚本标记的）。

.PARAMETER List
    只列出将要发生的变更，不写入任何文件。

.EXAMPLE
    pwsh -File install.ps1
    pwsh -File install.ps1 -List
    pwsh -File install.ps1 -Prune

.NOTES
    Windows 上创建目录符号链接需要管理员或开发者模式，所以这里用复制而非 symlink。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Prune,
    [switch]$List
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

if (-not (Test-Path -LiteralPath $SourceRoot)) {
    Write-Host "找不到源目录：$SourceRoot" -ForegroundColor Red
    exit 1
}
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

foreach ($skill in $sourceSkills) {
    $processedSkills += $skill.Name
    $destDir = Join-Path $DestRoot $skill.Name
    $srcFiles = Get-ChildItem -LiteralPath $skill.FullName -Recurse -File

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

    if ($skillChanges.Count -eq 0) {
        Write-Step ("= {0}（已是最新）" -f $skill.Name)
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

    # 标记文件：既是安装凭证，也让 -Prune 有据可依
    $markerPath = Join-Path $destDir $Marker
    if (-not $List -and -not (Test-Path -LiteralPath $markerPath)) {
        $content = "由 agent-memory-kit/install.ps1 安装`n源：$($skill.FullName)`n请勿手工编辑，改源文件后重新运行 install.ps1。`n"
        if ($PSCmdlet.ShouldProcess($markerPath, '写标记')) {
            [IO.File]::WriteAllText($markerPath, $content, [Text.UTF8Encoding]::new($false))
        }
    }
}

# ---------- -Prune：清理源里已不存在的已部署 Skill ----------
if ($Prune) {
    foreach ($d in $destSkills) {
        if ($processedSkills -contains $d.Name) { continue }
        $markerPath = Join-Path $d.FullName $Marker
        if (-not (Test-Path -LiteralPath $markerPath)) {
            Write-Host ("  跳过（非本脚本安装）：{0}" -f $d.Name) -ForegroundColor DarkGray
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
    Write-Host "运行时副本：$DestRoot"
    Write-Host ''
    Write-Host '下一步：重载编辑器窗口（Developer: Reload Window），让 agent 发现新 Skill。' -ForegroundColor Cyan
}
