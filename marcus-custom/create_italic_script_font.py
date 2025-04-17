import fontforge
import sys
import os
import re

use_monaspace = False

script_font_dir = R"D:\git\Iosevka\marcus-custom\monaspace" if use_monaspace else R"D:\git\Iosevka\marcus-custom\cascadia_frozen"

# note: nerd font has issues at the moment with naming which does not work with VS
# so we don't support a nerd patch here atm
target_font_dir = R"D:\git\Iosevka\dist\iosevka-marcus-cond\ttf.patched"
output_font_dir = R"D:\git\Iosevka\dist\iosemka-script" if use_monaspace else R"D:\git\Iosevka\dist\iosemka-script-cascadia-new"


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
            scriptFont = "MonaspaceRadonFrozen-" + style + ".ttf" if use_monaspace else "CascadiaCode-" + style + ".ttf"
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
            font.transform(psMat.scale(1.1))
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