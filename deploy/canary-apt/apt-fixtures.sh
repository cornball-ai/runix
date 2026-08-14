#!/bin/bash
# Configure the apt-mutation test fixtures inside the guest. Run IN the guest as
# `ubuntu` (NOPASSWD sudo).
#   - aptbot  (uid 1002): the AUTONOMOUS principal, enrolled in runix-apt-autonomous
#   - aptuser (uid 1003): a NON-member principal (the negative-authorization case)
#   - a local, trusted apt repo (/srv/canary-repo) with harmless test packages:
#       canary-benign     1.0 / 1.1   install / remove / upgrade / hold
#       canary-badpost    1.0         postinst exits 1 (deps satisfied) -> the
#                                     half-configured -> dpkg_broken gate
#       canary-slow       1.0         postinst sleeps -> a catchable window for the
#                                     interrupted-transaction (SIGKILL mid-commit) gate
#       canary-protected  1.0         Priority: required -> protected-removal refusal
#       r-cornball-canary 1.0         matches rapt's ^r-[a-z]+-[a-z0-9.]+$ ->
#                                     ownership (package_not_owned) refusal
# Every package is inert (a marker file, a bounded sleep); nothing here touches a
# real system package.
set -euo pipefail
log() { echo "== $* =="; }
REPO=/srv/canary-repo
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

log "principals: aptbot (autonomous member), aptuser (non-member)"
id aptbot  >/dev/null 2>&1 || sudo useradd -m -u 1002 -s /bin/bash aptbot
id aptuser >/dev/null 2>&1 || sudo useradd -m -u 1003 -s /bin/bash aptuser
sudo gpasswd -a aptbot runix-apt-autonomous >/dev/null
echo "  runix-apt-autonomous members: $(getent group runix-apt-autonomous | cut -d: -f4)"
echo "  aptuser groups: $(id -nG aptuser)"

# build_pkg <name> <version> [priority] [postinst-body]
build_pkg() {
    local name="$1" v="$2" prio="${3:-optional}" post="${4:-}"
    local d="$BUILD/$name-$v"
    mkdir -p "$d/DEBIAN" "$d/usr/share/$name"
    {
        echo "Package: $name"
        echo "Version: $v"
        echo "Architecture: all"
        echo "Priority: $prio"
        echo "Maintainer: canary <root@localhost>"
        echo "Section: misc"
        echo "Description: canary test package ($name)"
        echo " Inert fixture for pkgexec apt-mutation acceptance."
    } > "$d/DEBIAN/control"
    echo "$name $v" > "$d/usr/share/$name/marker"
    if [ -n "$post" ]; then
        printf '#!/bin/sh\n%s\n' "$post" > "$d/DEBIAN/postinst"
        chmod 0755 "$d/DEBIAN/postinst"
    fi
    dpkg-deb --build "$d" "$REPO/${name}_${v}_all.deb" >/dev/null
}

log "build harmless test packages into $REPO"
sudo mkdir -p "$REPO"
sudo chown "$(id -u)":"$(id -g)" "$REPO"
build_pkg canary-benign 1.0
build_pkg canary-benign 1.1
build_pkg canary-badpost 1.0 optional \
    'echo "canary-badpost: postinst failing on purpose" >&2; exit 1'
build_pkg canary-slow 1.0 optional \
    'touch /run/canary-slow.marker; echo "canary-slow: postinst marker set, sleeping"; sleep 30'
build_pkg canary-protected 1.0 required
build_pkg r-cornball-canary 1.0

log "index the local repo (flat, trusted, file://) and prime apt"
# --multiversion so BOTH canary-benign 1.0 and 1.1 are indexed (the default keeps only
# the newest and drops 1.0, which broke the G5 1.0->1.1 upgrade). stderr is NOT hidden,
# so any "ignoring lower version" or malformed-package warning lands in the evidence log.
( cd "$REPO" && dpkg-scanpackages --multiversion . /dev/null > Packages && gzip -9c Packages > Packages.gz )
sudo tee /etc/apt/sources.list.d/canary-repo.sources >/dev/null <<EOF
Types: deb
URIs: file://$REPO
Suites: ./
Trusted: yes
Enabled: yes
EOF
sudo apt-get update -qq
# Prove the refreshed index exposes EXACTLY canary-benign 1.0 and 1.1: a scanpackages
# that silently dropped the older version is precisely the fixture failure G5 exists to
# exercise, so abort here rather than let it surface later as an unexplained empty
# version. apt-cache madison lists every candidate version the index offers.
CBVERS=$(LC_ALL=C apt-cache madison canary-benign 2>/dev/null | awk '{print $3}' | sort -u | tr '\n' ' ' | sed 's/ *$//' || true)
if [ "$CBVERS" != "1.0 1.1" ]; then
    echo "apt-fixtures: FATAL: canary-benign index must expose exactly 1.0 and 1.1 (got '$CBVERS')" >&2
    exit 1
