#!/bin/bash
# ------------------------------------------------------------------------------
# Double-click this file in Finder to start uFVS in a Terminal window.
#
# Use this instead of uFVS.app when you want to watch the output, or when
# something is going wrong and you need to see the error.
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

MISSING=$("$RSCRIPT" -e 'p <- c("shiny","ggplot2","jsonlite","DBI","RSQLite","readxl","callr"); m <- p[!p %in% rownames(installed.packages())]; cat(paste(m, collapse=" "))')
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
