# Git Worktree Helpers
# Source in PowerShell profile: . "$env:USERPROFILE\.claude\scripts\worktree-helpers.ps1"
#
# Commands: gwt, gwta, wts, wtd, wtp, wtclean

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Internal utilities

function __wt_root {
    $root = git rev-parse --show-toplevel 2>$null
    if (-not $root) { throw "[wt] Not in a git repository" }
    $root
}

function __wt_branch_list {
    git worktree list --porcelain 2>$null |
        Select-String "^branch " |
        ForEach-Object { ($_.Line -replace "^branch refs/heads/", "").Trim() }
}

function __wt_ensure_ignored {
    param([string]$Root, [string]$Dir = ".worktrees")
    $gitignore = Join-Path $Root ".gitignore"
    $pattern = "$Dir/"

    if (Test-Path $gitignore) {
        $content = Get-Content $gitignore -Raw -ErrorAction SilentlyContinue
        if ($content -notmatch "(?m)^\.worktrees/$") {
            Add-Content $gitignore "`n$pattern"
            Write-Host "[wt] Added '$pattern' to .gitignore" -ForegroundColor Yellow
        }
    } else {
        $pattern | Out-File -FilePath $gitignore -Encoding utf8
        Write-Host "[wt] Created .gitignore with '$pattern'" -ForegroundColor Yellow
    }
}

#endregion

# gwt — list all worktrees with branch info
function gwt {
    [CmdletBinding()]
    param()
    git worktree list
}

# gwta — create a worktree
# Usage: gwta auth-jwt          → feat/auth-jwt
#        gwta fix/null-check    → fix/null-check (slash prefix auto-detected)
#        gwta null-check -Type fix
function gwta {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, HelpMessage = "Name (e.g. 'auth-jwt') or prefixed (e.g. 'fix/null-check')")]
        [string]$Name,

        [Parameter(Position = 1)]
        [ValidateSet("feat", "fix", "chore", "docs", "refactor", "test", "ci")]
        [string]$Type = "feat"
    )

    $ErrorActionPreference = "Stop"
    $root = __wt_root

    # Support gwta fix/null-check — extract type from slash prefix
    if ($Name -match "^(feat|fix|chore|docs|refactor|test|ci)/(.+)$") {
        $Type = $Matches[1]
        $Name = $Matches[2]
    }

    $branch = "$Type/$Name"
    $wtPath = Join-Path $root ".worktrees" $branch

    __wt_ensure_ignored -Root $root

    $parent = Split-Path $wtPath -Parent
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force $parent | Out-Null
    }

    Write-Host "[wt] Creating branch '$branch' at $wtPath" -ForegroundColor Cyan
    git worktree add $wtPath -b $branch

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[wt] Entering $wtPath" -ForegroundColor Green
        Set-Location $wtPath
    }
}

# wts — interactive worktree switcher (fzf if installed, Out-GridView fallback)
function wts {
    [CmdletBinding()]
    param()

    $entries = git worktree list 2>$null
    if (-not $entries) { Write-Host "[wt] No worktrees found"; return }

    $items = $entries | ForEach-Object {
        if ($_ -match "^(\S+)\s+(\S+)\s+(.+)$") {
            [PSCustomObject]@{
                Path   = $Matches[1]
                Commit = $Matches[2]
                Branch = $Matches[3] -replace "[\[\]]", ""
            }
        }
    } | Where-Object { $_ }

    if (Get-Command fzf -ErrorAction SilentlyContinue) {
        $display = $items | ForEach-Object { "$($_.Branch.PadRight(40)) $($_.Path)" }
        $selected = $display | fzf --prompt="worktree> " --height=40% --reverse --ansi
        if ($selected) {
            $path = ($selected -split "\s+", 2)[1].Trim()
            Set-Location $path
            Write-Host "[wt] Switched to $path" -ForegroundColor Green
        }
    } else {
        $selected = $items | Out-GridView -Title "Select Worktree" -OutputMode Single
        if ($selected) {
            Set-Location $selected.Path
            Write-Host "[wt] Switched to $($selected.Path)" -ForegroundColor Green
        }
    }
}