fi
echo "  canary-benign index: $CBVERS (both versions exposed)"
# canary-protected and r-cornball-canary are installed (via plain apt) so the
# protected-removal and ownership refusal gates have present targets.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y canary-protected r-cornball-canary >/dev/null
echo "  canary-benign:      $(apt-cache madison canary-benign | awk '{print $3}' | tr '\n' ' ')"
echo "  canary-protected:   $(dpkg-query -W -f='${Version} (${Priority})' canary-protected 2>/dev/null)"
echo "  r-cornball-canary:  $(dpkg-query -W -f='${Version}' r-cornball-canary 2>/dev/null) (installed)"

# --- inline-Signed-By signed repo (schema-1 signed-by normalization gate) ---------
# A dedicated GPG-signed flat repo whose deb822 source carries an INLINE armored
# public key (not a keyring path). apt.update must fetch AND verify it, so the update
# effector's ListUpdate succeeds and the receipt redeems; the preview and effector
# must both normalize the inline key to inline-sha256:<hex>. The .sources file is
# STAGED at /srv/canary-inline.sources (NOT in sources.list.d); the G-INLINE gate
# copies it in and removes it, so the other update gates keep their existing hash.
log "inline-Signed-By signed repo (signed-by normalization gate)"
sudo apt-get install -y -qq gnupg apt-utils >/dev/null 2>&1 || true
SIGNREPO=/srv/canary-signed
GH="$BUILD/gnupg"; mkdir -p "$GH"; chmod 700 "$GH"
cat > "$BUILD/keyparams" <<'EOF'
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Name-Real: Canary Inline Signer
Name-Email: canary-inline@localhost
Expire-Date: 0
%commit
EOF
GNUPGHOME="$GH" gpg --batch --gen-key "$BUILD/keyparams" >/dev/null 2>&1
sudo mkdir -p "$SIGNREPO"; sudo chown "$(id -u)":"$(id -g)" "$SIGNREPO"
cp "$REPO/canary-benign_1.1_all.deb" "$SIGNREPO/"
( cd "$SIGNREPO" && dpkg-scanpackages --multiversion . /dev/null > Packages && gzip -9c Packages > Packages.gz )
( cd "$SIGNREPO" && apt-ftparchive release . > Release )
GNUPGHOME="$GH" gpg --batch --yes --clearsign -o "$SIGNREPO/InRelease" "$SIGNREPO/Release"
GNUPGHOME="$GH" gpg --batch --yes -abs -o "$SIGNREPO/Release.gpg" "$SIGNREPO/Release"
# Fold the armored public key into a deb822 inline Signed-By (blank lines -> " .",
# every line prefixed with a space), staged out of sources.list.d.
{
    echo "Types: deb"
    echo "URIs: file://$SIGNREPO"
    echo "Suites: ./"
    echo "Enabled: yes"
    echo "Signed-By:"
    GNUPGHOME="$GH" gpg --batch --armor --export canary-inline@localhost \
        | sed -e 's/^[[:space:]]*$/./' -e 's/^/ /'
} | sudo tee /srv/canary-inline.sources >/dev/null
# Prove the staged source refreshes AND verifies before the gate depends on it: a
# broken signature here is exactly the fixture failure G-INLINE would otherwise
# surface as an unexplained update failure, so abort now.
sudo cp /srv/canary-inline.sources /etc/apt/sources.list.d/canary-inline.sources
if sudo apt-get update -o Dir::Etc::sourcelist=/dev/null \
       -o Dir::Etc::sourceparts=/etc/apt/sources.list.d/canary-inline.sources \
       -qq 2>"$BUILD/inline-update.err"; then
    echo "  inline-key repo signed + verified (staged at /srv/canary-inline.sources)"
else
    echo "apt-fixtures: FATAL: inline-key repo did not verify:" >&2
    cat "$BUILD/inline-update.err" >&2
    sudo rm -f /etc/apt/sources.list.d/canary-inline.sources
    exit 1
fi
sudo rm -f /etc/apt/sources.list.d/canary-inline.sources
sudo apt-get update -qq
echo "apt-fixtures: OK"
