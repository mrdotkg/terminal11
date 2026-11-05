# =============================================================================
# Terminal 11 - turnkey, agent-native CLI environment for Windows
#
#   irm https://raw.githubusercontent.com/YOUR_GH_USER/terminal11/main/install.ps1 | iex
#
# What it does
#   * Creates a NEW Windows Terminal profile ("Terminal 11") + a dedicated PowerShell
#     profile script, and (optionally) makes it the default profile.
#   * NEVER touches your own $PROFILE files or your existing Windows Terminal profiles.
#     The only edit to Windows Terminal's settings.json is the single "defaultProfile"
#     line (backed up first, reverted by uninstall). Profile + color scheme are added
#     through a Windows Terminal "fragment" file, so your settings.json stays yours.
#   * Pure PowerShell 7. No PowerShell modules. No background service.
#   * Idempotent: safe to run again; it reuses your previous answers.
#
# Environment variables (use these because `irm | iex` cannot take parameters)
#   T11_YES=1            unattended: no prompts, use saved config (or recommended defaults)
#   T11_DRYRUN=1         show the summary of what would change, then stop
#   T11_ACTION=uninstall remove Terminal 11 (reverts default profile, removes fragment)
#   T11_URL=<url>        where this script lives (used for `t11 update`)
#
# Installer syntax is kept Windows PowerShell 5.1 compatible on purpose, so that
# running it from the stock "powershell" window can bootstrap PowerShell 7 first.
# Installer source is plain ASCII; all fancy glyphs are built from [char] codes.
# =============================================================================

& {
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$S = @{
    Version     = '0.2.0'
    Url         = $(if ($env:T11_URL) { $env:T11_URL } else { 'https://raw.githubusercontent.com/YOUR_GH_USER/terminal11/main/install.ps1' })
    Root        = Join-Path (Join-Path $HOME '.config') 'terminal11'
    Guid        = '{c0ffee11-7e11-4a11-b111-000000000011}'
    WinPsGuid   = '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}'
    Interactive = (-not [Console]::IsInputRedirected) -and (-not $env:T11_YES)
    Warn        = New-Object System.Collections.Generic.List[string]
}

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
function Say { param([string]$Text, [string]$Color = 'Gray') Write-Host $Text -ForegroundColor $Color }
function Ok { param([string]$Text) Write-Host ('  ' + [char]0x2713 + ' ') -NoNewline -ForegroundColor Green; Write-Host $Text }
function Warn { param([string]$Text) $S.Warn.Add($Text); Write-Host ('  ! ' + $Text) -ForegroundColor Yellow }
function Stage {
    param([string]$Name, [string]$Text)
    Write-Host ''
    Write-Host (' ' + $Name.PadRight(10) + ' ') -NoNewline -ForegroundColor Black -BackgroundColor DarkYellow
    Write-Host ('  ' + $Text) -ForegroundColor DarkYellow
}
function Show-Banner {
    $h = [string][char]0x2500; $v = [string][char]0x2502; $w = 56
    $left = '  TERMINAL 11'
    $right = 'NOW BOARDING  v' + $S.Version + '  '
    $pad = ' ' * [Math]::Max(1, $w - $left.Length - $right.Length)
    Write-Host ''
    Write-Host ('  ' + [char]0x250C + ($h * $w) + [char]0x2510) -ForegroundColor DarkYellow
    Write-Host ('  ' + $v) -NoNewline -ForegroundColor DarkYellow
    Write-Host $left -NoNewline -ForegroundColor Yellow
    Write-Host ($pad + $right) -NoNewline -ForegroundColor DarkYellow
    Write-Host $v -ForegroundColor DarkYellow
    Write-Host ('  ' + [char]0x2514 + ($h * $w) + [char]0x2518) -ForegroundColor DarkYellow
    Say '  Turnkey, agent-native CLI environment for Windows.' White
}
function Test-Cmd { param([string]$Name) return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }
function Update-SessionPath {
    $seen = @{}; $out = New-Object System.Collections.Generic.List[string]
    $all = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + $env:Path
    foreach ($p in ($all -split ';')) {
        if ($p -and -not $seen.ContainsKey($p.ToLowerInvariant())) { $seen[$p.ToLowerInvariant()] = 1; $out.Add($p) }
    }
    $env:Path = $out -join ';'
}
function Confirm-Step {
    param([string]$Question, [bool]$Default = $true)
    if (-not $S.Interactive) { return $Default }
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    Write-Host ('  ' + $Question + ' [' + $hint + '] ') -NoNewline
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter') { Write-Host ''; return $Default }
        if ($k.KeyChar -eq 'y' -or $k.KeyChar -eq 'Y') { Write-Host 'yes'; return $true }
        if ($k.KeyChar -eq 'n' -or $k.KeyChar -eq 'N') { Write-Host 'no'; return $false }
    }
}
function Install-WingetPackage {
    param([string]$Id)
    & winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity *> $null
    # -1978335189 = already installed / no applicable upgrade
    return ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189)
}
function Write-Utf8 { param([string]$Path, [string]$Text) [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false))) }
function Backup-File {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $bak = $Path + '.terminal11-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak'
        Copy-Item -LiteralPath $Path -Destination $bak
        Say ('    backup: ' + $bak) DarkGray
    }
}
function Write-IfChanged {
    # Writes only when content differs; backs up the old file first.
    param([string]$Path, [string]$Text)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        if ([IO.File]::ReadAllText($Path) -eq $Text) { return }
        Backup-File $Path
    }
    Write-Utf8 $Path $Text
}

# ----------------------------------------------------------------------------
# Interactive menu (arrow keys, native console only)
# ----------------------------------------------------------------------------
function Read-Menu {
    param(
        [string]$Title,
        [object[]]$Options,
        $Default = $null,
        [bool]$Multi = $false,
        [string]$Step = ''
    )
    $E = [char]27
    $n = $Options.Count
    $cur = 0
    $sel = New-Object 'System.Collections.Generic.HashSet[int]'
    for ($i = 0; $i -lt $n; $i++) {
        if ($Multi) { if ($null -ne $Default -and (@($Default) -contains $Options[$i].Value)) { [void]$sel.Add($i) } }
        elseif ($null -ne $Default -and $Options[$i].Value -eq $Default) { $cur = $i }
    }
    $w = [Math]::Max(40, [Console]::WindowWidth - 3)
    Write-Host ''
    if ($Step) { Say ('  ' + $Step) DarkGray }
    Say ('  ' + $Title) White
    if ($Multi) { Say '  Up/Down move   Space toggle   Enter confirm   Esc back' DarkGray }
    else { Say '  Up/Down move   Enter select   Esc back' DarkGray }
    Write-Host ''
    [Console]::Write("$E[?25l")
    $first = $true
    $done = $false
    $hdr = $(if ($Step) { 5 } else { 4 })   # blank, [step], title, hint, blank
    $collapse = {
        # erase the options and header, leaving the cursor where the header started
        $up = $n + $hdr
        [Console]::Write("$E[" + $up + 'A')
        for ($j = 0; $j -lt $up; $j++) { [Console]::Write("$E[2K`n") }
        [Console]::Write("$E[" + $up + 'A')
    }
    try {
        while (-not $done) {
            if (-not $first) { [Console]::Write("$E[" + $n + 'A') }
            $first = $false
            for ($i = 0; $i -lt $n; $i++) {
                $o = $Options[$i]
                $box = ''
                if ($Multi) { $box = $(if ($sel.Contains($i)) { '[x] ' } else { '[ ] ' }) }
                $head = $box + $o.Label
                $desc = ''
                if ($o.Desc) {
                    $room = $w - 4 - $head.Length - 2
                    if ($room -gt 8) { $desc = '  ' + $(if ($o.Desc.Length -gt $room) { $o.Desc.Substring(0, $room - 1) + '~' } else { $o.Desc }) }
                }
                if ($i -eq $cur) {
                    $line = "  $E[36m" + [char]0x276F + "$E[0m $E[1m$head$E[0m$E[90m$desc$E[0m"
                } else {
                    $line = "    $head$E[90m$desc$E[0m"
                }
                [Console]::Write("$E[2K" + $line + "`n")
            }
            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                'UpArrow'   { $cur = ($cur - 1 + $n) % $n }
                'DownArrow' { $cur = ($cur + 1) % $n }
                'K'         { $cur = ($cur - 1 + $n) % $n }
                'J'         { $cur = ($cur + 1) % $n }
                'Spacebar'  { if ($Multi) { if (-not $sel.Remove($cur)) { [void]$sel.Add($cur) } } }
                'Enter'     { $done = $true }
                'Escape'    { & $collapse; return @{ Back = $true; Value = $null } }
            }
        }
        & $collapse
        if ($Multi) {
            $vals = @(); $names = @()
            for ($i = 0; $i -lt $n; $i++) { if ($sel.Contains($i)) { $vals += , $Options[$i].Value; $names += $Options[$i].Label } }
            Write-Host ('  ' + [char]0x2713 + ' ' + $Title + ': ') -NoNewline -ForegroundColor Green
            Write-Host $(if ($names.Count) { $names -join ', ' } else { '(none)' })
            return @{ Back = $false; Value = $vals }
        }
        Write-Host ('  ' + [char]0x2713 + ' ' + $Title + ': ') -NoNewline -ForegroundColor Green
        Write-Host $Options[$cur].Label
        return @{ Back = $false; Value = $Options[$cur].Value }
    } finally {
        [Console]::Write("$E[?25h")
    }
}

