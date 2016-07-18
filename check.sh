#!/bin/bash
my_dir=`dirname "$0"`
cd $my_dir

exp_fpaths="
CO2MPAS/
Apps/
install.log
README.txt
co2mpas-env.bat
RUN_CO2MPAS.bat
INSTALL.bat
.install.sh
MAKE_TEMPLATE.bat
MAKE_IPYTHON_NOTEBOOKS.bat
MAKE_DEMOS.bat
bash-console.bat
CONSOLE.bat
Apps/graphviz
Apps/WinPython/
Apps/Cygwin/
Apps/Pandoc/
Apps/Console/
Apps/node.js/
Apps/clink/
Apps/gpg4win-2.3.2.exe
Apps/vc_redist.x64.exe
Apps/CO2MPAS_console.ico
Apps/CO2MPAS_logo.ico
Apps/CO2MPAS_play.ico
"

for xxdir in ./*ALLINONE*; do
    for xxfile in $exp_fpaths; do
        xxpath="${xxdir}/${xxfile}"
        #echo "Check: ${xxpath}"
        ls -d "${xxpath}" >/dev/null
    done
done