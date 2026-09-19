#Requires -Version 7.0

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "patch_nerd_fonts.ps1")

function Assert-True($Condition, $Message) {
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Fails([scriptblock]$Action, [string]$Pattern) {
    $failure = $null
    try {
        & $Action
    } catch {
        $failure = $_.Exception.Message
    }
    Assert-True ($failure -match $Pattern) "Expected failure matching '$Pattern', got '$failure'"
}

$progressRecords = [Collections.Generic.List[object]]::new()
function Write-Progress {
    param ($Id, $ParentId, $Activity, $Status, $CurrentOperation, $PercentComplete, [switch]$Completed)
    $progressRecords.Add([pscustomobject]@{
        Id = $Id
        ParentId = $ParentId
        Activity = $Activity
        Status = $Status
        CurrentOperation = $CurrentOperation
        PercentComplete = $PercentComplete
        Completed = [bool]$Completed
    })
    Microsoft.PowerShell.Utility\Write-Progress @PSBoundParameters
}

$root = Join-Path ([IO.Path]::GetTempPath()) "nerd font tests $([guid]::NewGuid().ToString('N'))"
try {
    $inputDirectory = Join-Path $root "input fonts"
    $nerdDirectory = Join-Path $root "nerd fonts"
    $outputDirectory = Join-Path $root "output fonts"
    New-Item -Path $inputDirectory, $nerdDirectory, $outputDirectory -ItemType Directory | Out-Null
    Set-Content -LiteralPath (Join-Path $nerdDirectory "font-patcher") -Value "fixture"
    $fakeScript = Join-Path $root "fake_fontforge.ps1"
    Set-Content -LiteralPath $fakeScript -Value @'
$ErrorActionPreference = "Stop"
$nameIndex = [array]::IndexOf($args, '--name')
$outputIndex = [array]::IndexOf($args, '-out')
$name = $args[$nameIndex + 1]
$outputDirectory = $args[$outputIndex + 1]
$inputPath = $args[$outputIndex - 1]
if (-not (Test-Path -LiteralPath 'font-patcher') -or [IO.Path]::IsPathRooted($outputDirectory)) { exit 8 }
$mode = (Get-Content -LiteralPath $inputPath -Raw).Trim()
if ($mode -eq 'fail') { Write-Output 'Intentional patch failure'; exit 9 }
if ($mode -eq 'missing') { exit 0 }
$filename = if ($mode -eq 'collision') { 'Duplicate.ttf' } else { $name.Replace(' ', '-') + '.ttf' }
Set-Content -LiteralPath (Join-Path $outputDirectory $filename) -Value $inputPath
Write-Output "Patched $name"
'@
    $executable = Join-Path $root "fontforge.cmd"
    $pwsh = (Get-Process -Id $PID).Path
    Set-Content -LiteralPath $executable -Value "@`"$pwsh`" -NoProfile -File `"$fakeScript`" %*"
    $regular = Join-Path $inputDirectory "test-normal.ttf"
    $italic = Join-Path $inputDirectory "test-normalExtraLightItalic.ttf"
    Set-Content -LiteralPath $regular, $italic -Value "ok"
    $parameters = @{
        InputDirectory = $inputDirectory
        OutputDirectory = $outputDirectory
        FamilyName = "Iosemka"
        SourcePrefix = "test-normal"
        FontForgeExecutable = $executable
        NerdFontsDirectory = $nerdDirectory
        MaxParallel = 2
    }
    $messages = [Collections.Generic.List[string]]::new()
    Invoke-NerdFontPatch @parameters 6>&1 | ForEach-Object {
        Assert-True ($_ -is [Management.Automation.InformationRecord]) "Progress leaked into the result stream"
        $message = $_.MessageData.ToString()
        $messages.Add($message)
        if ($message -match '^\[\d+/2\] Patched ') {
            Assert-True (@(Get-ChildItem -LiteralPath $outputDirectory -Filter "*.ttf").Count -eq 0) "Completion progress was delayed until after publishing"
        }
        Write-Host $message
    }
    Assert-True (@($messages | Where-Object { $_ -match '^Starting Iosemka ' }).Count -eq 2) "Missing per-worker start messages"
    foreach ($count in 1..2) {
        Assert-True (@($messages | Where-Object { $_ -match "^\[$count/2\] Patched .*elapsed .*s\)" }).Count -eq 1) "Missing or duplicate completion count $count"
    }
    Assert-True ($messages[0] -match '^Patching 2 fonts') "Missing initial batch message"
    Assert-True ($messages[-1] -match '^Finished Iosemka: 2 fonts in ') "Missing final timing summary"
    Assert-True (($progressRecords | Where-Object { -not $_.Completed } | ForEach-Object PercentComplete) -join ',' -eq '0,50,100,100') "Incorrect native progress percentages"
    Assert-True ($progressRecords[1].Status -match '^1/2 fonts completed; elapsed ') "Native progress is missing counts or elapsed time"
    Assert-True ($progressRecords[1].CurrentOperation -match '^Patched test-') "Native progress is missing the completed filename"
    Assert-True ($progressRecords[-1].Completed) "Native progress was not cleared on success"
    Assert-True (@($progressRecords | Where-Object { $_.ParentId -ne -1 }).Count -eq 0) "Standalone progress should have no parent"
    Assert-True (Test-Path -LiteralPath (Join-Path $outputDirectory "Iosemka-Regular.ttf")) "Missing regular output"
    Assert-True (Test-Path -LiteralPath (Join-Path $outputDirectory "Iosemka-Extra-Light-Italic.ttf")) "Incorrect multiword style or argument quoting"
    Assert-True (@(Get-ChildItem -LiteralPath $root -Directory -Filter ".nerd-fonts-*").Count -eq 0) "Successful work directory was not cleaned up"

    $marker = Join-Path $outputDirectory "previous.txt"
    Set-Content -LiteralPath $marker -Value "keep"
    foreach ($mode in @("fail", "missing", "collision")) {
        $progressRecords.Clear()
        Set-Content -LiteralPath $regular, $italic -Value $mode
        $pattern = if ($mode -eq "collision") { "duplicate output names" } else { "Nerd Fonts patching failed" }
        Assert-Fails { Invoke-NerdFontPatch @parameters } $pattern
        Assert-True (Test-Path -LiteralPath $marker) "A failed batch replaced previous outputs"
        Assert-True ($progressRecords[-1].Completed) "Native progress was not cleared on failure"
        if ($mode -ne "collision") {
            Assert-True (@($progressRecords | Where-Object { $_.CurrentOperation -like 'FAILED *' }).Count -eq 2) "Native progress did not report failed jobs"
        }
    }
    $logs = @(Get-ChildItem -LiteralPath $root -Recurse -Filter "*.log")
    Assert-True ($logs.Count -ge 6) "Failed batches did not retain per-font logs"
    Assert-True ([bool]($logs | Select-String -Pattern "Intentional patch failure")) "Native failure output was not logged"

    $parameters.OutputDirectory = $inputDirectory
    Assert-Fails { Invoke-NerdFontPatch @parameters } "must not overlap"
    $parameters.OutputDirectory = $outputDirectory
    $parameters.MaxParallel = 0
    Assert-Fails { Invoke-NerdFontPatch @parameters } "less than the minimum"
    $parameters.MaxParallel = 2
    Set-Content -LiteralPath (Join-Path $inputDirectory "unexpected.ttf") -Value "ok"
    Assert-Fails { Invoke-NerdFontPatch @parameters } "Unexpected font name"
    Write-Host "Nerd Fonts worker tests passed"
} finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}