# ----------------------------------------------------------------------------
# Catalogs
# ----------------------------------------------------------------------------
$Tools = @(
    @{ Id = 'git';      Name = 'git';      Winget = 'Git.Git';                    Cmd = 'git';      Default = $true;  Desc = 'version control (prompt git info needs it)' }
    @{ Id = 'starship'; Name = 'starship'; Winget = 'Starship.Starship';          Cmd = 'starship'; Default = $true;  Desc = 'fast prompt engine' }
    @{ Id = 'zoxide';   Name = 'zoxide';   Winget = 'ajeetdsouza.zoxide';         Cmd = 'zoxide';   Default = $true;  Desc = 'smart cd: z, zi' }
    @{ Id = 'fzf';      Name = 'fzf';      Winget = 'junegunn.fzf';               Cmd = 'fzf';      Default = $true;  Desc = 'fuzzy finder: Ctrl+R, Ctrl+T, Alt+C' }
    @{ Id = 'eza';      Name = 'eza';      Winget = 'eza-community.eza';          Cmd = 'eza';      Default = $true;  Desc = 'modern ls (ll, la, lt)' }
    @{ Id = 'bat';      Name = 'bat';      Winget = 'sharkdp.bat';                Cmd = 'bat';      Default = $true;  Desc = 'cat with syntax highlighting' }
    @{ Id = 'ripgrep';  Name = 'ripgrep';  Winget = 'BurntSushi.ripgrep.MSVC';    Cmd = 'rg';       Default = $true;  Desc = 'fast text search (grep alias)' }
    @{ Id = 'fd';       Name = 'fd';       Winget = 'sharkdp.fd';                 Cmd = 'fd';       Default = $true;  Desc = 'fast file search' }
    @{ Id = 'delta';    Name = 'delta';    Winget = 'dandavison.delta';           Cmd = 'delta';    Default = $true;  Desc = 'better git diffs (this profile only)' }
    @{ Id = 'lazygit';  Name = 'lazygit';  Winget = 'JesseDuffield.lazygit';      Cmd = 'lazygit';  Default = $false; Desc = 'terminal git UI (lg)' }
    @{ Id = 'jq';       Name = 'jq';       Winget = 'jqlang.jq';                  Cmd = 'jq';       Default = $false; Desc = 'JSON processor' }
    @{ Id = 'mise';     Name = 'mise';     Winget = 'jdx.mise';                   Cmd = 'mise';     Default = $false; Desc = 'runtime/version manager' }
    @{ Id = 'btop';     Name = 'btop';     Winget = 'aristocratos.btop4win';      Cmd = 'btop';     Default = $false; Desc = 'system monitor' }
)

$Fonts = @{
    cascadia  = @{ Label = 'CaskaydiaCove Nerd Font'; Face = 'CaskaydiaCove Nerd Font Mono'; Zip = 'CascadiaCode';  Prefix = 'CaskaydiaCoveNerdFontMono' }
    jetbrains = @{ Label = 'JetBrainsMono Nerd Font'; Face = 'JetBrainsMono Nerd Font Mono'; Zip = 'JetBrainsMono'; Prefix = 'JetBrainsMonoNerdFontMono' }
    fira      = @{ Label = 'FiraCode Nerd Font';      Face = 'FiraCode Nerd Font Mono';      Zip = 'FiraCode';      Prefix = 'FiraCodeNerdFontMono' }
}

function New-Scheme {
    param([string]$Name, [string]$Bg, [string]$Fg, [string]$Cursor, [string]$Sel, [string[]]$C)
    return [ordered]@{
        name = $Name; background = $Bg; foreground = $Fg; cursorColor = $Cursor; selectionBackground = $Sel
        black = $C[0]; red = $C[1]; green = $C[2]; yellow = $C[3]; blue = $C[4]; purple = $C[5]; cyan = $C[6]; white = $C[7]
        brightBlack = $C[8]; brightRed = $C[9]; brightGreen = $C[10]; brightYellow = $C[11]; brightBlue = $C[12]; brightPurple = $C[13]; brightCyan = $C[14]; brightWhite = $C[15]
    }
}
$Schemes = @{
    catppuccin = @{ Label = 'Catppuccin Mocha'; Builtin = $false; Def = (New-Scheme 'Catppuccin Mocha (Terminal 11)' '#1E1E2E' '#CDD6F4' '#F5E0DC' '#585B70' @('#45475A','#F38BA8','#A6E3A1','#F9E2AF','#89B4FA','#F5C2E7','#94E2D5','#BAC2DE','#585B70','#F38BA8','#A6E3A1','#F9E2AF','#89B4FA','#F5C2E7','#94E2D5','#A6ADC8')) }
    tokyonight = @{ Label = 'Tokyo Night';      Builtin = $false; Def = (New-Scheme 'Tokyo Night (Terminal 11)' '#1A1B26' '#C0CAF5' '#C0CAF5' '#283457' @('#15161E','#F7768E','#9ECE6A','#E0AF68','#7AA2F7','#BB9AF7','#7DCFFF','#A9B1D6','#414868','#F7768E','#9ECE6A','#E0AF68','#7AA2F7','#BB9AF7','#7DCFFF','#C0CAF5')) }
    dracula    = @{ Label = 'Dracula';          Builtin = $false; Def = (New-Scheme 'Dracula (Terminal 11)' '#282A36' '#F8F8F2' '#F8F8F2' '#44475A' @('#21222C','#FF5555','#50FA7B','#F1FA8C','#BD93F9','#FF79C6','#8BE9FD','#F8F8F2','#6272A4','#FF6E6E','#69FF94','#FFFFA5','#D6ACFF','#FF92DF','#A4FFFF','#FFFFFF')) }
    nord       = @{ Label = 'Nord';             Builtin = $false; Def = (New-Scheme 'Nord (Terminal 11)' '#2E3440' '#D8DEE9' '#D8DEE9' '#434C5E' @('#3B4252','#BF616A','#A3BE8C','#EBCB8B','#81A1C1','#B48EAD','#88C0D0','#E5E9F0','#4C566A','#BF616A','#A3BE8C','#EBCB8B','#81A1C1','#B48EAD','#8FBCBB','#ECEFF4')) }
    gruvbox    = @{ Label = 'Gruvbox Dark';     Builtin = $false; Def = (New-Scheme 'Gruvbox Dark (Terminal 11)' '#282828' '#EBDBB2' '#EBDBB2' '#504945' @('#282828','#CC241D','#98971A','#D79921','#458588','#B16286','#689D6A','#A89984','#928374','#FB4934','#B8BB26','#FABD2F','#83A598','#D3869B','#8EC07C','#EBDBB2')) }
    onehalf    = @{ Label = 'One Half Dark';    Builtin = $true;  Def = $null }
}

