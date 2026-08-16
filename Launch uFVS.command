#!/bin/bash
# ------------------------------------------------------------------------------
# DEVELOPMENT launcher. It uses the R installed on this machine and the
# packages in your own R library, and runs the source checkout it sits in.
#
# It is not what a released uFVS.app does: that carries its own R runtime and
# never looks at a system R. See docs/RELEASE_BUILD.md.
#
# Press Ctrl-C in the Terminal window to stop the application.
# ------------------------------------------------------------------------------

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

RSCRIPT=""
for candidate in \
  /Library/Frameworks/R.framework/Resources/bin/Rscript \
  /usr/local/bin/Rscript \
  /opt/homebrew/bin/Rscript \
  "$(command -v Rscript 2>/dev/null)"
do
  if [ -x "$candidate" ]; then RSCRIPT="$candidate"; break; fi
done

if [ -z "$RSCRIPT" ]; then
  echo "R is not installed, or this script cannot find it."
  echo "Install R from https://cran.r-project.org and try again."
  echo
  read -r -p "Press Return to close this window."
  exit 1
fi

MISSING=$("$RSCRIPT" -e 'p <- c("shiny","ggplot2","jsonlite","DBI","RSQLite","readxl","callr","digest"); m <- p[!p %in% rownames(installed.packages())]; cat(paste(m, collapse=" "))')
if [ -n "$MISSING" ]; then
  echo "uFVS needs these R packages: $MISSING"
  read -r -p "Install them now? [y/N] " reply
  case "$reply" in
    [Yy]*) "$RSCRIPT" -e "install.packages(strsplit('$MISSING',' ')[[1]], repos='https://cloud.r-project.org')" ;;
    *) echo "Cannot start without them."; read -r -p "Press Return to close."; exit 1 ;;
  esac
fi

echo "Starting uFVS. Your browser will open shortly."
echo "Press Ctrl-C here to stop it."
echo

"$RSCRIPT" tools/launch.R

echo
read -r -p "uFVS has stopped. Press Return to close this window."