# wtd — remove a worktree and delete its branch
function wtd {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Branch,

        [switch]$Force,
        [switch]$KeepBranch
    )

    $root = __wt_root
    $wtPath = Join-Path $root ".worktrees" $Branch

    if (-not (Test-Path $wtPath)) {
        # Try matching from worktree list directly
        $match = (git worktree list --porcelain 2>$null | Select-String -Pattern "worktree (.+)" |
            Where-Object { $_.Matches[0].Groups[1].Value -like "*$Branch*" } |
            Select-Object -First 1)
        if ($match) { $wtPath = $match.Matches[0].Groups[1].Value }
        else { Write-Error "[wt] Worktree for '$Branch' not found"; return }
    }

    if ($PSCmdlet.ShouldProcess($wtPath, "Remove worktree")) {
        $removeArgs = @($wtPath)
        if ($Force) { $removeArgs = @("--force") + $removeArgs }
        git worktree remove @removeArgs

        if ($LASTEXITCODE -eq 0 -and -not $KeepBranch) {
            git branch -d $Branch 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "[wt] Branch '$Branch' has unmerged commits. Use 'git branch -D $Branch' to force."
            }
        }
    }
}

# wtp — prune stale worktree admin files and fetch prune remote refs
function wtp {
    [CmdletBinding()]
    param()
    Write-Host "[wt] Pruning worktree metadata..." -ForegroundColor Cyan
    git worktree prune -v
    Write-Host "[wt] Fetching + pruning remote refs..." -ForegroundColor Cyan
    git fetch --prune
}

# wtclean — remove all worktrees whose branches are merged into main/master
function wtclean {
    [CmdletBinding()]
    param()

    $mainBranch = git symbolic-ref --short refs/remotes/origin/HEAD 2>$null
    if (-not $mainBranch) { $mainBranch = "origin/main" }

    $merged = git branch --merged ($mainBranch -replace "origin/", "") 2>$null |
        ForEach-Object { $_.Trim() -replace "^\* ", "" } |
        Where-Object { $_ -notin @("main", "master", "develop", "HEAD", "") }

    if (-not $merged) {
        Write-Host "[wt] No merged branches to clean up" -ForegroundColor Green
        return
    }

    Write-Host "[wt] Merged branches eligible for cleanup:" -ForegroundColor Yellow
    $merged | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkYellow }

    $confirm = $Host.UI.PromptForChoice(
        "[wt] Confirm cleanup",
        "Remove these worktrees and branches?",
        @(
            [System.Management.Automation.Host.ChoiceDescription]::new("&Yes", "Remove all listed")
            [System.Management.Automation.Host.ChoiceDescription]::new("&No", "Cancel")
        ),
        1
    )

    if ($confirm -eq 0) {
        $merged | ForEach-Object {
            try { wtd -Branch $_ -Force } catch { Write-Warning "[wt] Could not remove '$_': $_" }
        }
        wtp
    }
}

#region Argument Completers

# Tab-complete branch names for wtd
Register-ArgumentCompleter -CommandName wtd -ParameterName Branch -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    __wt_branch_list 2>$null |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object {
            $display = $_
            $completion = if ($_ -match "/") { "'$_'" } else { $_ }
            [System.Management.Automation.CompletionResult]::new(
                $completion, $display, 'ParameterValue', $display
            )
        }
}

# Tab-complete -Type for gwta
Register-ArgumentCompleter -CommandName gwta -ParameterName Type -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete)
    @("feat", "fix", "chore", "docs", "refactor", "test", "ci") |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
}

#endregion

Write-Host "[wt] Worktree helpers loaded: gwt, gwta, wts, wtd, wtp, wtclean" -ForegroundColor DarkGray