# ----------------------------------------------------------------------------
# Config model
# ----------------------------------------------------------------------------
function Get-DefaultConfig {
    return @{
        font = 'cascadia'; fontSize = 12; scheme = 'catppuccin'; opacity = '100'; cursor = 'bar'
        engine = 'starship'; layout = 'two'; symbols = 'nerd'
        modules = @('git', 'node', 'python', 'go', 'rust', 'duration')
        editMode = 'Windows'; prediction = 'ListView'; tabMenu = $true
        tools = @($Tools | Where-Object { $_.Default } | ForEach-Object { $_.Id })
        gitAliases = $true; makeDefault = $true
    }
}
function Read-Manifest {
    $f = Join-Path $S.Root 'terminal11.json'
    if (Test-Path -LiteralPath $f) {
        try { return (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable) } catch { return $null }
    }
    return $null
}
function New-Step {
    param([string]$Key, [int]$Level, [string]$Title, $Options, [bool]$Multi = $false, $When = $null, $Default = $null)
    return @{ Key = $Key; Level = $Level; Title = $Title; Options = $Options; Multi = $Multi; When = $When; Default = $Default }
}
function Get-Steps {
    return @(
        (New-Step 'font' 1 'Font' @(
            @{ Value = 'cascadia';  Label = 'CaskaydiaCove Nerd Font'; Desc = 'Cascadia Code + icons (recommended, ~10 MB download)' }
            @{ Value = 'jetbrains'; Label = 'JetBrainsMono Nerd Font'; Desc = 'icons + great readability' }
            @{ Value = 'fira';      Label = 'FiraCode Nerd Font';      Desc = 'icons + ligatures' }
            @{ Value = 'keep';      Label = 'Keep Windows Terminal default'; Desc = 'no download; Unicode symbols' }))
        (New-Step 'fontSize' 2 'Font size' @(
            @{ Value = 11; Label = '11' }, @{ Value = 12; Label = '12' }, @{ Value = 13; Label = '13' }, @{ Value = 14; Label = '14' }))
        (New-Step 'scheme' 1 'Color scheme' @(
            @{ Value = 'catppuccin';  Label = 'Catppuccin Mocha' }
            @{ Value = 'tokyonight';  Label = 'Tokyo Night' }
            @{ Value = 'dracula';     Label = 'Dracula' }
            @{ Value = 'nord';        Label = 'Nord' }
            @{ Value = 'gruvbox';     Label = 'Gruvbox Dark' }
            @{ Value = 'onehalf';     Label = 'One Half Dark'; Desc = 'built into Windows Terminal' }))
        (New-Step 'opacity' 2 'Background' @(
            @{ Value = '100';     Label = 'Solid';              Desc = 'fastest, no transparency' }
            @{ Value = '95';      Label = 'Slightly translucent' }
            @{ Value = '90';      Label = 'Translucent' }
            @{ Value = 'acrylic'; Label = 'Acrylic blur';       Desc = 'pretty, slightly heavier' }))
        (New-Step 'cursor' 2 'Cursor' @(
            @{ Value = 'bar'; Label = 'Bar' }, @{ Value = 'vintage'; Label = 'Block-ish (vintage)' }, @{ Value = 'underscore'; Label = 'Underscore' }, @{ Value = 'filledBox'; Label = 'Filled box' }))
        (New-Step 'engine' 1 'Prompt engine' @(
            @{ Value = 'starship'; Label = 'Starship';           Desc = 'rich, fast, many modules (recommended)' }
            @{ Value = 'native';   Label = 'Native PowerShell';  Desc = 'zero dependencies, path + git branch only' }))
        (New-Step 'layout' 1 'Prompt layout' @(
            @{ Value = 'two'; Label = 'Two-line'; Desc = '~/proj on main  /  then input on its own line' }
            @{ Value = 'one'; Label = 'One-line'; Desc = '~/proj on main > input' }))
        (New-Step 'symbols' 1 'Prompt symbols' @(
            @{ Value = 'nerd';    Label = 'Nerd Font icons'; Desc = 'needs a Nerd Font (installed above)' }
            @{ Value = 'unicode'; Label = 'Unicode';         Desc = 'line art + arrows, words instead of icons' }
            @{ Value = 'ascii';   Label = 'ASCII';           Desc = 'works everywhere' }) $false $null { if ($cfg.font -eq 'keep' -and $cfg.symbols -eq 'nerd') { 'unicode' } else { $cfg.symbols } })
        (New-Step 'modules' 1 'Prompt info' @(
            @{ Value = 'git';        Label = 'Git branch + status' }
            @{ Value = 'node';       Label = 'Node version' }
            @{ Value = 'python';     Label = 'Python version' }
            @{ Value = 'go';         Label = 'Go version' }
            @{ Value = 'rust';       Label = 'Rust version' }
            @{ Value = 'kubernetes'; Label = 'Kubernetes context' }
            @{ Value = 'aws';        Label = 'AWS profile' }
            @{ Value = 'duration';   Label = 'Command duration'; Desc = 'only when a command took 2s+' }
            @{ Value = 'time';       Label = 'Clock (24h)' }) $true { $cfg.engine -eq 'starship' })
        (New-Step 'editMode' 1 'Editing mode' @(
            @{ Value = 'Windows'; Label = 'Windows'; Desc = 'default PowerShell keys' }
            @{ Value = 'Emacs';   Label = 'Emacs';   Desc = 'Ctrl+A/E/K/W like bash' }
            @{ Value = 'Vi';      Label = 'Vi' }))
        (New-Step 'prediction' 2 'History prediction' @(
            @{ Value = 'ListView';   Label = 'List view'; Desc = 'dropdown of matching history (recommended)' }
            @{ Value = 'InlineView'; Label = 'Inline';    Desc = 'grey ghost text' }
            @{ Value = 'None';       Label = 'Off' }))
        (New-Step 'tabMenu' 2 'Tab completion' @(
            @{ Value = $true;  Label = 'Menu';     Desc = 'Tab opens a selectable menu' }
            @{ Value = $false; Label = 'Standard'; Desc = 'cycle through matches' }))
        (New-Step 'tools' 1 'CLI tools to install (winget, per-user where possible)' { Get-ToolOptions } $true)
        (New-Step 'gitAliases' 2 'Git shortcuts (g, gs, ga, gd, gco, glog ...)' @(
            @{ Value = $true; Label = 'Install' }, @{ Value = $false; Label = 'Skip' }))
        (New-Step 'makeDefault' 1 'Make "Terminal 11" the default Windows Terminal profile?' @(
            @{ Value = $true;  Label = 'Yes'; Desc = 'your other profiles stay in the dropdown' }
            @{ Value = $false; Label = 'No';  Desc = 'just add it; pick it from the dropdown' }))
    )
}
function Get-ToolOptions {
    return @($Tools | ForEach-Object {
        $have = Test-Cmd $_.Cmd
        @{ Value = $_.Id; Label = $_.Name; Desc = $(if ($have) { 'installed - ' + $_.Desc } else { $_.Desc }) }
    })
}

