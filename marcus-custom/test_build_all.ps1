#Requires -Version 7.0

$ErrorActionPreference = "Stop"

function Assert-True($Condition, $Message) {
    if (-not $Condition) {
        throw $Message
    }
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

$root = Join-Path ([IO.Path]::GetTempPath()) "font build tests $([guid]::NewGuid().ToString('N'))"
$previousLog = $env:FONT_BUILD_TEST_LOG
$previousFailure = $env:FONT_BUILD_TEST_FAIL_SCRIPT
$originalLocation = (Get-Location).Path
try {
    $repo = Join-Path $root "Iosevka"
    $custom = Join-Path $repo "marcus-custom"
    $nerd = Join-Path $root "nerd-fonts"
    $env:FONT_BUILD_TEST_LOG = Join-Path $root "events"
    $env:FONT_BUILD_TEST_FAIL_SCRIPT = ""
    New-Item -Path $custom, $nerd, $env:FONT_BUILD_TEST_LOG -ItemType Directory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "build_all.ps1"), (Join-Path $PSScriptRoot "patch_nerd_fonts.ps1") -Destination $custom
    Set-Content -LiteralPath (Join-Path $nerd "font-patcher") -Value "fixture"
    Set-Content -LiteralPath (Join-Path $custom "private-build-plans_condensed.toml") -Value "[buildPlans.iosevka-marcus-cond]`nfamily = `"Iosevka Marcus Condensed`""
    Set-Content -LiteralPath (Join-Path $custom "private-build-plans_normal.toml") -Value "[buildPlans.iosevka-marcus]`nfamily = `"Iosevka Marcus`""
    foreach ($plan in @("iosevka-marcus-cond", "iosevka-marcus")) {
        $inputDirectory = Join-Path $repo "dist\$plan\ttf"
        New-Item -Path $inputDirectory -ItemType Directory -Force | Out-Null
        foreach ($style in @("", "Italic")) {
            Set-Content -LiteralPath (Join-Path $inputDirectory "$plan-normal$style.ttf") -Value "original"
        }
    }
    $fakeScript = Join-Path $root "fake_fontforge.ps1"
    Set-Content -LiteralPath $fakeScript -Value @'
$ErrorActionPreference = "Stop"
$scriptName = Split-Path $args[[array]::IndexOf($args, '-script') + 1] -Leaf
if ($scriptName -eq 'font-patcher') {
    $name = $args[[array]::IndexOf($args, '--name') + 1]
    if ($name.StartsWith('IosemkaScript ') -and $env:FONT_BUILD_TEST_FAIL_SCRIPT) { exit 9 }
    $outputDirectory = $args[[array]::IndexOf($args, '-out') + 1]
    $inputPath = $args[[array]::IndexOf($args, '-out') - 1]
    $family, $style = $name -split ' ', 2
    Set-Content -LiteralPath (Join-Path $outputDirectory "$family-$($style.Replace(' ', '')).ttf") -Value "nerd:$(Get-Content -LiteralPath $inputPath -Raw)"
} else {
    $inputDirectory = $args[[array]::IndexOf($args, '--input-dir') + 1]
    $outputDirectory = $args[[array]::IndexOf($args, '--output-dir') + 1]
    $fonts = @(Get-ChildItem -LiteralPath $inputDirectory -Filter '*.ttf')
    if ($fonts.Count -ne 2) { throw 'Stage started before all fonts were ready' }
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
    foreach ($font in $fonts) {
        if ($scriptName -eq 'create_italic_script_font.py') {
            if ($args -notcontains '--defer-extra-glyphs') { throw 'Missing intermediate mode' }
            if ($args[[array]::IndexOf($args, '--donor') + 1] -ne 'Monaspace') { throw 'Donor option was not forwarded' }
            Set-Content -LiteralPath (Join-Path $outputDirectory $font.Name.Replace('Condensed', 'Script')) -Value 'donor'
        } elseif ($scriptName -eq 'extra_glyphs.py') {
            $content = Get-Content -LiteralPath $font.FullName -Raw
            if (-not $content.StartsWith('nerd:')) { throw 'Extra glyphs ran before Nerd patching' }
            Set-Content -LiteralPath (Join-Path $outputDirectory $font.Name) -Value "extra:$content"
        } else {
            throw "Unexpected script $scriptName"
        }
    }
}
@{ Script = $scriptName; Output = $outputDirectory } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:FONT_BUILD_TEST_LOG "$([guid]::NewGuid()).json")
'@
    $executable = Join-Path $root "fontforge.cmd"
    $pwsh = (Get-Process -Id $PID).Path
    Set-Content -LiteralPath $executable -Value "@`"$pwsh`" -NoProfile -File `"$fakeScript`" %*"
    Set-Alias -Name fontforge -Value $executable
    Set-Alias -Name python -Value $executable
    Set-Alias -Name ttfautohint -Value $executable
    $build = Join-Path $custom "build_all.ps1"
    & $build -skipIoBuild -nameFilter Condensed -patchJobs 2 -scriptDonor Monaspace
    $finalDirectory = Join-Path $repo "dist\iosemka-script-Monaspace.final"
    foreach ($style in @("Regular", "Italic")) {
        $content = Get-Content -LiteralPath (Join-Path $finalDirectory "IosemkaScript-$style.ttf") -Raw
        Assert-True ($content.StartsWith("extra:nerd:donor")) "Incorrect Script stage ordering"
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo "dist\iosevka-marcus\ttf.patched"))) "nameFilter did not skip the normal plan"
    Assert-True ((Get-Location).Path -eq $originalLocation) "Build did not restore its working directory"
    $overall = @($progressRecords | Where-Object { $_.Id -eq 0 -and -not $_.Completed })
    Assert-True ($overall[0].PercentComplete -eq 0 -and $overall[-1].PercentComplete -eq 100) "Overall progress did not include completed and skipped plans"
    Assert-True (@($overall | Where-Object CurrentOperation -like 'Creating Script fonts:*').Count -eq 1) "Overall progress did not show the Script stage"
    $children = @($progressRecords | Where-Object Id -eq 1)
    Assert-True ($children.Count -gt 0 -and @($children | Where-Object ParentId -ne 0).Count -eq 0) "Nerd patching progress was not nested under the build"
    Assert-True ($progressRecords[-1].Id -eq 0 -and $progressRecords[-1].Completed) "Overall progress was not cleared on success"

    Get-ChildItem -LiteralPath $env:FONT_BUILD_TEST_LOG | Remove-Item
    & $build -skipIoBuild -nameFilter '^Iosemka$' -patchJobs 1 -scriptDonor Monaspace
    $events = @(Get-ChildItem -LiteralPath $env:FONT_BUILD_TEST_LOG | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
    Assert-True (@($events | Where-Object Script -eq "create_italic_script_font.py").Count -eq 0) "Script ran without the condensed plan"

    Get-ChildItem -LiteralPath $env:FONT_BUILD_TEST_LOG | Remove-Item
    & $build -skipIoBuild -nameFilter Condensed -patchJobs 2 -skipScript
    $events = @(Get-ChildItem -LiteralPath $env:FONT_BUILD_TEST_LOG | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
    Assert-True (@($events | Where-Object Script -eq "create_italic_script_font.py").Count -eq 0) "skipScript did not skip generation"

    Get-ChildItem -LiteralPath $env:FONT_BUILD_TEST_LOG | Remove-Item
    $env:FONT_BUILD_TEST_FAIL_SCRIPT = "1"
    $progressRecords.Clear()
    $failure = $null
    try {
        & $build -skipIoBuild -nameFilter Condensed -patchJobs 2 -scriptDonor Monaspace
    } catch {
        $failure = $_.Exception.Message
    }
    Assert-True ($failure -match "Nerd Fonts patching failed") "Script patching failure was not propagated"
    $events = @(Get-ChildItem -LiteralPath $env:FONT_BUILD_TEST_LOG | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
    Assert-True (@($events | Where-Object { $_.Script -eq "extra_glyphs.py" -and $_.Output -eq $finalDirectory }).Count -eq 0) "Script final stage ran after failed patching"
    Assert-True ((Get-Location).Path -eq $originalLocation) "Failed build did not restore its working directory"
    Assert-True ($progressRecords[-1].Id -eq 0 -and $progressRecords[-1].Completed) "Overall progress was not cleared on failure"
    Assert-True ($progressRecords[-2].Id -eq 1 -and $progressRecords[-2].Completed) "Child progress was not cleared before the failed build's progress"
    Write-Host "Build pipeline tests passed"
} finally {
    $env:FONT_BUILD_TEST_LOG = $previousLog
    $env:FONT_BUILD_TEST_FAIL_SCRIPT = $previousFailure
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}