#Requires -Version 7.0

param (
    [switch]$skipIoBuild,
    $nameFilter,
    [ValidateRange(1, 256)][int]$patchJobs = 4,
    [ValidateSet("CascadiaCode", "Monaspace", "VictorMono")][string]$scriptDonor = "CascadiaCode",
    [switch]$skipScript
)

$ErrorActionPreference = "Stop"
$iodir = join-path $PSScriptRoot ".."
. (Join-Path $PSScriptRoot "patch_nerd_fonts.ps1")
Push-Location $iodir
try {

    $plans = Get-Item (join-path $PSScriptRoot "private-build-plans_*.toml")

    if ($plans.Count -eq 0) {
        throw "no plans found"
    }

    $fontforgeCommand = Get-Command "fontforge" -ErrorAction SilentlyContinue
    if (-not $fontforgeCommand) {
        throw "cannot find fontforge";
    }
    if ($fontforgeCommand.CommandType -eq "Alias") {
        $fontforgeCommand = $fontforgeCommand.ResolvedCommand
    }
    if ($fontforgeCommand.CommandType -ne "Application") {
        throw "fontforge must resolve to an executable"
    }
    $fontforgeExecutable = $fontforgeCommand.Path
    $nerdFontsDirectory = Join-Path $PSScriptRoot "..\..\nerd-fonts"
    if (-not (get-command "python" -ErrorAction SilentlyContinue)) {
        throw "cannot find python"
    }

    if (-not (get-command "ttfautohint" -ErrorAction SilentlyContinue)) {
        #https://freetype.org/ttfautohint/
        throw "cannot find ttfautohint"
    }

    write-host "Building plans...";

    function cap($s) {
        return $s[0].ToString().ToUpperInvariant() + $s.Substring(1);
    }


    $planIndex = 0
    foreach($p in $plans) {
        $planIndex++
        $buildProgress = @{
            Id = 0
            Activity = "Processing build plans"
            Status = "Plan $planIndex/$($plans.Count): $($p.BaseName)"
            PercentComplete = ($planIndex - 1) * 100 / $plans.Count
        }
        Write-Progress @buildProgress -CurrentOperation "Reading build plan"

        write-host "Plan file: $p"
        $c = get-content $p -raw;

        if ($c -notmatch "\[buildPlans\.(iosevka-marcus(-.+)?)\]") {
            throw "could not extract name from plan"
        }

        $name = $matches[1];

        if ($c -notmatch "family = (.+)") {
            throw "could not get family"
        }

        $family = ($matches[1]).Trim().Trim('"');

        $newName = "Iosemka";
        if ($family -match "Iosevka Marcus (.+)") {
            # We need to remove the space here so that NerdFonts does not consider it 
            # part of the subfamily. It appears to then correctly insert a space anyway.
            $newName += $matches[1];
        }

        if ($nameFilter -and ($newName -notmatch $nameFilter)) {
            write-host "Skipping $name → $newName ($family)"
            $buildProgress.PercentComplete = $planIndex * 100 / $plans.Count
            Write-Progress @buildProgress -CurrentOperation "Skipped by name filter"
            continue;
        }

        copy-item -Path $p -Destination (Join-Path $PSScriptRoot "..\private-build-plans.toml") -Force;

        if (-not $skipIoBuild) {
            write-host "Building plan $name ($family)"
            Write-Progress @buildProgress -CurrentOperation "Building Iosevka: $newName"

            npm run build -- ttf::$name
            if ($LASTEXITCODE -ne 0) {
                throw "Iosevka build failed for $name (exit $LASTEXITCODE)"
            }
        }

        $patchdir = join-path $iodir "dist\$name\ttf.patched"
        $patchParameters = @{
            InputDirectory = Join-Path $iodir "dist\$name\ttf"
            OutputDirectory = $patchdir
            FamilyName = $newName
            SourcePrefix = "$name-normal"
            FontForgeExecutable = $fontforgeExecutable
            NerdFontsDirectory = $nerdFontsDirectory
            MaxParallel = $patchJobs
            ProgressParentId = 0
        }
        Write-Progress @buildProgress -CurrentOperation "Patching Nerd Fonts: $newName"
        Invoke-NerdFontPatch @patchParameters

        $finaldir = join-path $iodir "dist\$name\ttf.final"
        Write-Host "Adding extra Japanese glyphs for $newName"
        Write-Progress @buildProgress -CurrentOperation "Adding Japanese glyphs: $newName"
        & $fontforgeExecutable -lang=py -script (join-path $PSScriptRoot "extra_glyphs.py") --input-dir $patchdir --output-dir $finaldir
        if ($LASTEXITCODE -ne 0) {
            throw "Extra glyph patching failed for $name (exit $LASTEXITCODE)"
        }
        Write-Host "Finished $newName -> $finaldir"

        if ($name -eq "iosevka-marcus-cond" -and -not $skipScript) {
            $scriptBase = Join-Path $iodir "dist\iosemka-script-$scriptDonor"
            Write-Host "Creating Script fonts with $scriptDonor"
            Write-Progress @buildProgress -CurrentOperation "Creating Script fonts: $scriptDonor"
            & $fontforgeExecutable -lang=py -script (Join-Path $PSScriptRoot "create_italic_script_font.py") --donor $scriptDonor --input-dir $patchdir --output-dir "$scriptBase.unpatched" --defer-extra-glyphs
            if ($LASTEXITCODE -ne 0) {
                throw "Script font generation failed for $scriptDonor (exit $LASTEXITCODE)"
            }
            $patchParameters.InputDirectory = "$scriptBase.unpatched"
            $patchParameters.OutputDirectory = "$scriptBase.patched"
            $patchParameters.FamilyName = "IosemkaScript"
            $patchParameters.SourcePrefix = "IosemkaScript-"
            Write-Progress @buildProgress -CurrentOperation "Patching Nerd Fonts: IosemkaScript ($scriptDonor)"
            Invoke-NerdFontPatch @patchParameters

            Write-Host "Adding extra Japanese glyphs for IosemkaScript ($scriptDonor)"
            Write-Progress @buildProgress -CurrentOperation "Adding Japanese glyphs: IosemkaScript ($scriptDonor)"
            & $fontforgeExecutable -lang=py -script (Join-Path $PSScriptRoot "extra_glyphs.py") --input-dir "$scriptBase.patched" --output-dir "$scriptBase.final"
            if ($LASTEXITCODE -ne 0) {
                throw "Script extra glyph patching failed for $scriptDonor (exit $LASTEXITCODE)"
            }
            Write-Host "Finished IosemkaScript ($scriptDonor) -> $scriptBase.final"
        }
        $buildProgress.PercentComplete = $planIndex * 100 / $plans.Count
        Write-Progress @buildProgress -CurrentOperation "Finished $newName"
    }

    write-host "Done"
} finally {
    Write-Progress -Id 0 -Activity "Processing build plans" -Completed
    Pop-Location
}
