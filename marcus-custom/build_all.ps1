param ([switch]$skipIoBuild, $nameFilter)

$ErrorActionPreference = "Stop"
$iodir = join-path $PSScriptRoot ".."
Push-Location $iodir
try {

    $plans = Get-Item (join-path $PSScriptRoot "private-build-plans_*.toml")

    if ($plans.Count -eq 0) {
        throw "no plans found"
    }

    if (-not (get-command "fontforge" -ErrorAction SilentlyContinue)) {
        throw "cannot find fontforge";
    }
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


    foreach($p in $plans) {

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
            continue;
        }

        copy-item -Path $p -Destination (Join-Path $PSScriptRoot "..\private-build-plans.toml") -Force;

        if (-not $skipIoBuild) {
            write-host "Building plan $name ($family)"

            npm run build -- ttf::$name
            if ($LASTEXITCODE -ne 0) {
                throw "Iosevka build failed for $name (exit $LASTEXITCODE)"
            }
        }

        write-host "Patching with Nerd font"

        $fontfiles = get-item (join-path $PSScriptRoot "..\dist\$name\ttf\*.ttf");
        if ($fontfiles.Count -eq 0) {
            throw "could not find any font files"
        }

        $patchdir = join-path $PSScriptRoot "..\dist\$name\ttf.patched";
        if (Test-Path -LiteralPath $patchdir) {
            Remove-Item -LiteralPath $patchdir -Recurse -force;
        }
        New-Item -Path $patchdir -ItemType Directory | out-null;

        # note: not sure what the status of the bundled nerd-fonts folder is, this looks for the
        # full nerd-fonts repo (same level as this repo)
        # NOTE: you also need to change the dist path below
        Push-Location (join-path $PSScriptRoot "..\..\nerd-fonts")
        try {
            foreach($ff in $fontfiles) {

                $part = (get-item $ff).BaseName

                if ($part -notmatch "-([^-]+)`$") {
                    throw "unexpected format $ff ($part)"
                }

                $part = $matches[1]

                if (!$part.StartsWith("normal")) {
                    throw "expected part to end with 'normal'";
                }

                $part = $part.Substring("normal".Length)

                $currentName = $newName;

                if ($part.Length) {
            
                    $m = [regex]::Matches($part, "[A-Z][a-z]+");

                    if ($m.Count -eq 0) {
                        throw "expected subfamily matches"
                    }

                    $currentName += " " + ($m -join " ")
                } else {
                    # nerdfont needs this, or it may see "Condensed" as a subfamily
                    $currentName += " Regular"
                }

                write-host "Name to use is $currentName"

                # note: absolute -out causes error
                # path with included nerd-fonts: ..\..\dist\$name\ttf.patched
                fontforge -script font-patcher --name $currentName --complete --quiet $ff -out ..\Iosevka\dist\$name\ttf.patched | out-null;
                if ($LASTEXITCODE -ne 0) {
                    throw "Nerd Fonts patching failed for $ff (exit $LASTEXITCODE)"
                }
            }
        } finally {
            Pop-Location
        }

        $finaldir = join-path $iodir "dist\$name\ttf.final"
        fontforge -lang=py -script (join-path $PSScriptRoot "extra_glyphs.py") --input-dir $patchdir --output-dir $finaldir
        if ($LASTEXITCODE -ne 0) {
            throw "Extra glyph patching failed for $name (exit $LASTEXITCODE)"
        }
    }

    write-host "Done"
} finally {
    Pop-Location
}