# ----------------------------------------------------------------------------
# Generators
# ----------------------------------------------------------------------------
function New-StarshipToml {
    param($c)
    $nerd = ($c.symbols -eq 'nerd'); $ascii = ($c.symbols -eq 'ascii')
    $mods = @($c.modules)
    $parts = '$directory'
    if ($mods -contains 'git')        { $parts += '$git_branch$git_status' }
    if ($mods -contains 'node')       { $parts += '$nodejs' }
    if ($mods -contains 'python')     { $parts += '$python' }
    if ($mods -contains 'go')         { $parts += '$golang' }
    if ($mods -contains 'rust')       { $parts += '$rust' }
    if ($mods -contains 'kubernetes') { $parts += '$kubernetes' }
    if ($mods -contains 'aws')        { $parts += '$aws' }
    if ($mods -contains 'duration')   { $parts += '$cmd_duration' }
    if ($mods -contains 'time')       { $parts += '$time' }

    $tl = if ($ascii) { '+-' } else { '\u256D\u2500' }
    $bl = if ($ascii) { '+-' } else { '\u2570\u2500' }
    if ($c.layout -eq 'two') {
        $format = 'format = """' + "`n" + '[' + $tl + '](bold bright-black)' + $parts + "`n" + '[' + $bl + '](bold bright-black)$character"""'
        $nl = 'true'
    } else {
        $format = 'format = "' + $parts + '$character"'
        $nl = 'false'
    }
    $ch = if ($ascii) { '>' } else { '\u276F' }
    $chv = if ($ascii) { '<' } else { '\u276E' }
    $sym = @{
        git = 'on '; node = 'node '; python = 'py '; go = 'go '; rust = 'rs '; kubernetes = 'k8s '; aws = 'aws '
    }
    if ($nerd) {
        $sym = @{ git = '\uE0A0 '; node = '\uE718 '; python = '\uE73C '; go = '\uE627 '; rust = '\uE7A8 '; kubernetes = '\u2638 '; aws = '\uE7AD ' }
    }

    $t = @'
# Terminal 11 starship config.
# Terminal 11 regenerates this file on reconfigure (old copy is backed up).
# To keep your own edits across updates, put this marker on the first line:  # t11:keep
add_newline = @@NL@@
command_timeout = 500
scan_timeout = 30
@@FORMAT@@

[directory]
style = "bold cyan"
truncation_length = 3
truncate_to_repo = true

[character]
success_symbol = "[@@CH@@](bold green)"
error_symbol = "[@@CH@@](bold red)"
vimcmd_symbol = "[@@CHV@@](bold yellow)"

'@
    $t = $t.Replace('@@NL@@', $nl).Replace('@@FORMAT@@', $format).Replace('@@CH@@', $ch).Replace('@@CHV@@', $chv)

    $defs = @(
        @{ Id = 'git'; Name = 'git_branch'; Style = 'bold purple'; Fmt = ' [$symbol$branch]($style)'; Sym = 'git' }
        @{ Id = 'git'; Name = 'git_status'; Style = 'bold yellow'; Fmt = '( [$all_status$ahead_behind]($style))'; Sym = '' }
        @{ Id = 'node'; Name = 'nodejs'; Style = 'bold green'; Fmt = ' [$symbol$version]($style)'; Sym = 'node' }
        @{ Id = 'python'; Name = 'python'; Style = 'bold yellow'; Fmt = ' [$symbol$version]($style)'; Sym = 'python' }
        @{ Id = 'go'; Name = 'golang'; Style = 'bold cyan'; Fmt = ' [$symbol$version]($style)'; Sym = 'go' }
        @{ Id = 'rust'; Name = 'rust'; Style = 'bold red'; Fmt = ' [$symbol$version]($style)'; Sym = 'rust' }
        @{ Id = 'kubernetes'; Name = 'kubernetes'; Style = 'bold blue'; Fmt = ' [$symbol$context]($style)'; Sym = 'kubernetes'; Extra = 'disabled = false' }
        @{ Id = 'aws'; Name = 'aws'; Style = 'bold yellow'; Fmt = ' [$symbol($profile)]($style)'; Sym = 'aws' }
        @{ Id = 'duration'; Name = 'cmd_duration'; Style = 'yellow'; Fmt = ' [$duration]($style)'; Sym = ''; Extra = 'min_time = 2000' }
        @{ Id = 'time'; Name = 'time'; Style = 'bright-black'; Fmt = ' [$time]($style)'; Sym = ''; Extra = 'disabled = false' + "`n" + 'time_format = "%H:%M"' }
    )
    foreach ($d in $defs) {
        if ($mods -notcontains $d.Id) { continue }
        $t += '[' + $d.Name + "]`n"
        if ($d.Sym) { $t += 'symbol = "' + $sym[$d.Sym] + "`"`n" }
        if ($d.ContainsKey('Extra')) { $t += $d.Extra + "`n" }
        $t += 'style = "' + $d.Style + "`"`n"
        $t += 'format = "' + $d.Fmt + "`"`n`n"
    }
    return $t
}

function New-ProfileScript {
    param($c)
    $nerd = ($c.symbols -eq 'nerd'); $ascii = ($c.symbols -eq 'ascii')
    $icons = if ($nerd) { '--icons=auto' } else { '' }
    $tl = if ($ascii) { '+- ' } else { [string][char]0x256D + [string][char]0x2500 + ' ' }
    $bl = if ($ascii) { '+- ' } else { [string][char]0x2570 + [string][char]0x2500 + ' ' }
    $sym = if ($ascii) { '>' } else { [string][char]0x276F }

    $head = @'
# Terminal 11 profile - generated by installer v@@VERSION@@. Regenerated on update: do not edit.
# Your own code goes in local.ps1 (same folder). It is loaded last and never overwritten.
if (-not $PSScriptRoot) { return }
$T11 = $PSScriptRoot
$env:TERMINAL11_HOME = $T11
$env:STARSHIP_CONFIG = Join-Path $T11 'starship.toml'
$env:BAT_THEME = 'ansi'
$env:FZF_DEFAULT_OPTS = '--height=40% --layout=reverse --border --info=inline --color=hl:6,hl+:6,pointer:6,prompt:6,info:8,border:8'

# PATH: pick up tools installed after Windows Terminal itself started
$__seen = @{}
$env:Path = $(foreach ($__x in (([Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + $env:Path) -split ';')) {
    if ($__x -and -not $__seen.ContainsKey($__x.ToLowerInvariant())) { $__seen[$__x.ToLowerInvariant()] = 1; $__x }
}) -join ';'
Remove-Variable __seen, __x -ErrorAction Ignore

# Cached `tool init` output: regenerated only when the tool's binary changes.
function Get-T11Init {
    param([string]$Name, [string]$Exe, [string[]]$InitArgs)
    $app = Get-Command $Exe -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    if (-not $app) { return $null }
    $file = Join-Path (Join-Path $T11 'cache') "$Name.ps1"
    if (-not (Test-Path -LiteralPath $file) -or (Get-Item -LiteralPath $file).LastWriteTimeUtc -lt (Get-Item -LiteralPath $app.Source).LastWriteTimeUtc) {
        New-Item -ItemType Directory -Path (Split-Path $file) -Force | Out-Null
        (& $app.Source @InitArgs) -join "`n" | Set-Content -LiteralPath $file -Encoding utf8
    }
    return $file
}

# Native prompt (also the fallback if Starship is missing)
function prompt {
    $ok = $?
    $esc = [char]27
    $p = $PWD.ProviderPath
    if ($p.StartsWith($HOME, [StringComparison]::OrdinalIgnoreCase)) { $p = '~' + $p.Substring($HOME.Length) }
    $branch = ''
    $d = $PWD.ProviderPath
    while ($d) {
        $h = Join-Path $d '.git\HEAD'
        if (Test-Path -LiteralPath $h -PathType Leaf) {
            $line = Get-Content -LiteralPath $h -TotalCount 1
            $branch = if ($line -match '^ref: refs/heads/(.+)$') { $Matches[1] } else { $line.Substring(0, [Math]::Min(7, $line.Length)) }
            break
        }
        $d = Split-Path -Parent $d
    }
    $git = if ($branch) { " $esc[35m$branch$esc[0m" } else { '' }
    $col = if ($ok) { '32' } else { '31' }
    if (@@TWOLINE@@) { "$esc[90m@@TL@@$esc[0m$esc[36m$p$esc[0m$git`n$esc[90m@@BL@@$esc[0m$esc[$($col)m@@SYM@@$esc[0m " }
    else { "$esc[36m$p$esc[0m$git $esc[$($col)m@@SYM@@$esc[0m " }
}

'@
    $head = $head.Replace('@@VERSION@@', $S.Version).Replace('@@TWOLINE@@', $(if ($c.layout -eq 'two') { '$true' } else { '$false' })).Replace('@@TL@@', $tl).Replace('@@BL@@', $bl).Replace('@@SYM@@', $sym)

    $inits = ''
    if ($c.engine -eq 'starship') {
        $inits += "`$__i = Get-T11Init 'starship' 'starship' @('init', 'powershell', '--print-full-init'); if (`$__i) { . `$__i }`n"
    }
    $inits += "`$__i = Get-T11Init 'zoxide' 'zoxide' @('init', 'powershell'); if (`$__i) { . `$__i }`n"
    $inits += "`$__i = Get-T11Init 'mise' 'mise' @('activate', 'pwsh'); if (`$__i) { . `$__i }`n`n"

    $readline = @'
# PSReadLine (built-in only)
try {
    Set-PSReadLineOption -EditMode @@EDITMODE@@
    Set-PSReadLineOption -BellStyle None -HistoryNoDuplicates -HistorySearchCursorMovesToEnd -MaximumHistoryCount 20000
    @@PREDICTION@@
    Set-PSReadLineOption -Colors @{ InlinePrediction = "$([char]27)[90m" }
    Set-PSReadLineKeyHandler -Chord UpArrow -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Chord DownArrow -Function HistorySearchForward
    @@TAB@@
} catch { }

'@
    $pred = if ($c.prediction -eq 'None') { 'Set-PSReadLineOption -PredictionSource None' } else { 'Set-PSReadLineOption -PredictionSource History -PredictionViewStyle ' + $c.prediction }
    $tab = if ($c.tabMenu) { 'Set-PSReadLineKeyHandler -Chord Tab -Function MenuComplete' } else { '' }
    $readline = $readline.Replace('@@EDITMODE@@', [string]$c.editMode).Replace('@@PREDICTION@@', $pred).Replace('@@TAB@@', $tab)

    $aliases = @'
# Navigation + everyday shortcuts
function .. { Set-Location .. }
function ... { Set-Location ..\.. }
function .... { Set-Location ..\..\.. }
function c { Clear-Host }
function mkcd { param([Parameter(Mandatory)][string]$Path) New-Item -ItemType Directory -Path $Path -Force | Out-Null; Set-Location -LiteralPath $Path }
function touch { param([Parameter(Mandatory)][string[]]$Path) foreach ($p in $Path) { if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).LastWriteTime = Get-Date } else { New-Item -ItemType File -Path $p | Out-Null } } }
function which { param([Parameter(Mandatory)][string]$Name) Get-Command $Name -All -ErrorAction Ignore | Select-Object CommandType, Name, Source }
function open { Invoke-Item @args }
if (Get-Command eza -CommandType Application -ErrorAction Ignore) {
    function ll { eza -l @@ICONS@@ --git --group-directories-first @args }
    function la { eza -la @@ICONS@@ --git --group-directories-first @args }
    function lt { eza --tree --level=2 @@ICONS@@ @args }
} else {
    function ll { Get-ChildItem @args | Format-Table Mode, LastWriteTime, Length, Name -AutoSize }
    function la { Get-ChildItem -Force @args | Format-Table Mode, LastWriteTime, Length, Name -AutoSize }
}
if (Get-Command rg -CommandType Application -ErrorAction Ignore) { Set-Alias grep rg }
if (Get-Command lazygit -CommandType Application -ErrorAction Ignore) { Set-Alias lg lazygit }
if (Get-Command delta -CommandType Application -ErrorAction Ignore) { $env:GIT_PAGER = 'delta' }

'@
    $aliases = $aliases.Replace('@@ICONS@@', $icons)

    $gitAl = ''
    if ($c.gitAliases) {
        $gitAl = @'
# Git shortcuts
function g { git @args }
function gs { git status -sb @args }
function ga { git add @args }
function gd { git diff @args }
function gco { git checkout @args }
function gb { git branch @args }
function glog { git log --oneline --graph --decorate -20 @args }
function gpush { git push @args }
function gpull { git pull --ff-only @args }

'@
    }

    $fzf = @'
# fzf key bindings without any module: Ctrl+R history, Ctrl+T files, Alt+C directories
if (Get-Command fzf -CommandType Application -ErrorAction Ignore) {
    Set-PSReadLineKeyHandler -Chord Ctrl+r -ScriptBlock {
        $line = $null; $cur = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cur)
        $path = (Get-PSReadLineOption).HistorySavePath
        if (-not (Test-Path -LiteralPath $path)) { return }
        $items = [System.IO.File]::ReadAllLines($path)
        [array]::Reverse($items)
        $pick = $items | Select-Object -Unique | fzf --scheme=history --query "$line" --prompt 'history> '
        [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
        if ($pick) { [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine(); [Microsoft.PowerShell.PSConsoleReadLine]::Insert($pick) }
    }
    Set-PSReadLineKeyHandler -Chord Ctrl+t -ScriptBlock {
        $src = if (Get-Command fd -CommandType Application -ErrorAction Ignore) { fd --type f --hidden --exclude .git } else { Get-ChildItem -Recurse -File -Name -ErrorAction Ignore }
        $prev = if (Get-Command bat -CommandType Application -ErrorAction Ignore) { 'bat --style=numbers --color=always --line-range=:200 {}' } else { 'type {}' }
        $pick = @($src | fzf --multi --preview $prev --prompt 'file> ')
        [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
        if ($pick.Count -gt 0) {
            $text = ($pick | ForEach-Object { if ($_ -match '\s') { "'$_'" } else { $_ } }) -join ' '
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert($text)
        }
    }
    Set-PSReadLineKeyHandler -Chord Alt+c -ScriptBlock {
        $src = if (Get-Command fd -CommandType Application -ErrorAction Ignore) { fd --type d --hidden --exclude .git } else { Get-ChildItem -Recurse -Directory -Name -ErrorAction Ignore }
        $pick = $src | fzf --prompt 'cd> '
        if ($pick) {
            [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert("Set-Location -LiteralPath '" + $pick.Replace("'", "''") + "'")
            [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
        } else { [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt() }
    }
}

'@

    $t11 = @'
# t11: tiny helper (a function, not an installed program)
function t11 {
    param([Parameter(Position = 0)][string]$Command = 'help', [switch]$Json)
    $mf = Join-Path $T11 'terminal11.json'
    $m = if (Test-Path -LiteralPath $mf) { Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json } else { $null }
    switch ($Command) {
        'doctor' {
            $tools = [ordered]@{}
            if ($m -and $m.tools) {
                foreach ($p in $m.tools.PSObject.Properties) {
                    $a = Get-Command $p.Value -CommandType Application -ErrorAction Ignore | Select-Object -First 1
                    $tools[$p.Name] = if ($a) { $a.Source } else { $null }
                }
            }
            $r = [ordered]@{
                version = if ($m) { $m.version } else { $null }
                root = $T11
                pwsh = $PSVersionTable.PSVersion.ToString()
                windowsTerminal = [bool]$env:WT_SESSION
                tools = $tools
                files = [ordered]@{
                    profile = Test-Path -LiteralPath (Join-Path $T11 'profile.ps1')
                    starship = Test-Path -LiteralPath (Join-Path $T11 'starship.toml')
                    local = Test-Path -LiteralPath (Join-Path $T11 'local.ps1')
                }
            }
            if ($Json) { $r | ConvertTo-Json -Depth 5; return }
            Write-Host "Terminal 11 $($r.version)  |  pwsh $($r.pwsh)  |  Windows Terminal: $($r.windowsTerminal)"
            foreach ($k in $tools.Keys) { Write-Host ('  {0,-10} {1}' -f $k, $(if ($tools[$k]) { $tools[$k] } else { 'MISSING (t11 update, or: winget install ...)' })) }
        }
        'bench' {
            $ms = 1..5 | ForEach-Object { (Measure-Command { pwsh -NoLogo -NoProfile -Command ". '$T11\profile.ps1'; exit" | Out-Null }).TotalMilliseconds } | Sort-Object
            'startup (non-interactive approximation, PSReadLine setup excluded): median {0:n0} ms, min {1:n0} ms, max {2:n0} ms' -f $ms[2], $ms[0], $ms[4]
        }
        'glyphs' {
            $e = [char]27
            "Box: $([char]0x256D)$([char]0x2500)$([char]0x2570)  Arrows: $([char]0x276F) $([char]0x276E)"
            "Nerd Font icons (should be pictures, not boxes): $([char]0xE0A0) $([char]0xE718) $([char]0xE73C) $([char]0xE627) $([char]0xE7A8)"
        }
        'edit' { $f = Join-Path $T11 'local.ps1'; if ($env:EDITOR) { & $env:EDITOR $f } else { notepad $f } }
        'home' { Set-Location -LiteralPath $T11 }
        'clean' { Remove-Item -LiteralPath (Join-Path $T11 'cache') -Recurse -Force -ErrorAction Ignore; 'Init cache cleared; open a new tab.' }
        'update' { $env:T11_ACTION = 'install'; $env:T11_YES = '1'; try { Invoke-RestMethod $m.installUrl | Invoke-Expression } finally { Remove-Item Env:T11_ACTION, Env:T11_YES -ErrorAction Ignore } }
        'uninstall' { $env:T11_ACTION = 'uninstall'; try { Invoke-RestMethod $m.installUrl | Invoke-Expression } finally { Remove-Item Env:T11_ACTION -ErrorAction Ignore } }
        default {
            'Terminal 11 helper'
            '  t11 doctor [-Json]   check tools and files (agents: use -Json)'
            '  t11 bench            measure shell startup time'
            '  t11 glyphs           test icon rendering'
            '  t11 edit             edit local.ps1 (your own customizations)'
            '  t11 home             cd to the Terminal 11 folder'
            '  t11 clean            clear cached tool init scripts'
            '  t11 update           re-apply saved config and refresh tools'
            '  t11 uninstall        remove Terminal 11 (your own profiles were never touched)'
        }
    }
}

# Your customizations (never overwritten)
$__l = Join-Path $T11 'local.ps1'
if (Test-Path -LiteralPath $__l) { . $__l }
Remove-Variable __l, __i -ErrorAction Ignore
'@
    return ($head + $inits + $readline + $aliases + $gitAl + $fzf + $t11 + "`n")
}

function Write-AgentFiles {
    $root = $S.Root
    $agents = @'
# Terminal 11 - environment guide for AI agents

This machine runs **Terminal 11**: Windows Terminal + PowerShell 7, CLI-first, no PowerShell modules.
Home: `@@ROOT@@`

## Layout
- `profile.ps1`    GENERATED. Do not edit. Regenerated by `t11 update`.
- `local.ps1`      Yours (user or agent) - loaded last, never overwritten. Put customizations here.
- `starship.toml`  Prompt config. Add `# t11:keep` as line 1 to protect manual edits from regeneration.
- `terminal11.json` Manifest and chosen config. `t11 update` re-applies it.
- `cache/`         Cached `tool init` scripts (safe to delete: `t11 clean`).
- `skills/`        Playbooks for common tasks (add-tool, fix-shell, tune-startup).

## Rules
1. Never edit the user's own `$PROFILE` files or Windows Terminal `settings.json`. Terminal 11 only owns its own folder and its WT fragment.
2. No external PowerShell modules. Prefer standalone executables installed with `winget`.
3. Startup speed is a feature. Run `t11 bench` before and after any change to profile load; keep new work lazy or cached.
4. Inspect state with `t11 doctor -Json` instead of guessing.
5. Ask the user before installing software. State the exact winget id.
6. Interactive-only code (PSReadLine handlers, prompts) must tolerate non-interactive sessions.

## Common tasks
- Missing a tool: follow `skills/add-tool/SKILL.md`.
- Shell broken or slow: follow `skills/fix-shell/SKILL.md` or `skills/tune-startup/SKILL.md`.
'@
    $addTool = @'
---
name: add-tool
description: Install a CLI tool for the Terminal 11 environment and wire it into the shell. Use when a command is missing or the user asks for a new CLI tool.
---
1. Check: `Get-Command <tool> -ErrorAction Ignore`. If present, stop.
2. Find the package: `winget search <tool>`. Confirm the id with the user before installing.
3. Install: `winget install --id <Id> --exact --silent --accept-package-agreements --accept-source-agreements`.
4. Open a NEW Terminal 11 tab (the profile re-reads PATH on start) and verify with `Get-Command`.
5. If the tool needs shell integration, add it to `local.ps1`. For init scripts use the cached pattern: dot-source the output of `Get-T11Init '<name>' '<exe>' @('<init args>')` at the top level of local.ps1 (not inside a function).
6. Run `t11 bench`. If startup grew by more than ~30 ms, make the integration lazy.
'@
    $fixShell = @'
---
name: fix-shell
description: Diagnose and repair a broken Terminal 11 shell (errors on startup, missing prompt, missing commands, wrong glyphs).
---
1. `t11 doctor -Json` - look for MISSING tools and missing files.
2. Start a clean shell to isolate the cause: `pwsh -NoProfile`. If the problem disappears, it is in profile.ps1 or local.ps1.
3. Bisect `local.ps1` by commenting blocks out. Never edit `profile.ps1`; fix the cause or re-run `t11 update`.
4. Prompt looks wrong: `t11 clean`, then open a new tab. Boxes instead of icons: `t11 glyphs`; fix the font in the Terminal 11 profile or switch symbols to Unicode/ASCII via `t11 update` after changing the saved config.
5. Tool missing after install: open a NEW tab; if still missing, `winget list <id>`.
'@
    $tune = @'
---
name: tune-startup
description: Measure and reduce Terminal 11 shell startup time.
---
1. Baseline: `t11 bench` (run it 2-3 times, use the median).
2. Compare against `pwsh -NoProfile -Command exit` to see the floor.
3. Check `local.ps1` first: anything that spawns a process, calls Get-Module -ListAvailable, or hits the network at startup is a suspect.
4. Prefer cached init (`Get-T11Init`) or lazy wrappers that load the real thing on first use.
5. Re-run `t11 bench`; report before/after numbers to the user.
'@
    New-Item -ItemType Directory -Path (Join-Path $root 'skills\add-tool') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'skills\fix-shell') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'skills\tune-startup') -Force | Out-Null
    Write-IfChanged (Join-Path $root 'AGENTS.md') ($agents.Replace('@@ROOT@@', $root))
    Write-IfChanged (Join-Path $root 'CLAUDE.md') "See AGENTS.md in this folder.`n"
    Write-IfChanged (Join-Path $root 'skills\add-tool\SKILL.md') $addTool
    Write-IfChanged (Join-Path $root 'skills\fix-shell\SKILL.md') $fixShell
    Write-IfChanged (Join-Path $root 'skills\tune-startup\SKILL.md') $tune
}

# ----------------------------------------------------------------------------
# Windows Terminal + font + tools
# ----------------------------------------------------------------------------
function Get-WtSettingsPaths {
    $la = $env:LOCALAPPDATA
    $c = @(
        (Join-Path $la 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $la 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $la 'Microsoft\Windows Terminal\settings.json')
    )
    return @($c | Where-Object { Test-Path -LiteralPath $_ })
}
function Get-FragmentDir { return (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\Terminal11') }

function Test-FontInstalled {
    param([string]$Face)
    foreach ($k in @('HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts')) {
        $props = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
        if ($props) { foreach ($n in $props.PSObject.Properties.Name) { if ($n -like ($Face + '*')) { return $true } } }
    }
    return $false
}
function Install-NerdFont {
    param([string]$Key)
    $f = $Fonts[$Key]
    if (Test-FontInstalled $f.Face) { Ok ($f.Label + ' already installed'); return $f.Face }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('t11-font-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $zip = Join-Path $tmp ($f.Zip + '.zip')
        $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -UseBasicParsing -Uri ('https://github.com/ryanoasis/nerd-fonts/releases/latest/download/' + $f.Zip + '.zip') -OutFile $zip } finally { $ProgressPreference = $old }
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tmp 'x') -Force
        $dest = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        $reg = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
        $files = @(Get-ChildItem -LiteralPath (Join-Path $tmp 'x') -Filter ($f.Prefix + '-*.ttf') | Where-Object { $_.BaseName -match '-(Regular|Bold|Italic|BoldItalic)$' })
        if ($files.Count -eq 0) { throw 'no matching font files in the archive' }
        foreach ($file in $files) {
            Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
            $style = ($file.BaseName -split '-')[-1]
            New-ItemProperty -Path $reg -Name ($f.Face + ' ' + $style + ' (TrueType)') -Value (Join-Path $dest $file.Name) -PropertyType String -Force | Out-Null
        }
        Ok ($f.Label + ' installed for your user (restart Windows Terminal to see it)')
        return $f.Face
    } catch {
        Warn ('Font install failed: ' + $_.Exception.Message)
        return $null
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function Install-Tools {
    param($c)
    $want = @($Tools | Where-Object { @($c.tools) -contains $_.Id })
    if ($c.engine -ne 'starship') { $want = @($want | Where-Object { $_.Id -ne 'starship' }) }
    $missing = @($want | Where-Object { -not (Test-Cmd $_.Cmd) })
    foreach ($t in @($want | Where-Object { Test-Cmd $_.Cmd })) { Ok ($t.Name + ' already installed') }
    if ($missing.Count -eq 0) { return }
    if (-not (Test-Cmd 'winget')) { Warn 'winget not found - skipped tool installs. Install "App Installer" from the Microsoft Store and run again.'; return }
    foreach ($t in $missing) {
        Write-Host ('  installing ' + $t.Name.PadRight(10)) -NoNewline -ForegroundColor Gray
        if (Install-WingetPackage $t.Winget) { Write-Host ' done' -ForegroundColor Green }
        else { Write-Host ' failed' -ForegroundColor Yellow; $S.Warn.Add('Could not install ' + $t.Name + ' (winget id ' + $t.Winget + ')') }
    }
    Update-SessionPath
}
function Register-WtProfile {
    param($c, $FontFace)
    $dir = Get-FragmentDir
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $ps1 = Join-Path $S.Root 'profile.ps1'
    $cmd = 'pwsh.exe -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -NoExit -Command ". ''' + $ps1.Replace("'", "''") + '''"'
    $sch = $Schemes[$c.scheme]
    $schemeName = if ($sch.Builtin) { $sch.Label } else { $sch.Def.name }
    $p = [ordered]@{
        guid = $S.Guid
        name = 'Terminal 11'
        commandline = $cmd
        startingDirectory = '%USERPROFILE%'
        icon = ([string][char]0x2708) + ([string][char]0xFE0F)
        colorScheme = $schemeName
        cursorShape = [string]$c.cursor
    }
    if ($FontFace) { $p['font'] = [ordered]@{ face = $FontFace; size = [int]$c.fontSize } }
    if ($c.opacity -eq 'acrylic') { $p['useAcrylic'] = $true; $p['opacity'] = 85 }
    else { $p['useAcrylic'] = $false; $p['opacity'] = [int]$c.opacity }
    $frag = [ordered]@{ profiles = @($p) }
    if (-not $sch.Builtin) { $frag['schemes'] = @($sch.Def) }
    Write-Utf8 (Join-Path $dir 'terminal11.json') ($frag | ConvertTo-Json -Depth 8)
    Ok 'Windows Terminal profile "Terminal 11" registered (fragment, settings.json untouched)'
}
function Set-WtDefault {
    # Targeted edit of the single "defaultProfile" value. Comments/formatting in settings.json survive.
    param([string]$Path, [string]$Guid)
    $text = [IO.File]::ReadAllText($Path)
    $rx = [regex]'"defaultProfile"\s*:\s*"([^"]*)"'
    $m = $rx.Match($text)
    $previous = $S.WinPsGuid
    if ($m.Success) {
        $previous = $m.Groups[1].Value
        if ($previous -eq $Guid) { return $previous }
        $updated = $rx.Replace($text, '"defaultProfile": "' + $Guid + '"', 1)
    } else {
        $brace = [regex]'(?m)^\s*\{'
        if (-not $brace.IsMatch($text)) { throw 'settings.json has an unexpected shape' }
        $updated = $brace.Replace($text, "{`r`n    `"defaultProfile`": `"" + $Guid + "`",", 1)
    }
    Backup-File $Path
    Write-Utf8 $Path $updated
    return $previous
}
function Show-Summary {
    param($c, [bool]$HasWt)
    $sch = $Schemes[$c.scheme].Label
    $font = if ($c.font -eq 'keep') { 'Windows Terminal default' } else { $Fonts[$c.font].Label + ' ' + $c.fontSize }
    $toolNames = @($Tools | Where-Object { @($c.tools) -contains $_.Id -and ($c.engine -eq 'starship' -or $_.Id -ne 'starship') })
    $toInstall = @($toolNames | Where-Object { -not (Test-Cmd $_.Cmd) })
    $rows = @(
        @('Shell', 'PowerShell 7, via a NEW Windows Terminal profile "Terminal 11"'),
        @('Appearance', ($font + ' / ' + $sch + ' / ' + $c.opacity + $(if ($c.opacity -ne 'acrylic') { '% opacity' } else { '' }) + ' / cursor ' + $c.cursor)),
        @('Prompt', ($c.engine + ', ' + $c.layout + '-line, ' + $c.symbols + ' symbols' + $(if ($c.engine -eq 'starship') { ', ' + (@($c.modules) -join ' ') } else { '' }))),
        @('Keyboard', ($c.editMode + ' keys, prediction ' + $c.prediction + ', Tab ' + $(if ($c.tabMenu) { 'menu' } else { 'standard' }))),
        @('Tools', $(if ($toInstall.Count) { 'will install: ' + (($toInstall | ForEach-Object { $_.Name }) -join ', ') } else { 'nothing to install' })),
        @('Default', $(if ($c.makeDefault) { 'Terminal 11 becomes the default profile (previous default restored by uninstall)' } else { 'not changed' }))
    )
    Write-Host ''
    Say '  Configuration summary' White
    foreach ($r in $rows) { Write-Host ('    ' + $r[0].PadRight(12)) -NoNewline -ForegroundColor DarkYellow; Write-Host $r[1] }
    Write-Host ''
    Say '  Will create' White
    Say ('    ' + $S.Root + '   (profile.ps1, starship.toml, local.ps1, AGENTS.md, skills)') Gray
    Say '    a Windows Terminal fragment for the "Terminal 11" profile and color scheme' Gray
    Say '  Will NOT touch' White
    Say '    your $PROFILE files, your existing Windows Terminal profiles, git config' Gray
    if (-not $HasWt) { Say '  Windows Terminal was not detected; it will be installed if you accept.' Yellow }
}

# ----------------------------------------------------------------------------
# Uninstall
# ----------------------------------------------------------------------------
function Invoke-Uninstall {
    Show-Banner
    Stage 'DEPARTURE' 'Removing Terminal 11'
    $m = Read-Manifest
    if (-not $m) { Say '  No Terminal 11 manifest found; nothing to revert except the fragment.' Yellow }
    foreach ($path in @(Get-WtSettingsPaths)) {
        $text = [IO.File]::ReadAllText($path)
        $rx = [regex]'"defaultProfile"\s*:\s*"([^"]*)"'
        $mm = $rx.Match($text)
        if ($mm.Success -and $mm.Groups[1].Value -eq $S.Guid) {
            $prev = $S.WinPsGuid
            if ($m -and $m.ContainsKey('previousDefaults') -and $m['previousDefaults'].ContainsKey($path)) { $prev = $m['previousDefaults'][$path] }
            Backup-File $path
            Write-Utf8 $path ($rx.Replace($text, '"defaultProfile": "' + $prev + '"', 1))
            Ok ('default profile restored in ' + $path)
        }
    }
    $frag = Get-FragmentDir
    if (Test-Path -LiteralPath $frag) { Remove-Item -LiteralPath $frag -Recurse -Force; Ok 'Windows Terminal fragment removed' }
    if (Test-Path -LiteralPath $S.Root) {
        if (Confirm-Step ('Also delete ' + $S.Root + ' (your local.ps1 lives there)?') $false) { Remove-Item -LiteralPath $S.Root -Recurse -Force; Ok 'config folder deleted' }
        else { Say ('  kept ' + $S.Root) Gray }
    }
    Say '  Installed tools and fonts were left alone (remove with winget / Windows Settings if you want).' DarkGray
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
if ($env:OS -ne 'Windows_NT') { Say 'Terminal 11 supports Windows only.' Red; return }

# --- Windows PowerShell 5.1 -> bootstrap PowerShell 7 ------------------------
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Show-Banner
    Say '  You are in Windows PowerShell 5.1. Terminal 11 runs on PowerShell 7.' Yellow
    $pw = Get-Command pwsh -ErrorAction SilentlyContinue
    $pwPath = $null
    if ($pw) { $pwPath = $pw.Source }
    if (-not $pwPath) { $g = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'; if (Test-Path -LiteralPath $g) { $pwPath = $g } }
    if (-not $pwPath) {
        if (-not (Test-Cmd 'winget')) { Say '  winget not found. Install PowerShell 7 from https://aka.ms/powershell and run this again.' Red; return }
        if (-not (Confirm-Step 'Install PowerShell 7 with winget (Microsoft.PowerShell)?')) { Say '  No changes made.' Yellow; return }
        Write-Host '  installing PowerShell 7 ...' -ForegroundColor Gray
        if (-not (Install-WingetPackage 'Microsoft.PowerShell')) { Say '  winget could not install PowerShell 7.' Red; return }
        Update-SessionPath
        $g = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $g) { $pwPath = $g } else { $pw = Get-Command pwsh -ErrorAction SilentlyContinue; if ($pw) { $pwPath = $pw.Source } }
        if (-not $pwPath) { Say '  PowerShell 7 installed but not found on PATH. Open a new window and run this again.' Yellow; return }
    }
    Say '  Continuing in PowerShell 7 ...' Gray
    if ($PSCommandPath) { & $pwPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath }
    else { & $pwPath -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ("irm '" + $S.Url + "' | iex") }
    return
}

$action = if ($env:T11_ACTION) { $env:T11_ACTION.ToLowerInvariant() } else { 'install' }
if ($action -eq 'uninstall') { Invoke-Uninstall; return }

# --- CHECK-IN ----------------------------------------------------------------
Clear-Host
Show-Banner
Stage 'CHECK-IN' 'Looking at your machine'
$wtPaths = @(Get-WtSettingsPaths)
$hasWt = ($wtPaths.Count -gt 0) -or (Test-Cmd 'wt')
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$prev = Read-Manifest
Say ('  PowerShell   ' + $PSVersionTable.PSVersion) Gray
Say ('  Windows Term ' + $(if ($hasWt) { 'found' } else { 'not found' })) Gray
Say ('  winget       ' + $(if (Test-Cmd 'winget') { 'available' } else { 'not found (tool installs will be skipped)' })) Gray
Say ('  Previous run ' + $(if ($prev) { 'v' + $prev['version'] + ' (answers will be reused)' } else { 'none' })) Gray
if ($isAdmin) { Warn 'Running as Administrator. Not needed: everything installs per-user.' }

$cfg = Get-DefaultConfig
if ($prev -and $prev.ContainsKey('config')) {
    foreach ($k in @($prev['config'].Keys)) { if ($cfg.ContainsKey($k)) { $cfg[$k] = $prev['config'][$k] } }
}

$levelNum = 0
if (-not $S.Interactive) {
    Say '  Unattended: using saved config or recommended defaults.' DarkGray
} else {
    $modeOpts = @()
    if ($prev) { $modeOpts += @{ Value = 'saved'; Label = 'Re-apply saved settings'; Desc = 'update tools and files, no questions' } }
    $modeOpts += @{ Value = 'rec'; Label = 'Recommended'; Desc = 'opinionated defaults, zero questions' }
    $modeOpts += @{ Value = 'cust'; Label = 'Customize'; Desc = 'about 9 quick questions' }
    $modeOpts += @{ Value = 'adv'; Label = 'Advanced'; Desc = 'everything: size, cursor, prediction, aliases...' }
    Stage 'PREFS' 'How much do you want to decide?'
    $r = Read-Menu -Title 'Setup mode' -Options $modeOpts -Default $modeOpts[0].Value
    if ($r.Back) { Say '  No changes made.' Yellow; return }
    if ($r.Value -eq 'rec' -and $prev) { $cfg = Get-DefaultConfig }
    if ($r.Value -eq 'cust') { $levelNum = 1 }
    if ($r.Value -eq 'adv') { $levelNum = 2 }
}

# --- PREFS (wizard) + summary loop -------------------------------------------
while ($true) {
    if ($levelNum -gt 0) {
        $list = @(Get-Steps | Where-Object { $_.Level -le $levelNum })
        $i = 0; $dir = 1
        while ($i -lt $list.Count) {
            $st = $list[$i]
            if ($null -ne $st.When -and -not (& $st.When)) { $i += $dir; if ($i -lt 0) { $i = 0; $dir = 1 }; continue }
            $opts = if ($st.Options -is [scriptblock]) { & $st.Options } else { $st.Options }
            $def = if ($null -ne $st.Default) { & $st.Default } else { $cfg[$st.Key] }
            $r = Read-Menu -Title $st.Title -Options $opts -Default $def -Multi $st.Multi -Step ('Question ' + ($i + 1) + ' of ' + $list.Count)
            if ($r.Back) { $dir = -1; $i = [Math]::Max(0, $i - 1); continue }
            $cfg[$st.Key] = $r.Value
            $dir = 1; $i++
        }
        if ($cfg.font -eq 'keep' -and $cfg.symbols -eq 'nerd') { $cfg.symbols = 'unicode' }
    }

    Stage 'DEPARTURE' 'Review before boarding'
    Show-Summary $cfg $hasWt
    if ($env:T11_DRYRUN) { Say '  T11_DRYRUN is set: stopping here, nothing was changed.' Yellow; return }
    if (-not $S.Interactive) { break }
    $r = Read-Menu -Title 'Ready?' -Options @(
        @{ Value = 'go';   Label = 'Apply configuration' }
        @{ Value = 'redo'; Label = 'Go back and change answers' }
        @{ Value = 'exit'; Label = 'Exit without changes' }) -Default 'go'
    if ($r.Back -or $r.Value -eq 'exit') { Say '  No changes made.' Yellow; return }
    if ($r.Value -eq 'go') { break }
    if ($levelNum -eq 0) { $levelNum = 1 }
}

# --- BOARDING (apply) --------------------------------------------------------
Stage 'BOARDING' 'Installing and configuring'
if (-not $hasWt) {
    if ((Test-Cmd 'winget') -and (Confirm-Step 'Install Windows Terminal (Microsoft.WindowsTerminal)?')) {
        if (Install-WingetPackage 'Microsoft.WindowsTerminal') { Ok 'Windows Terminal installed'; $hasWt = $true } else { Warn 'Could not install Windows Terminal.' }
    } else { Warn 'Windows Terminal not installed: profile is registered anyway and appears once it is.' }
}

Install-Tools $cfg

$fontFace = $null
if ($cfg.font -ne 'keep') {
    $fontFace = Install-NerdFont $cfg.font
    if (-not $fontFace -and $cfg.symbols -eq 'nerd') { $cfg.symbols = 'unicode'; Warn 'No Nerd Font available, so prompt symbols fall back to Unicode.' }
}

try {
    New-Item -ItemType Directory -Path $S.Root -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $S.Root 'cache') -Force | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $S.Root 'cache') -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    Write-IfChanged (Join-Path $S.Root 'profile.ps1') (New-ProfileScript $cfg)
    Ok 'profile.ps1 written'

    $starshipPath = Join-Path $S.Root 'starship.toml'
    $keep = (Test-Path -LiteralPath $starshipPath) -and ((Get-Content -LiteralPath $starshipPath -TotalCount 1) -match 't11:keep')
    if ($keep) { Say '  starship.toml has "# t11:keep" - left as is' Yellow }
    else { Write-IfChanged $starshipPath (New-StarshipToml $cfg); Ok 'starship.toml written' }

    $localPath = Join-Path $S.Root 'local.ps1'
    if (-not (Test-Path -LiteralPath $localPath)) {
        Write-Utf8 $localPath ("# Your Terminal 11 customizations. Loaded last, never overwritten.`n# Examples:`n#   `$env:EDITOR = 'code'`n#   Set-Alias k kubectl`n")
    }
    Write-AgentFiles
    Ok 'AGENTS.md and agent skills written'
} catch { Warn ('Writing config failed: ' + $_.Exception.Message) }

try { Register-WtProfile $cfg $fontFace } catch { Warn ('Could not register the Windows Terminal profile: ' + $_.Exception.Message) }

$previousDefaults = @{}
if ($prev -and $prev.ContainsKey('previousDefaults')) { $previousDefaults = $prev['previousDefaults'] }
if ($cfg.makeDefault) {
    $targets = @(Get-WtSettingsPaths)
    if ($targets.Count -eq 0) { Warn 'Windows Terminal has no settings.json yet (it is created on first launch). Run the installer again after opening Windows Terminal once to make Terminal 11 the default.' }
    foreach ($p in $targets) {
        try {
            $old = Set-WtDefault $p $S.Guid
            if (-not $previousDefaults.ContainsKey($p)) { $previousDefaults[$p] = $old }
            Ok ('default profile set in ' + (Split-Path -Parent (Split-Path -Parent $p) | Split-Path -Leaf))
        } catch { Warn ('Could not set the default profile in ' + $p + ': ' + $_.Exception.Message) }
    }
}

$toolMap = [ordered]@{}
foreach ($t in $Tools) { if ((@($cfg.tools) -contains $t.Id) -or (Test-Cmd $t.Cmd)) { $toolMap[$t.Id] = $t.Cmd } }
$manifest = [ordered]@{
    product = 'Terminal11'; version = $S.Version; installedAt = (Get-Date).ToString('o'); installUrl = $S.Url
    guid = $S.Guid; fontFace = $fontFace; config = $cfg; tools = $toolMap; previousDefaults = $previousDefaults
}
Write-Utf8 (Join-Path $S.Root 'terminal11.json') ($manifest | ConvertTo-Json -Depth 8)

# --- DEPARTURE ---------------------------------------------------------------
Stage 'DEPARTURE' 'Gate open'
Say '  Open Windows Terminal, then pick "Terminal 11" from the dropdown (Ctrl+Shift+1..9 for profile slots).' White
if ($cfg.makeDefault) { Say '  It is also your default profile, so new windows start in it.' Gray }
Say '  Restart Windows Terminal once so the new font and PATH are picked up.' Gray
Say '  Run  t11  inside it for doctor / bench / update / uninstall.' Gray
Say ('  Launch it anywhere:  pwsh -NoProfile -NoExit -Command ". ''' + (Join-Path $S.Root 'profile.ps1') + '''"') DarkGray
if ($S.Warn.Count -gt 0) {
    Write-Host ''
    Say '  Things to look at:' Yellow
    foreach ($w in $S.Warn) { Say ('    - ' + $w) Yellow }
}
Write-Host ''
}
