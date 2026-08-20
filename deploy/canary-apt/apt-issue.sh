#!/bin/bash
# VM-ONLY wrapper: run the pkgops issuer launcher (apt-issue.R) as the calling
# (unprivileged) principal, so the §7 gates drive the real pkgops public path in
# place of the rab-exercise oracle. Installed by install-apt-stack.sh as
# /usr/local/bin/apt-issue, with apt-issue.R beside it. NEVER packaged.
#
#   apt-issue <verb> <resource> <hash> [pkg...]
#
# --vanilla keeps the run deterministic (no ~/.Renviron / ~/.Rprofile); pkgops is
# found on the default library path where R CMD INSTALL placed it. stdout is exactly
# the one RESULT line apt-issue.R prints (the caller greps '^RESULT ').
set -euo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
exec Rscript --vanilla "$HERE/apt-issue.R" "$@"
