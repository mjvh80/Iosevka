import fontforge
import sys
import os
import re

use_monaspace = False

script_font_name = "CascadiaCode" # "VictorMono" # "Monaspace" if use_monaspace else "CascadiaCode"

script_font_dir = "S:\\git\\Iosevka\\marcus-custom\\"
script_font_prefix = ""

scale = 1.1

if script_font_name == "Monaspace":
    script_font_dir += "monaspace"
    script_font_prefix = "MonaspaceRadonFrozen-"
elif script_font_name == "CascadiaCode":
    script_font_dir += "cascadia_frozen"
    script_font_prefix = "CascadiaCode-"
else:
    script_font_dir += "victor_mono"
    script_font_prefix = "VictorMono-"
    scale = 1.0

# note: nerd font has issues at the moment with naming which does not work with VS
# so we don't support a nerd patch here atm
target_font_dir = R"S:\git\Iosevka\dist\iosevka-marcus-cond\ttf.patched"
output_font_dir = R"S:\git\Iosevka\dist\iosemka-script-" + script_font_name # if use_monaspace else R"D:\git\Iosevka\dist\iosemka-script-cascadia-new"

if not os.path.exists(target_font_dir):
    raise Exception("Target font directory not found: " + target_font_dir)

# create output dir if not found
if not os.path.exists(output_font_dir):
    os.makedirs(output_font_dir)

# Process target fonts, either copying them or replacing them.
# enumerate the directory
for root, dirs, files in os.walk(target_font_dir):
    for file in files:
        if not file.startswith("IosemkaCondensed-"):
            raise Exception("Invalid font found in target directory: " + file )

        style = file[len("IosemkaCondensed-"):-4]

        print("processing file " + file + " style = " + style)

        source_font = fontforge.open(os.path.join(root, file))

        if style.endswith("Italic"):
           
           
            # scriptFont = "MonaspaceRadonFrozen-" + style + ".ttf" if use_monaspace else "CascadiaCode-" + style + ".ttf"

#            scriptFont = ("MonaspaceRadonFrozen-" + style + ".ttf") if script_font_name == "monaspace" else ("CascadiaCode-" + style + ".ttf") if script_font_name == "cascadia_frozen" else None

            if script_font_name == "CascadiaCode" and style == "Italic":
                # use Light Italic glyphs for Italic style as Cascadia Code is a bit heavy
                scriptFont = "CascadiaCode-LightItalic.ttf"
            else:
                scriptFont = script_font_prefix + style + ".ttf"

           # elseif script_font_name == "Monaspace":

           # if scriptFont == "VictorMono-Italic.ttf":
            #    scriptFont = "VictorMono-MediumItalic.ttf"
            

#            if scriptFont == "VictorMono-Italic.ttf":
 #               scriptFont = "VictorMono-MediumItalic.ttf"

            if os.path.exists(os.path.join(script_font_dir, scriptFont)):
                font = fontforge.open(os.path.join(script_font_dir, scriptFont))
            else:
                print ("script font " + scriptFont + " not found, skipping")
                continue
            # else: we ignore this italic font
        else:
            font = fontforge.open(os.path.join(root, file))

        font.fontname = source_font.fontname.replace("Condensed", "Script")
        font.familyname = source_font.familyname.replace("Condensed", "Script")
        font.fullname = source_font.fullname.replace("Condensed", "Script")
        font.sfntRevision = source_font.sfntRevision

        # copy over sfnt_names but replace Condensed with Script
        sfnt_names = []
        for item in source_font.sfnt_names:
            #if item[1] == "Preferred Family":
            #    sfnt_names += [(item[0], item[1], "Iosemka Script")] # bug in nerd font patch
            #else:
            sfnt_names += [(item[0], item[1], item[2].replace("Condensed", "Script"))]
        font.sfnt_names = tuple(sfnt_names) 


        # If we are using say Light Italic, names don't match and older Windows APIs choke.
        font.os2_weight    = source_font.os2_weight
        font.os2_width     = source_font.os2_width
        font.os2_stylemap  = source_font.os2_stylemap
        font.os2_panose    = source_font.os2_panose


        
        # font.fullname = "Iosemka Script" + full_name_suffix

        # font.sfntRevision = 42.3 # any number again

        # font.sfnt_names = [
        #     ('English (US)', 'Version', "Version 42"), # just picking something but same number for all 
        #     ('English (US)', 'Family', 'Iosemka Script'),
        #     ('English (US)', 'SubFamily', subfamily),
        #     ('English (US)', 'Fullname', "Iosemka Script" + full_name_suffix),
        #     ('English (US)', 'PostScriptName', "Iosemka-Script" + ps_name),
        #     ('English (US)', 'Preferred Family', "Iosemka Script"),
        #     ('English (US)', 'Preferred Styles', "Condensed " + subfamily),
        #     ('English (US)', 'UniqueID', 'Iosemka Script 42')
        # ]

        should_change_em = True

        if font != source_font and should_change_em:               

            font.em = source_font.em

            # cleanup
            font.selection.all()

            # todo: we need to fix clipping
            font.transform(psMat.scale(scale))
            #print("box before = " + str(box) + " after = " + str(font.boundingBox()))

            font.removeOverlap()
            font.round()
            font.addExtrema()
            font.correctDirection()

        output_path = os.path.join(output_font_dir, "IosemkaScript-" + style + ".ttf")

        font.generate(output_path)
        font.close()

        if font != source_font:
            source_font.close()

print("done")