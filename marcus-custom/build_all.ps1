param ([switch]$skipIoBuild)

$iodir = join-path $PSScriptRoot "..\Iosevka"
Push-Location $iodir
trap { pop-location }

$plans = Get-Item "private-build-plans_*.toml"

if ($plans.Count -eq 0) {
    throw "no plans found in $iodir"
}

if (-not (get-command "fontforge" -ErrorAction SilentlyContinue)) {
    throw "cannot find fontforge";
}
if (-not (get-command "python" -ErrorAction SilentlyContinue)) {
    throw "cannot find python"
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

    copy-item -Path $p -Destination (Join-Path $PSScriptRoot "..\Iosevka\private-build-plans.toml") -Force;

    $family = ($matches[1]).Trim().Trim('"');

    $newName = "Iosemka";
    if ($family -match "Iosevka Marcus (.+)") {
        $newName += (" " + $matches[1]);
    }

    if (-not $skipIoBuild) {
        write-host "Building plan $name ($family)"

        push-location (join-path $PSScriptRoot "..\Iosevka")
       npm run build -- ttf::$name
    }

    write-host "Patching with Nerd font"

    $fontfiles = get-item (join-path $PSScriptRoot "..\Iosevka\dist\$name\ttf\*.ttf");
    if ($fontfiles.Count -eq 0) {
        throw "could not find any font files"
    }

    $patchdir = join-path $PSScriptRoot "..\Iosevka\dist\$name\ttf.patched";
    Remove-Item -Path $patchdir -Recurse -force -ErrorAction SilentlyContinue;
    New-Item -Path $patchdir -ItemType Directory -ErrorAction SilentlyContinue | out-null;

    Push-Location (join-path $PSScriptRoot "..\nerd-fonts\FontPatcher")
    foreach($ff in $fontfiles) {

        $part = (get-item $ff).BaseName

        if ($part -notmatch "-([^-]+)`$") {
            throw "unexpected format $ff ($part)"
        }

        $part = $matches[1]

        $currentName = $newName;
        while($part -match "extra|semibold|bold|italic|oblique|light|heavy|medium|regular|thin") {
            $currentName += " " + (cap $matches[0])
            $part = $part.Substring($matches[0].Length);
        }

        if ($part.Length -ne 0) {
            throw "part remaning: $part"
        }

        write-host "Name to use is $currentName"

        # note: absolute -out causes error
        fontforge -script font-patcher --name $currentName --complete --quiet $ff -out ..\..\Iosevka\dist\$name\ttf.patched | out-null;
    }
}

Push-Location $PSScriptRoot
write-host "Done"