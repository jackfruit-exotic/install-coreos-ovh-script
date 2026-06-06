#!/usr/bin/env bash
#
# wizard.sh — Interactive installer for Fedora CoreOS + Docker + Tailscale
#             on an OVH VPS / dedicated server booted in rescue mode.
#
# Runs LOCALLY on your Linux machine and drives the whole flow over SSH.
# The procedure spans 3 environments across 2 reboots:
#
#   1. Local        — collect config, build the Ignition file (needs podman)
#   2. Rescue box   — install CoreOS to disk via coreos-installer (root@IP, password)
#   3. CoreOS box   — layer Docker+Tailscale, reboot, then finalize (core@IP, ssh key)
#
# Each step is a menu entry, so you can resume after a reboot. Answers are
# saved to ./.env (gitignored). The Tailscale auth key is NEVER written to disk.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths & constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="$SCRIPT_DIR/profiles"          # one <name>.env per server
BACKUP_DIR="$PROFILES_DIR/.backups"          # timestamped auto-backups
STATE_FILE="$SCRIPT_DIR/.active-profile"     # remembers the last-used profile
SSH_CTRL="$SCRIPT_DIR/.ssh-rescue.sock"
BACKUP_KEEP=10                               # backups retained per profile

# Per-profile paths, (re)computed by set_profile_paths when the profile changes.
PROFILE=""; ENV_FILE=""; IGN_FILE=""; BU_FILE=""; LOG_FILE=""

BUTANE_IMAGE="quay.io/coreos/butane:release"
# (the coreos-installer image is referenced inline in step 3's remote heredoc,
#  which can't expand shell vars — so there's no constant for it here)

# ---------------------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
  C_RESET=; C_BOLD=; C_DIM=; C_BLUE=; C_GREEN=; C_YELLOW=; C_RED=
fi

# _log appends an ANSI-stripped, timestamped line to the active profile's log
# (no-op until a profile sets LOG_FILE). log() is the public "note only" form.
_log() {
  [[ -n "${LOG_FILE:-}" ]] || return 0
  local clean; clean="$(printf '%s' "$1" | sed -E 's/\x1b\[[0-9;]*m//g')"
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$clean" >> "$LOG_FILE" 2>/dev/null || true
}
log() { _log "$1"; }

banner() { printf '\n%s%s== %s ==%s\n' "$C_BOLD" "$C_BLUE" "$1" "$C_RESET"; _log "== $1 =="; }
info()   { printf '%s•%s %s\n' "$C_BLUE" "$C_RESET" "$1";   _log "INFO $1"; }
ok()     { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1";  _log "OK   $1"; }
warn()   { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; _log "WARN $1"; }
err()    { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; _log "ERR  $1"; }
die()    { err "$1"; exit 1; }

# ask VAR "Prompt" "default"
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __reply
  if [[ -n "$__default" ]]; then
    read -r -p "$(printf '%s%s%s [%s]: ' "$C_BOLD" "$__prompt" "$C_RESET" "$__default")" __reply || true
    __reply="${__reply:-$__default}"
  else
    read -r -p "$(printf '%s%s%s: ' "$C_BOLD" "$__prompt" "$C_RESET")" __reply || true
  fi
  printf -v "$__var" '%s' "$__reply"
}

confirm() { # confirm "Question?" [default y|n]  -> returns 0 if yes
  local __reply __def="${2:-n}" __hint
  [[ "$__def" == y ]] && __hint="[Y/n]" || __hint="[y/N]"
  read -r -p "$(printf '%s%s%s %s: ' "$C_BOLD" "$1" "$C_RESET" "$__hint")" __reply || true
  __reply="${__reply:-$__def}"
  [[ "$__reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ---------------------------------------------------------------------------
# Profiles & persistence
#   Each server is a profile saved as profiles/<name>.env (non-secrets only).
#   Secrets (console password hash, Tailscale auth key) are NEVER persisted.
#   Every save auto-backs-up the previous version to profiles/.backups/.
# ---------------------------------------------------------------------------
# Persisted (non-secret) settings:
SSH_PUBKEY=""; SSH_KEY_PATH=""; TARGET_IP=""; FCOS_HOSTNAME=""
CORE_USER="core"; NET_IFACE="auto"; RESCUE_USER="root"
RESCUE_AUTH="password"      # how to log into OVH rescue: "password" or "key"
RESCUE_KEY_PATH=""          # private key for rescue when RESCUE_AUTH=key (blank = default keys)
STREAM="stable"            # Fedora CoreOS update stream: stable | testing | next (no LTS)
# Day-2 server management state (persisted):
SSH_PUBLIC="yes"           # "yes" = port 22 open to internet; "no" = Tailscale-only
FW_CLOSED=""               # comma list of closed ports, e.g. "8080/tcp,53/udp"
MGMT_HOST=""               # host coreos_ssh connects to (blank = TARGET_IP; set to Tailscale IP when SSH restricted)
# In-memory only (never written anywhere): console password hash, rescue password.
PASSWORD_HASH=""; RESCUE_PASSWORD=""

reset_settings() { # restore defaults before loading/creating a profile
  SSH_PUBKEY=""; SSH_KEY_PATH=""; TARGET_IP=""; FCOS_HOSTNAME=""
  CORE_USER="core"; NET_IFACE="auto"; RESCUE_USER="root"; PASSWORD_HASH=""
  RESCUE_AUTH="password"; RESCUE_KEY_PATH=""; STREAM="stable"
  SSH_PUBLIC="yes"; FW_CLOSED=""; MGMT_HOST=""
}

sanitize_name() { local s="${1//[^A-Za-z0-9_.-]/-}"; s="${s##-}"; printf '%s' "${s:-default}"; }

set_profile_paths() {
  ENV_FILE="$PROFILES_DIR/$PROFILE.env"
  IGN_FILE="$PROFILES_DIR/$PROFILE.ign"
  BU_FILE="$PROFILES_DIR/$PROFILE.rendered.bu"
  LOG_FILE="$PROFILES_DIR/$PROFILE.log"
}

list_profiles() { # one profile name per line, newest-first
  local f; shopt -s nullglob
  for f in "$PROFILES_DIR"/*.env; do printf '%s\n' "$(basename "$f" .env)"; done
  shopt -u nullglob
}

profile_summary() { # "hostname @ ip" read from a profile file (isolated subshell)
  ( TARGET_IP=""; FCOS_HOSTNAME=""; source "$1" 2>/dev/null
    printf '%s @ %s' "${FCOS_HOSTNAME:-?}" "${TARGET_IP:-?}" )
}

load_profile() { # PROFILE must be set
  reset_settings
  set_profile_paths
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || true
  printf '%s' "$PROFILE" > "$STATE_FILE"
}

save_env() {
  [[ -n "$PROFILE" ]] || { warn "No active profile."; return 1; }
  mkdir -p "$PROFILES_DIR"; set_profile_paths
  umask 077
  # Auto-backup the previous version, then rotate to the newest $BACKUP_KEEP.
  if [[ -f "$ENV_FILE" ]]; then
    mkdir -p "$BACKUP_DIR"
    cp -p "$ENV_FILE" "$BACKUP_DIR/${PROFILE}-$(date +%Y%m%d-%H%M%S).env"
    list_backups "$PROFILE" | tail -n +$((BACKUP_KEEP + 1)) | while read -r old; do
      rm -f "$BACKUP_DIR/$old"
    done
  fi
  cat > "$ENV_FILE" <<EOF
# install-coreos profile '$PROFILE' — saved $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Gitignored. Secrets (console password, Tailscale auth key) are NOT stored here.
SSH_PUBKEY=$(printf '%q' "$SSH_PUBKEY")
SSH_KEY_PATH=$(printf '%q' "$SSH_KEY_PATH")
TARGET_IP=$(printf '%q' "$TARGET_IP")
FCOS_HOSTNAME=$(printf '%q' "$FCOS_HOSTNAME")
CORE_USER=$(printf '%q' "$CORE_USER")
NET_IFACE=$(printf '%q' "$NET_IFACE")
RESCUE_USER=$(printf '%q' "$RESCUE_USER")
RESCUE_AUTH=$(printf '%q' "$RESCUE_AUTH")
RESCUE_KEY_PATH=$(printf '%q' "$RESCUE_KEY_PATH")
STREAM=$(printf '%q' "$STREAM")
SSH_PUBLIC=$(printf '%q' "$SSH_PUBLIC")
FW_CLOSED=$(printf '%q' "$FW_CLOSED")
MGMT_HOST=$(printf '%q' "$MGMT_HOST")
EOF
  printf '%s' "$PROFILE" > "$STATE_FILE"
  ok "Saved profile '$PROFILE' → ${ENV_FILE/#$HOME/\~}  (previous version backed up)"
}

list_backups() { # list_backups <profile>  -> backup filenames, newest-first
  local p="$1"; shopt -s nullglob
  local files=("$BACKUP_DIR/${p}-"*.env)
  shopt -u nullglob
  ((${#files[@]})) || return 0
  ls -1t "${files[@]}" 2>/dev/null | xargs -r -n1 basename
}

require_config() { # returns non-zero (→ step bails back to the menu) if incomplete
  [[ -n "$TARGET_IP" && -n "$SSH_PUBKEY" && -n "$FCOS_HOSTNAME" ]] \
    || { err "Settings incomplete — fill IP, hostname and SSH key in '1) Configure'."; return 1; }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
hash_password() { # reads plaintext on stdin, prints a crypt(5) hash
  if command -v mkpasswd >/dev/null 2>&1; then
    mkpasswd -m yescrypt -s
  elif command -v openssl >/dev/null 2>&1; then
    openssl passwd -6 -stdin
  else
    return 1
  fi
}

set_password() { # prompts twice (no echo), sets PASSWORD_HASH
  local p1 p2
  while :; do
    read -rs -p "  Password: " p1; echo
    read -rs -p "  Confirm:  " p2; echo
    [[ -n "$p1" && "$p1" == "$p2" ]] && break
    warn "Empty or mismatched — try again."
  done
  PASSWORD_HASH="$(printf '%s' "$p1" | hash_password)" || {
    warn "Need 'mkpasswd' (whois pkg) or 'openssl' to hash the password."
    PASSWORD_HASH=""; unset p1 p2; return 1
  }
  unset p1 p2
  ok "Password hash generated — will apply to ${CORE_USER} and root."
}

# --- SSH key validation -----------------------------------------------------
expand_tilde() { printf '%s' "${1/#\~/$HOME}"; }

# Echo the SHA256 fingerprint of a key file (works for public OR private keys —
# OpenSSH private keys carry the public half in cleartext, so no passphrase is
# needed). Empty output + non-zero return means "not a valid key".
key_fp() {
  command -v ssh-keygen >/dev/null 2>&1 || return 3
  local fp; fp="$(ssh-keygen -l -f "$1" 2>/dev/null | awk '{print $2}')"
  [[ -n "$fp" ]] && { printf '%s' "$fp"; return 0; } || return 1
}

# Validate the public-key STRING; echo its fingerprint on success.
pubkey_check() {
  [[ -n "$1" ]] || return 2
  command -v ssh-keygen >/dev/null 2>&1 || return 3
  local tmp fp; tmp="$(mktemp)"; printf '%s\n' "$1" > "$tmp"
  fp="$(key_fp "$tmp")"; local rc=$?; rm -f "$tmp"
  (( rc == 0 )) && printf '%s' "$fp"; return $rc
}

# Validate the private-key FILE; echo its fingerprint on success.
privkey_check() {
  local p; p="$(expand_tilde "$1")"
  [[ -n "$p" ]] || return 2
  [[ -f "$p" ]] || return 4
  key_fp "$p"
}

# Warn (non-fatal) if pub and priv keys exist but don't correspond.
keys_match_warn() {
  local pfp sfp
  pfp="$(pubkey_check "$SSH_PUBKEY")"      || return 0
  [[ -n "$SSH_KEY_PATH" ]]                 || return 0
  sfp="$(privkey_check "$SSH_KEY_PATH")"   || return 0
  if [[ "$pfp" != "$sfp" ]]; then
    warn "Public key and private key ($SSH_KEY_PATH) do NOT match."
    warn "You likely won't be able to log in after install — fix in Settings."
  fi
}

clear_known_host() {
  local ip="$1"
  ssh-keygen -R "$ip" >/dev/null 2>&1 || true
  info "Cleared any stale host key for $ip from ~/.ssh/known_hosts"
}

rescue_ssh() { # multiplexed ssh to the OVH rescue box; honors RESCUE_AUTH
  local opts=(-o ControlMaster=auto -o ControlPath="$SSH_CTRL" -o ControlPersist=600
             -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null)
  if [[ "$RESCUE_AUTH" == key ]]; then
    # SSH-key auth (key registered in OVH's rescue options). May be a different
    # key than the one installed on CoreOS ("other ssh"); blank = default keys/agent.
    [[ -n "$RESCUE_KEY_PATH" ]] && opts+=(-i "$(expand_tilde "$RESCUE_KEY_PATH")" -o IdentitiesOnly=yes)
    opts+=(-o PreferredAuthentications=publickey -o PubkeyAuthentication=yes)
    ssh "${opts[@]}" "${RESCUE_USER}@${TARGET_IP}" "$@"
  elif [[ -n "$RESCUE_PASSWORD" ]] && command -v sshpass >/dev/null 2>&1; then
    # Password auth via sshpass (the session password is never stored).
    sshpass -p "$RESCUE_PASSWORD" ssh "${opts[@]}" \
      -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no \
      "${RESCUE_USER}@${TARGET_IP}" "$@"
  else
    # No sshpass / blank password: let SSH prompt (or use default keys).
    ssh "${opts[@]}" "${RESCUE_USER}@${TARGET_IP}" "$@"
  fi
}

prompt_rescue_password() { # masked, session-only; blank = use key / SSH's own prompt
  RESCUE_PASSWORD=""
  if ! command -v sshpass >/dev/null 2>&1; then
    warn "sshpass not installed — SSH will ask for the rescue password itself."
    info "For an in-wizard prompt instead: sudo dnf install -y sshpass"
    return 0
  fi
  info "Enter the temporary rescue password OVH emailed you for this session."
  info "It is used now and ${C_BOLD}never saved${C_RESET}. Leave blank to use an SSH key or let"
  info "SSH prompt you itself."
  read -rs -p "$(printf '%sRescue password (this session only):%s ' "$C_BOLD" "$C_RESET")" RESCUE_PASSWORD
  echo
}
rescue_ssh_close() {
  ssh -O exit -o ControlPath="$SSH_CTRL" "${RESCUE_USER}@${TARGET_IP}" >/dev/null 2>&1 || true
}

coreos_host() { printf '%s' "${MGMT_HOST:-$TARGET_IP}"; }  # Tailscale IP once SSH is restricted

coreos_ssh() { # ssh to core@<coreos_host> using the configured private key
  local extra=()
  [[ -n "$SSH_KEY_PATH" ]] && extra=(-i "$SSH_KEY_PATH")
  ssh "${extra[@]}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
      "${CORE_USER}@$(coreos_host)" "$@"
}

wait_for_ssh() { # wait_for_ssh <label> <connect-fn-name>  -- polls until login works
  local label="$1" fn="$2" tries=0
  info "Waiting for $label SSH on $TARGET_IP (Ctrl-C to stop)…"
  while ! "$fn" true 2>/dev/null; do
    tries=$((tries+1))
    printf '\r  …still waiting (%ds)   ' $((tries*5))
    sleep 5
  done
  printf '\r%-40s\r' ' '
  ok "$label is reachable."
}

# ===========================================================================
# STEP 1 — Configure (navigable settings menu)
# ===========================================================================
shorty() { # truncate long values for display
  local s="$1"
  [[ -z "$s" ]] && { printf '%s(not set)%s' "$C_DIM" "$C_RESET"; return 0; }
  (( ${#s} > 46 )) && printf '%s…' "${s:0:46}" || printf '%s' "$s"
  return 0
}

reqmark() { # prints a red required-marker when $1 is empty; always returns 0
  [[ -z "$1" ]] && printf ' %s⚠ required%s' "$C_RED" "$C_RESET"
  return 0
}

keymark_pub() { # ✓ / ⚠ invalid for the public key (empty handled by reqmark)
  [[ -z "$SSH_PUBKEY" ]] && return 0
  pubkey_check "$SSH_PUBKEY" >/dev/null 2>&1 \
    && printf ' %s✓ valid%s' "$C_GREEN" "$C_RESET" \
    || printf ' %s⚠ invalid%s' "$C_RED" "$C_RESET"
  return 0
}
keymark_priv() { # ✓ / ⚠ for the private key file
  [[ -z "$SSH_KEY_PATH" ]] && return 0
  privkey_check "$SSH_KEY_PATH" >/dev/null 2>&1 \
    && printf ' %s✓ valid%s' "$C_GREEN" "$C_RESET" \
    || printf ' %s⚠ not found / invalid%s' "$C_RED" "$C_RESET"
  return 0
}

edit_pubkey() {
  local default_pub="${SSH_KEY_PATH:+${SSH_KEY_PATH}.pub}"
  default_pub="${default_pub:-$HOME/.ssh/id_ed25519.pub}"
  local pubpath candidate
  ask pubpath "Path to SSH *public* key (.pub), or paste the key" "$default_pub"
  pubpath="$(expand_tilde "$pubpath")"
  if [[ "$pubpath" =~ ^(ssh-|ecdsa-) ]]; then
    candidate="$pubpath"
  elif [[ -f "$pubpath" ]]; then
    candidate="$(< "$pubpath")"; info "Read public key from $pubpath"
  else
    warn "No such file: $pubpath — leaving public key unchanged."
    return 0
  fi
  # Validate the candidate before accepting it.
  local fp
  if fp="$(pubkey_check "$candidate")"; then
    SSH_PUBKEY="$candidate"
    ok "Valid public key — SHA256:${fp#SHA256:}"
    keys_match_warn
  else
    case $? in
      3) warn "ssh-keygen not found; cannot validate. Accepting key as-is."
         SSH_PUBKEY="$candidate" ;;
      *) warn "That is NOT a valid SSH public key (ssh-keygen rejected it)."
         warn "Public key left unchanged." ;;
    esac
  fi
}

edit_privkey() {
  local p
  ask p "Path to your *private* key (to log into CoreOS later)" "${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
  p="$(expand_tilde "$p")"
  local fp
  if fp="$(privkey_check "$p")"; then
    SSH_KEY_PATH="$p"
    ok "Valid private key — SHA256:${fp#SHA256:}"
    # SSH refuses keys readable by group/other. Last two octal digits must be 00.
    local perms; perms="$(stat -c '%a' "$p" 2>/dev/null || stat -f '%Lp' "$p" 2>/dev/null)"
    [[ -n "$perms" && "${perms: -2}" != "00" ]] \
      && warn "Permissions on $p are $perms — SSH wants owner-only. Fix: chmod 600 '$p'"
    keys_match_warn
  else
    case $? in
      4) warn "No such file: $p — private key path left unchanged." ;;
      3) warn "ssh-keygen not found; cannot validate. Setting path as-is."; SSH_KEY_PATH="$p" ;;
      *) warn "$p is not a valid SSH private key — left unchanged." ;;
    esac
  fi
}

edit_rescue() { # OVH rescue access: user + auth method (password or SSH key)
  ask RESCUE_USER "OVH rescue SSH username" "${RESCUE_USER:-root}"
  info "How do you log into OVH rescue mode?"
  info "  1) Password  — OVH emails a fresh one each time you enable rescue mode"
  info "  2) SSH key   — you registered a public key in OVH's rescue options"
  local m; ask m "Choose 1 or 2" "$([[ "$RESCUE_AUTH" == key ]] && echo 2 || echo 1)"
  case "$m" in
    2) RESCUE_AUTH="key"
       info "Private key for rescue (may differ from your CoreOS key)."
       info "Leave blank to use your default SSH keys / agent."
       local p; ask p "Rescue private key path" "$RESCUE_KEY_PATH"
       p="$(expand_tilde "$p")"
       if [[ -z "$p" ]]; then
         RESCUE_KEY_PATH=""; ok "Rescue auth: SSH key (default keys/agent)."
       elif privkey_check "$p" >/dev/null 2>&1; then
         RESCUE_KEY_PATH="$p"; ok "Rescue auth: SSH key ($p)."
       else
         warn "$p is not a valid/existing private key — kept, but verify it."
         RESCUE_KEY_PATH="$p"
       fi ;;
    *) RESCUE_AUTH="password"; RESCUE_KEY_PATH=""
       ok "Rescue auth: password (you'll be prompted in step 3)." ;;
  esac
}

edit_stream() { # Fedora CoreOS update stream (no LTS — it auto-updates)
  info "Fedora CoreOS has no LTS releases; it auto-updates. Pick an update stream"
  info "(coreos-installer always writes the LATEST image in the chosen stream):"
  info "  1) stable  — recommended; well-tested, ~biweekly"
  info "  2) testing — what stable will become, ~2 weeks ahead"
  info "  3) next    — early access to next major version"
  local m; ask m "Choose 1/2/3" "$(case "$STREAM" in testing) echo 2;; next) echo 3;; *) echo 1;; esac)"
  case "$m" in 2) STREAM="testing";; 3) STREAM="next";; *) STREAM="stable";; esac
  ok "Install stream: $STREAM"
}

edit_password() {
  if [[ -n "$PASSWORD_HASH" ]] && ! confirm "A console password is already set — replace it?"; then
    return 0
  fi
  if confirm "Set a console password for ${CORE_USER} + root (for the OVH KVM console)?"; then
    set_password || true
  else
    PASSWORD_HASH=""; info "No console password — SSH-key login only."
  fi
}

step_configure() {
  # First run: seed the SSH key from the common default if present.
  local default_pub="$HOME/.ssh/id_ed25519.pub"
  [[ -z "$SSH_PUBKEY" && -f "$default_pub" ]] && SSH_PUBKEY="$(< "$default_pub")"
  [[ -z "$SSH_KEY_PATH" && -f "$default_pub" ]] && SSH_KEY_PATH="${default_pub%.pub}"

  while true; do
    banner "Settings  (saved to .env — secrets excluded)"
    # reqmark prints a red ⚠ when a required field is empty (always exits 0).
    local m1 m2 m6
    m1=$(reqmark "$TARGET_IP"); m2=$(reqmark "$FCOS_HOSTNAME"); m6=$(reqmark "$SSH_PUBKEY")
    printf '  %s1%s) Server IP (OVH)       %s: %s%s\n'  "$C_BOLD" "$C_RESET" "$C_DIM$C_RESET" "$(shorty "$TARGET_IP")" "$m1"
    printf '  %s2%s) Hostname              : %s%s\n'    "$C_BOLD" "$C_RESET" "$(shorty "$FCOS_HOSTNAME")" "$m2"
    printf '  %s3%s) CoreOS admin user     : %s\n'      "$C_BOLD" "$C_RESET" "$(shorty "$CORE_USER")"
    printf '  %s4%s) Network interface     : %s %s(auto-detected on the server)%s\n' \
                                                        "$C_BOLD" "$C_RESET" "$(shorty "$NET_IFACE")" "$C_DIM" "$C_RESET"
    local rauth; if [[ "$RESCUE_AUTH" == key ]]; then
      rauth="ssh-key${RESCUE_KEY_PATH:+ ($(basename "$RESCUE_KEY_PATH"))}"
    else rauth="password"; fi
    printf '  %s5%s) Rescue access (OVH)   : %s %svia %s%s\n' \
      "$C_BOLD" "$C_RESET" "$(shorty "$RESCUE_USER")" "$C_DIM" "$rauth" "$C_RESET"
    printf '  %s6%s) SSH public key        : %s%s%s\n'  "$C_BOLD" "$C_RESET" "$(shorty "$SSH_PUBKEY")" "$m6" "$(keymark_pub)"
    printf '  %s7%s) SSH private key path  : %s%s\n'    "$C_BOLD" "$C_RESET" "$(shorty "$SSH_KEY_PATH")" "$(keymark_priv)"
    printf '  %s8%s) Console password      : %s %s(optional — for the OVH KVM console)%s\n' "$C_BOLD" "$C_RESET" \
      "$([[ -n "$PASSWORD_HASH" ]] && printf '%sset%s' "$C_GREEN" "$C_RESET" || printf '%s(not set)%s' "$C_DIM" "$C_RESET")" \
      "$C_DIM" "$C_RESET"
    printf '  %s9%s) FCOS stream           : %s %s(latest in stream; no LTS)%s\n' \
      "$C_BOLD" "$C_RESET" "$(shorty "${STREAM:-stable}")" "$C_DIM" "$C_RESET"

    if [[ -n "$TARGET_IP" && -n "$FCOS_HOSTNAME" && -n "$SSH_PUBKEY" ]]; then
      printf '\n  %s✓ ready to build the Ignition (step 2)%s\n' "$C_GREEN" "$C_RESET"
    else
      printf '\n  %sfill the ⚠ required fields above to continue%s\n' "$C_YELLOW" "$C_RESET"
    fi
    printf '  %s?%s) Help   %ss%s) Save & back   %sb%s) Back without saving\n' \
      "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"

    local c
    ask c "Edit # (or ?, s, b)" ""
    case "$c" in
      1) ask TARGET_IP     "Server public IPv4 (OVH manager → your server)" "$TARGET_IP" ;;
      2) ask FCOS_HOSTNAME "Hostname for the new server"      "${FCOS_HOSTNAME:-coreos-host}" ;;
      3) ask CORE_USER     "CoreOS admin username (SSH login)" "${CORE_USER:-core}" ;;
      4) info "Leave as 'auto' — the wizard detects the real NIC on the server in step 5."
         info "Only set a name (e.g. ens3, eth0, eno1) if you want to force one."
         ask NET_IFACE     "Network interface"                "${NET_IFACE:-auto}" ;;
      5) edit_rescue ;;
      6) edit_pubkey ;;
      7) edit_privkey ;;
      8) edit_password ;;
      9) edit_stream ;;
      \?|h) settings_help ;;
      s) save_env; break ;;
      b) break ;;
      "") break ;;
      *) warn "Unknown choice: $c" ;;
    esac
  done
}

settings_help() {
  cat <<EOF

${C_BOLD}What each setting means${C_RESET}
  ${C_BOLD}1 Server IP${C_RESET}        The public IPv4 of your server, shown in the OVH manager.
  ${C_BOLD}2 Hostname${C_RESET}         The name your new CoreOS box will have (and its Tailscale name).
  ${C_BOLD}3 Admin user${C_RESET}       The Linux user created for you (SSH-key login). 'core' is standard.
  ${C_BOLD}4 Interface${C_RESET}        Leave 'auto'. Detected on the server (e.g. ens3/eth0) in step 5.
  ${C_BOLD}5 Rescue access${C_RESET}    OVH rescue login (user, almost always 'root') and ${C_BOLD}how${C_RESET} to
                    authenticate: ${C_BOLD}password${C_RESET} (OVH emails a fresh one each time you
                    enable rescue) or ${C_BOLD}SSH key${C_RESET} (one you registered in OVH's rescue
                    options — may be a different key than the one you install).
  ${C_BOLD}6 SSH public key${C_RESET}   Installed into CoreOS so you can log in. A path or pasted key.
                    Validated with ssh-keygen (${C_GREEN}✓ valid${C_RESET}/${C_RED}⚠ invalid${C_RESET}); build is blocked if bad.
  ${C_BOLD}7 Private key${C_RESET}      The matching private key the wizard uses to reach CoreOS later.
                    Checked for existence + validity, and that it ${C_BOLD}matches${C_RESET} the public key.
  ${C_BOLD}8 Console password${C_RESET} Optional. Lets you log in at the OVH KVM/noVNC console or a
                    maintenance prompt. Stored only as a hash, in memory — never on disk.
  ${C_BOLD}9 FCOS stream${C_RESET}      Fedora CoreOS update stream — no LTS, it auto-updates.
                    stable (default) / testing / next. Installs the latest in the stream.
EOF
  read -r -p "$(printf '%s(press Enter)%s' "$C_DIM" "$C_RESET")" _ || true
}

# ===========================================================================
# STEP 2 — Build Ignition
# ===========================================================================
render_butane() {
  # Optional console/maintenance password — applied to the admin user AND root
  # so you can log in at the OVH KVM console or a systemd maintenance prompt.
  local pw_user="" root_block=""
  if [[ -n "$PASSWORD_HASH" ]]; then
    pw_user=$'\n      password_hash: "'"$PASSWORD_HASH"$'"'
    root_block=$'\n    - name: root\n      password_hash: "'"$PASSWORD_HASH"$'"'
  fi
  cat > "$BU_FILE" <<EOF
variant: fcos
version: 1.5.0
passwd:
  users:
    - name: ${CORE_USER}
      groups:
        - wheel
      ssh_authorized_keys:
        - "${SSH_PUBKEY}"${pw_user}${root_block}
storage:
  files:
    - path: /etc/hostname
      mode: 0644
      overwrite: true
      contents:
        inline: ${FCOS_HOSTNAME}
    - path: /etc/sudoers.d/10-coreos-wizard
      mode: 0440
      contents:
        inline: |
          ${CORE_USER} ALL=(ALL) NOPASSWD: ALL
    - path: /etc/sysctl.d/99-tailscale.conf
      mode: 0644
      contents:
        inline: |
          net.ipv4.ip_forward = 1
          net.ipv6.conf.all.forwarding = 1
EOF
}

# Name the available Butane engine, preferring the native binary (no containers,
# so it sidesteps podman's rootless user-namespace breakage).
butane_engine() {
  if command -v butane >/dev/null 2>&1; then echo native
  elif command -v podman >/dev/null 2>&1; then echo podman
  elif command -v docker >/dev/null 2>&1; then echo docker
  else echo none; fi
}

run_butane() { # stdin: .bu  ->  stdout: .ign
  case "$(butane_engine)" in
    native) butane --strict ;;
    podman) podman run --rm -i "$BUTANE_IMAGE" --strict ;;
    docker) docker run --rm -i "$BUTANE_IMAGE" --strict ;;
    *)      return 127 ;;
  esac
}

step_build_ignition() {
  banner "Step 2 — Build Ignition config (local)"
  require_config

  local engine; engine="$(butane_engine)"
  if [[ "$engine" == none ]]; then
    err "Need 'butane', 'podman', or 'docker' to transpile the config."
    err "Easiest fix (no containers): sudo dnf install -y butane"
    return 1
  fi

  # Refuse to bake an invalid public key into the image (it'd lock you out).
  local fp
  if fp="$(pubkey_check "$SSH_PUBKEY")"; then
    ok "SSH public key validated — SHA256:${fp#SHA256:}"
    keys_match_warn
  elif (( $? == 3 )); then
    warn "ssh-keygen unavailable — skipping key validation."
  else
    err "SSH public key is invalid. Fix it in Settings (#6) before building."
    return 1
  fi

  render_butane
  info "Rendered Butane → $BU_FILE"

  info "Transpiling with butane ($engine)…"
  if ! run_butane < "$BU_FILE" > "$IGN_FILE"; then
    err "Butane transpile failed (engine: $engine) — see $LOG_FILE."
    if [[ "$engine" == podman ]]; then
      err "podman looks broken. Either:  podman system migrate"
      err "or install the native binary (no containers):  sudo dnf install -y butane"
    fi
    rm -f "$IGN_FILE"
    return 1
  fi

  # Local validation guards against the 'trailing characters' JSON class of bug.
  if command -v python3 >/dev/null; then
    python3 -m json.tool "$IGN_FILE" >/dev/null || { err "Generated Ignition is not valid JSON."; return 1; }
  fi
  ok "Wrote valid Ignition → $IGN_FILE"
}

# ===========================================================================
# STEP 3 — Install to the rescue box
# ===========================================================================
step_rescue_install() {
  banner "Step 3 — Install CoreOS on the rescue box"
  require_config
  [[ -f "$IGN_FILE" ]] || { err "No Ignition built yet — run step 2 first."; return 1; }

  warn "This connects to ${RESCUE_USER}@${TARGET_IP} (the OVH rescue system)."
  info "First, in the OVH manager: reboot the server in RESCUE mode."
  if [[ "$RESCUE_AUTH" == key ]]; then
    info "Auth: ${C_BOLD}SSH key${C_RESET}${RESCUE_KEY_PATH:+ ($RESCUE_KEY_PATH)} (registered in OVH rescue options)."
  else
    info "Auth: ${C_BOLD}password${C_RESET} — OVH emails a fresh one each time you enable rescue."
    info "You'll be prompted for it now (once; the SSH connection is then reused)."
  fi
  confirm "Continue?" || return 0

  [[ "$RESCUE_AUTH" == password ]] && prompt_rescue_password   # masked, session-only
  clear_known_host "$TARGET_IP"   # rescue host key differs from old OS / CoreOS

  banner "Detecting disks on the rescue box"
  info "Listing block devices — identify the persistent SSD by its size,"
  info "NOT the small RAM-backed rescue root (sda is often the ramdisk on OVH)."
  echo
  rescue_ssh "lsblk -dno NAME,SIZE,MODEL,TYPE | sed 's/^/    /'" \
    || { rescue_ssh_close; err "Could not reach the rescue box (check IP / rescue mode / credentials)."; return 1; }
  echo

  local device confirm_dev
  ask device "Target disk to ERASE and install onto (e.g. sdb, nvme0n1)" ""
  [[ -n "$device" ]] || { rescue_ssh_close; err "No device given — aborting."; return 1; }
  device="${device#/dev/}"

  printf '%s' "${C_RED}${C_BOLD}"
  printf 'EVERYTHING on /dev/%s will be DESTROYED.%s\n' "$device" "$C_RESET"
  ask confirm_dev "Re-type the device name to confirm" ""
  [[ "$confirm_dev" == "$device" ]] || { rescue_ssh_close; err "Names didn't match — aborting (no changes made)."; return 1; }

  local ign_b64
  ign_b64="$(base64 -w0 < "$IGN_FILE")"

  banner "Running coreos-installer (this downloads ~1GB and writes the disk)"
  log "STEP3 install start: device=/dev/$device profile=$PROFILE ip=$TARGET_IP"
  # Pass device + base64 ignition as env so the remote script stays static & quote-safe.
  # All remote output is tee'd to the profile log for later debugging.
  if rescue_ssh "DEV='$device' IGN_B64='$ign_b64' STREAM='${STREAM:-stable}' bash -s" <<'REMOTE' 2>&1 | tee -a "$LOG_FILE"
set -euo pipefail

# OVH rescue runs from a RAM-backed root, which makes containers fail at every
# layer (overlay-on-ramfs, no-systemd cgroups, pivot_root EINVAL). So we do NOT
# run a container. We use podman only to PULL and EXTRACT the installer image's
# filesystem ('create'+'export' never start a container → no OCI runtime, no
# pivot_root), then run coreos-installer via chroot, which has none of those
# constraints. (coreos-installer ships no static binary, only the container.)
echo ">> Preparing rescue environment…"
export DEBIAN_FRONTEND=noninteractive
command -v podman >/dev/null 2>&1 || { apt-get update -qq || true; apt-get install -y -qq podman || true; }
apt-get clean 2>/dev/null || true
rm -rf /var/lib/apt/lists/* 2>/dev/null || true

IMG=quay.io/coreos/coreos-installer:release
STORE=/run/podman-store
ROOTFS=/run/ci-rootfs
mkdir -p "$STORE" "$ROOTFS"
mountpoint -q "$STORE"  || mount -t tmpfs tmpfs "$STORE"
mountpoint -q "$ROOTFS" || mount -t tmpfs tmpfs "$ROOTFS"

echo ">> Pulling installer image (vfs storage on tmpfs)…"
podman --root "$STORE" --storage-driver vfs pull "$IMG"

echo ">> Extracting installer rootfs (no container is started)…"
CID="$(podman --root "$STORE" --storage-driver vfs create "$IMG")"
podman --root "$STORE" --storage-driver vfs export "$CID" | tar -x -C "$ROOTFS"
podman --root "$STORE" --storage-driver vfs rm "$CID" >/dev/null 2>&1 || true
umount "$STORE" 2>/dev/null || true        # free the image copy from RAM

# Give the chroot the config, working DNS, and the kernel filesystems
# coreos-installer needs (block devices, sysfs, udev db).
printf '%s' "$IGN_B64" | base64 -d > "$ROOTFS/config.ign"
cp -f /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || true
mkdir -p "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/run/udev"
mount --bind /dev      "$ROOTFS/dev"
mount --bind /proc     "$ROOTFS/proc"
mount --bind /sys      "$ROOTFS/sys"
mount --bind /run/udev "$ROOTFS/run/udev" 2>/dev/null || true

echo ">> Installing Fedora CoreOS (${STREAM:-stable} stream) onto /dev/$DEV via chroot…"
set +e
chroot "$ROOTFS" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  coreos-installer install "/dev/$DEV" --stream "${STREAM:-stable}" -i /config.ign
RC=$?
set -e

# Tidy up bind mounts (best effort; the rescue box reboots anyway).
umount "$ROOTFS/run/udev" 2>/dev/null || true
umount "$ROOTFS/sys"      2>/dev/null || true
umount "$ROOTFS/proc"     2>/dev/null || true
umount "$ROOTFS/dev"      2>/dev/null || true

if [ "$RC" -ne 0 ]; then echo ">> coreos-installer failed (rc=$RC)"; exit "$RC"; fi
echo ">> Install complete."
REMOTE
  then :; else
    rescue_ssh_close; RESCUE_PASSWORD=""
    err "Remote install failed — see $LOG_FILE. Disk left untouched by the rollback."
    return 1
  fi

  rescue_ssh_close
  RESCUE_PASSWORD=""              # drop the session password from memory
  log "STEP3 install complete: /dev/$device"
  echo
  ok "CoreOS written to /dev/$device."
  echo
  warn "Now, in the OVH manager:"
  info "  1. Switch boot mode back to ${C_BOLD}Boot from hard disk${C_RESET}."
  info "  2. Reboot the server."
  info "  3. Then run step 4 here."
}

# ===========================================================================
# STEP 4 — Layer Docker + Tailscale on CoreOS (phase A)
# ===========================================================================
step_coreos_layer() {
  banner "Step 4 — Layer Docker + Tailscale (CoreOS, first reboot)"
  require_config
  clear_known_host "$TARGET_IP"   # host identity changed: rescue/old OS -> CoreOS
  wait_for_ssh "CoreOS ($CORE_USER@)" coreos_ssh

  info "Checking what's already installed…"
  if coreos_ssh "rpm -q docker-ce >/dev/null 2>&1 && rpm -q tailscale >/dev/null 2>&1"; then
    ok "docker-ce and tailscale are already layered — skip to step 5."
    return 0
  fi

  info "Layering docker-ce + tailscale in a single rpm-ostree transaction…"
  log "STEP4 layering start: $TARGET_IP"
  if coreos_ssh "sudo bash -s" <<'REMOTE' 2>&1 | tee -a "$LOG_FILE"
set -euo pipefail

# Docker CE (replaces the default moby-engine stack).
sudo curl -fsSLo /etc/yum.repos.d/docker-ce.repo \
  https://download.docker.com/linux/fedora/docker-ce.repo

# Tailscale repo + GPG key imported to the trusted store (avoids subkey errors).
sudo curl -fsSLo /etc/yum.repos.d/tailscale.repo \
  https://pkgs.tailscale.com/stable/fedora/tailscale.repo
sudo curl -fsSLo /etc/pki/rpm-gpg/tailscale.gpg \
  https://pkgs.tailscale.com/stable/fedora/repo.gpg

# One transaction => one reboot.
sudo rpm-ostree override remove moby-engine containerd runc docker-cli \
  --install docker-ce \
  --install docker-ce-cli \
  --install containerd.io \
  --install docker-buildx-plugin \
  --install docker-compose-plugin \
  --install tailscale

echo ">> Layering staged. A reboot is required to activate it."
REMOTE
  then :; else
    err "rpm-ostree layering failed — see $LOG_FILE."
    return 1
  fi

  echo
  log "STEP4 layering complete"
  ok "Packages layered."
  if confirm "Reboot the server now and wait for it to come back?"; then
    coreos_ssh "sudo systemctl reboot" || true
    sleep 5
    wait_for_ssh "CoreOS ($CORE_USER@)" coreos_ssh
    ok "Back online — run step 5 to finalize."
  else
    warn "Reboot manually (ssh ${CORE_USER}@${TARGET_IP} 'sudo systemctl reboot'), then run step 5."
  fi
}

# ===========================================================================
# STEP 5 — Finalize: enable services, Tailscale up, GRO (phase B)
# ===========================================================================
step_coreos_finalize() {
  banner "Step 5 — Finalize (enable Docker/Tailscale, bring up tailnet)"
  require_config
  wait_for_ssh "CoreOS ($CORE_USER@)" coreos_ssh

  if ! coreos_ssh "command -v tailscale >/dev/null && rpm -q docker-ce >/dev/null 2>&1"; then
    err "docker-ce/tailscale not active yet. Did you run step 4 AND reboot?"; return 1
  fi

  # Resolve the network interface on the server unless the user forced a name.
  local iface="$NET_IFACE"
  if [[ -z "$iface" || "$iface" == auto ]]; then
    iface="$(coreos_ssh "ip -o -4 route show default | awk '{print \$5; exit}'" 2>/dev/null | tr -d '\r')"
    if [[ -n "$iface" ]]; then
      ok "Auto-detected primary interface: $iface"
    else
      iface="ens3"; warn "Could not auto-detect interface; falling back to ens3."
    fi
  fi

  # --- Tailscale options (wizard) ------------------------------------------
  banner "Tailscale options"
  local ts_flags="" ts_opts_label="hostname=$FCOS_HOSTNAME"
  if confirm "Enable Tailscale SSH (manage SSH access through your tailnet)?" y; then
    ts_flags+=" --ssh"; ts_opts_label+=", ssh"
  fi
  if confirm "Advertise this node as an EXIT NODE (route others' traffic through it)?" n; then
    ts_flags+=" --advertise-exit-node"; ts_opts_label+=", exit-node"
    warn "Exit node needs approval in the Tailscale admin console (Machines → … → Edit"
    warn "route settings) before it's usable. IP forwarding is already enabled."
  fi
  if confirm "Act as a SUBNET ROUTER (let the tailnet reach private networks via this node)?" n; then
    local routes
    ask routes "Routes to advertise — comma-separated CIDRs (e.g. 192.168.1.0/24,10.0.0.0/24)" ""
    routes="${routes// /}"   # strip spaces so the flag stays a single token
    if [[ -n "$routes" ]]; then
      [[ "$routes" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}(,([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2})*$ ]] \
        || warn "That doesn't look like comma-separated IPv4 CIDRs — double-check it."
      ts_flags+=" --advertise-routes=$routes"; ts_opts_label+=", routes=$routes"
      warn "Subnet routes need approval in the admin console (Machines → … → Edit route settings)."
    else
      info "No routes entered — skipping subnet router."
    fi
  fi

  local ts_authkey
  warn "The Tailscale auth key is used now and never written to disk."
  info "Get one at https://login.tailscale.com/admin/settings/keys (non-ephemeral)."
  ask ts_authkey "Tailscale auth key (tskey-auth-…)" ""
  [[ "$ts_authkey" =~ ^tskey- ]] || warn "That doesn't look like a tskey- auth key."

  info "Configuring services, GRO offload, and joining the tailnet ($ts_opts_label)…"
  log "STEP5 finalize start: iface=$iface hostname=$FCOS_HOSTNAME flags=[$ts_flags] (auth key NOT logged)"
  # sudo strips the environment, so pass values as positional args instead.
  # Output is tee'd to the log; the remote script never echoes the auth key.
  if coreos_ssh "sudo bash -s -- '$iface' '$FCOS_HOSTNAME' '$ts_authkey' '$ts_flags'" <<'REMOTE' 2>&1 | tee -a "$LOG_FILE"
set -euo pipefail
IFACE="$1"; HOSTN="$2"; TS_KEY="$3"; TS_FLAGS="$4"

# NetworkManager dispatcher: turn on UDP GRO forwarding when the iface comes up.
cat > "/etc/NetworkManager/dispatcher.d/99-tailscale-gro" <<EOS
#!/bin/bash
if [ "\$1" = "$IFACE" ] && [ "\$2" = "up" ]; then
    /usr/sbin/ethtool -K $IFACE rx-udp-gro-forwarding on rx-gro-list off
fi
EOS
chmod +x "/etc/NetworkManager/dispatcher.d/99-tailscale-gro"
/usr/sbin/ethtool -K "$IFACE" rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null || true

# sysctl forwarding (also set by Ignition; reassert in case of a fresh boot).
sysctl --system >/dev/null 2>&1 || true

# Docker + Tailscale daemons, persistent across reboots.
systemctl enable --now docker.socket 2>/dev/null || systemctl enable --now docker || true
systemctl enable --now tailscaled

# Join the tailnet. State persists in /var/lib/tailscale. TS_FLAGS is intentionally
# unquoted so it splits into separate flags (--ssh, --advertise-exit-node, …).
tailscale up --auth-key="$TS_KEY" --hostname="$HOSTN" $TS_FLAGS

echo ">> Tailscale status:"
tailscale status || true
echo ">> Docker:"
docker --version || true
REMOTE
  then :; else
    err "Finalization failed — see $LOG_FILE."
    return 1
  fi

  echo
  log "STEP5 finalize complete"
  ok "Done. The node should now be visible in your Tailscale admin console."
  info "Log in any time with:  ssh -i ${SSH_KEY_PATH:-<key>} ${CORE_USER}@${TARGET_IP}"
}

# ===========================================================================
# Server management (Day-2: acts on the live, running CoreOS box)
# ===========================================================================
require_live() {
  [[ -n "$TARGET_IP" ]] || { err "No server configured (run the install first)."; return 1; }
  coreos_ssh true 2>/dev/null || { err "Can't reach the server at $(coreos_host). Is it up and reachable?"; return 1; }
}

# Emit the nftables ruleset for the current SSH_PUBLIC + FW_CLOSED state.
# Default-allow (FCOS default); only explicit drops. INPUT chain only — no FORWARD
# chain, so Docker published ports and exit-node forwarding (FORWARD/DNAT) keep working.
generate_nft_rules() {
  local closed_tcp="" closed_udp="" p
  local IFS=','
  for p in $FW_CLOSED; do
    [[ -z "$p" ]] && continue
    case "$p" in
      */udp) closed_udp+="${closed_udp:+, }${p%/udp}" ;;
      *)     closed_tcp+="${closed_tcp:+, }${p%/tcp}" ;;
    esac
  done
  unset IFS
  printf '#!/usr/sbin/nft -f\n'
  printf '# Managed by install-coreos wizard — default-allow, explicit drops only.\n'
  printf 'table inet wizard {\n'
  printf '  chain input {\n'
  printf '    type filter hook input priority 0; policy accept;\n'
  printf '    ct state established,related accept\n'
  printf '    iif "lo" accept\n'
  printf '    iifname "tailscale0" accept\n'          # tailnet is fully trusted
  if [[ "$SSH_PUBLIC" != yes ]]; then
    printf '    ip saddr 100.64.0.0/10 tcp dport 22 accept\n'
    printf '    ip6 saddr fd7a:115c:a1e0::/48 tcp dport 22 accept\n'
    printf '    tcp dport 22 drop\n'                  # block public SSH (tailnet already accepted above)
  fi
  [[ -n "$closed_tcp" ]] && printf '    tcp dport { %s } drop\n' "$closed_tcp"
  [[ -n "$closed_udp" ]] && printf '    udp dport { %s } drop\n' "$closed_udp"
  printf '  }\n}\n'
}

# Safely apply the ruleset: dry-run → arm dead-man rollback → apply+persist →
# confirm via $2 (fresh connection) and cancel the timer. $1=description.
fw_apply() {
  local desc="$1" chost="${2:-$(coreos_host)}"
  local rules b64; rules="$(generate_nft_rules)"; b64="$(printf '%s' "$rules" | base64 -w0)"

  if ! coreos_ssh "echo $b64 | base64 -d | sudo nft -c -f -" 2>/dev/null; then
    err "Generated nftables ruleset failed validation — nothing applied."; return 1
  fi
  # Dead-man: in 120s, drop our table → FCOS default (all open) → guaranteed reachable.
  coreos_ssh "sudo systemd-run --collect --on-active=120 --unit=wizard-fw-rollback \
      /usr/sbin/nft delete table inet wizard >/dev/null 2>&1; true" >/dev/null 2>&1 || true
  info "Auto-rollback armed: if this locks you out, access is restored in ~120s."
  # Apply + persist (survive reboot).
  coreos_ssh "echo $b64 | base64 -d | sudo tee /etc/sysconfig/nftables.conf >/dev/null \
      && sudo nft -f /etc/sysconfig/nftables.conf \
      && sudo systemctl enable nftables.service >/dev/null 2>&1; true" || true
  # Confirm + cancel the timer through $chost in ONE fresh connection.
  local sshk=(); [[ -n "$SSH_KEY_PATH" ]] && sshk=(-i "$SSH_KEY_PATH")
  if ssh "${sshk[@]}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=12 "${CORE_USER}@${chost}" \
       "sudo systemctl stop wizard-fw-rollback.timer 2>/dev/null; sudo systemctl reset-failed wizard-fw-rollback.service 2>/dev/null; true" 2>/dev/null; then
    ok "$desc — applied, persisted, confirmed via ${chost}."
    return 0
  fi
  warn "$desc applied but could NOT confirm via ${chost} — auto-rollback will restore access (~120s)."
  return 1
}

toggle_exit_node() {
  require_live || return 1
  info "Exit node lets other tailnet devices route their internet through this box."
  if confirm "Enable exit node? (No = disable)" y; then
    coreos_ssh "sudo tailscale set --advertise-exit-node" \
      && ok "Advertising as exit node — approve it in the admin console (Machines → … → Edit route settings)." \
      || err "tailscale set failed."
  else
    coreos_ssh "sudo tailscale set --advertise-exit-node=false" \
      && ok "Exit node disabled." || err "tailscale set failed."
  fi
}

toggle_public_ssh() {
  require_live || return 1
  local sshk=(); [[ -n "$SSH_KEY_PATH" ]] && sshk=(-i "$SSH_KEY_PATH")
  if [[ "$SSH_PUBLIC" == yes ]]; then
    banner "Restrict public SSH → Tailscale-only"
    warn "This drops port 22 from the public internet (tailnet keeps working)."
    local tsip
    tsip="$(coreos_ssh 'tailscale ip -4 2>/dev/null' | tr -d '\r' | head -1)"
    [[ "$tsip" =~ ^100\. ]] || { err "Couldn't read the box's Tailscale IP (is Tailscale up?). Aborting — no change."; return 1; }
    info "Box Tailscale IP: $tsip. Verifying THIS machine can SSH it…"
    if ! ssh "${sshk[@]}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=12 "${CORE_USER}@${tsip}" true 2>/dev/null; then
      err "This machine CANNOT reach $tsip over Tailscale."
      err "Get 'ssh ${CORE_USER}@${tsip}' working from here first (this machine must be on the tailnet)."
      return 1
    fi
    ok "Confirmed: this machine reaches $tsip over Tailscale."
    confirm "Restrict public SSH now? (auto-rollback protects you)" y || return 0
    local old="$SSH_PUBLIC"; SSH_PUBLIC="no"
    if fw_apply "Public SSH → Tailscale-only" "$tsip"; then
      MGMT_HOST="$tsip"; save_env
      ok "Public SSH restricted. The wizard now manages this box via $tsip."
      info "Connect with:  tailscale ssh ${CORE_USER}@${FCOS_HOSTNAME}   (or ssh ${CORE_USER}@${tsip})"
    else
      SSH_PUBLIC="$old"
      warn "Not confirmed — auto-rollback restores public SSH; state left as open."
    fi
  else
    banner "Re-open public SSH"
    confirm "Re-open port 22 to the internet?" n || return 0
    local old="$SSH_PUBLIC"; SSH_PUBLIC="yes"
    if fw_apply "Public SSH → open" "$(coreos_host)"; then
      MGMT_HOST=""; save_env
      ok "Public SSH re-opened. The wizard manages via $TARGET_IP again."
    else
      SSH_PUBLIC="$old"
      warn "Could not confirm — left as Tailscale-only."
    fi
  fi
}

fw_list() {
  require_live || return 1
  banner "Firewall status — ${FCOS_HOSTNAME:-?}"
  info "Public SSH : $([[ "$SSH_PUBLIC" == yes ]] && echo open || echo "Tailscale-only")"
  info "Closed ports: ${FW_CLOSED:-none (all open — FCOS default)}"
  echo "--- live nftables (managed table) ---"
  coreos_ssh "sudo nft list table inet wizard 2>/dev/null || echo '(no managed table loaded — all ports open)'"
}

fw_close_port() {
  require_live || return 1
  local p; ask p "Port to CLOSE to the public (e.g. 8080 or 8080/udp)" ""
  [[ -n "$p" ]] || return 0
  [[ "$p" == */* ]] || p="$p/tcp"
  [[ "$p" =~ ^[0-9]+/(tcp|udp)$ ]] || { err "Use PORT or PORT/tcp|udp."; return 1; }
  [[ "${p%/*}" == 22 ]] && { err "Use the Public SSH toggle for port 22, not this."; return 1; }
  case ",$FW_CLOSED," in *",$p,"*) info "$p is already closed."; return 0 ;; esac
  local old="$FW_CLOSED"; FW_CLOSED="${FW_CLOSED:+$FW_CLOSED,}$p"
  if fw_apply "Closed $p (public; tailnet still allowed)"; then save_env; else FW_CLOSED="$old"; fi
}

fw_open_port() {
  require_live || return 1
  [[ -n "$FW_CLOSED" ]] || { info "No ports are closed."; return 0; }
  info "Currently closed: $FW_CLOSED"
  local p; ask p "Port to RE-OPEN (e.g. 8080 or 8080/udp)" ""
  [[ -n "$p" ]] || return 0
  [[ "$p" == */* ]] || p="$p/tcp"
  local old="$FW_CLOSED" new="" x; local IFS=','
  for x in $FW_CLOSED; do [[ "$x" == "$p" ]] || new="${new:+$new,}$x"; done
  unset IFS
  [[ "$new" == "$old" ]] && { warn "$p was not in the closed list."; return 0; }
  FW_CLOSED="$new"
  if fw_apply "Opened $p"; then save_env; else FW_CLOSED="$old"; fi
}

fw_disable() {
  require_live || return 1
  confirm "Remove the managed firewall entirely (all ports open, SSH restriction lifted)?" n || return 0
  coreos_ssh "sudo nft delete table inet wizard 2>/dev/null; sudo rm -f /etc/sysconfig/nftables.conf; \
              sudo systemctl disable nftables.service 2>/dev/null; true" || true
  FW_CLOSED=""; SSH_PUBLIC="yes"; MGMT_HOST=""; save_env
  ok "Managed firewall removed — back to FCOS default (all open). Wizard uses $TARGET_IP."
}

server_management_menu() {
  while true; do
    banner "Server management — ${FCOS_HOSTNAME:-?} @ $(coreos_host)"
    info "Operates on the live, running server."
    printf '\n  %sTailscale%s\n' "$C_BOLD" "$C_RESET"
    printf '    %se%s) Exit node           enable / disable\n' "$C_BOLD" "$C_RESET"
    printf '  %sAccess%s\n' "$C_BOLD" "$C_RESET"
    printf '    %sx%s) Public SSH          currently: %s%s%s\n' "$C_BOLD" "$C_RESET" \
      "$([[ "$SSH_PUBLIC" == yes ]] && printf "%sopen%s" "$C_YELLOW" "$C_RESET" || printf "%sTailscale-only%s" "$C_GREEN" "$C_RESET")" "" ""
    printf '  %sFirewall (nftables)%s\n' "$C_BOLD" "$C_RESET"
    printf '    %sl%s) List / status      %sc%s) Close a port   %so%s) Open a port   %sd%s) Disable\n' \
      "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf '\n  %sb%s) Back\n' "$C_BOLD" "$C_RESET"
    local k; ask k "Choose" ""
    case "$k" in
      e) toggle_exit_node || true ;;
      x) toggle_public_ssh || true ;;
      l) fw_list || true ;;
      c) fw_close_port || true ;;
      o) fw_open_port || true ;;
      d) fw_disable || true ;;
      b|"") return 0 ;;
      *) warn "Unknown choice: $k" ;;
    esac
  done
}

# ===========================================================================
# Profiles UI
# ===========================================================================
new_profile() { # create + switch to a new profile, then configure it
  local name
  ask name "New profile name (e.g. the server's hostname)" ""
  [[ -n "$name" ]] || { warn "No name given."; return 1; }
  PROFILE="$(sanitize_name "$name")"
  if [[ -f "$PROFILES_DIR/$PROFILE.env" ]]; then
    warn "Profile '$PROFILE' already exists — switching to it."
    load_profile; return 0
  fi
  reset_settings; set_profile_paths
  ok "Created profile '$PROFILE'."
  step_configure                       # edits the in-memory settings (saves on 's')
  printf '%s' "$PROFILE" > "$STATE_FILE"   # record as active without wiping edits
}

delete_profile() {
  local list; mapfile -t list < <(list_profiles)
  ((${#list[@]})) || { warn "No profiles to delete."; return 0; }
  local n; ask n "Delete which # (blank to cancel)" ""
  [[ "$n" =~ ^[0-9]+$ ]] && (( n>=1 && n<=${#list[@]} )) || { info "Cancelled."; return 0; }
  local victim="${list[$((n-1))]}"
  confirm "Really delete profile '$victim' (backups are kept)?" || return 0
  rm -f "$PROFILES_DIR/$victim.env" "$PROFILES_DIR/$victim.ign" "$PROFILES_DIR/$victim.rendered.bu"
  ok "Deleted '$victim'."
  [[ "$victim" == "$PROFILE" ]] && { PROFILE=""; reset_settings; }
}

restore_backup() { # pick a timestamped backup of the active profile and restore it
  [[ -n "$PROFILE" ]] || { warn "No active profile."; return 0; }
  local bk; mapfile -t bk < <(list_backups "$PROFILE")
  ((${#bk[@]})) || { info "No backups for '$PROFILE' yet."; return 0; }
  banner "Backups for '$PROFILE' (newest first)"
  local i
  for i in "${!bk[@]}"; do printf '  %s%d%s) %s\n' "$C_BOLD" $((i+1)) "$C_RESET" "${bk[$i]}"; done
  local n; ask n "Restore which # (blank to cancel)" ""
  [[ "$n" =~ ^[0-9]+$ ]] && (( n>=1 && n<=${#bk[@]} )) || { info "Cancelled."; return 0; }
  cp -p "$BACKUP_DIR/${bk[$((n-1))]}" "$ENV_FILE"
  load_profile
  ok "Restored '$PROFILE' from ${bk[$((n-1))]}."
}

profiles_menu() {
  while true; do
    banner "Profiles  (each = one server; saved under profiles/)"
    local list; mapfile -t list < <(list_profiles)
    if ((${#list[@]}==0)); then
      info "No profiles yet."
    else
      local i mark
      for i in "${!list[@]}"; do
        mark=""; [[ "${list[$i]}" == "$PROFILE" ]] && mark=" ${C_GREEN}● active${C_RESET}"
        printf '  %s%d%s) %-16s %s%s%s%s\n' "$C_BOLD" $((i+1)) "$C_RESET" \
          "${list[$i]}" "$C_DIM" "$(profile_summary "$PROFILES_DIR/${list[$i]}.env")" "$C_RESET" "$mark"
      done
    fi
    printf '\n  %sn%s) New   %sd%s) Delete   %sr%s) Restore backup   %sb%s) Back\n' \
      "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
    local c; ask c "Select # or action" ""
    case "$c" in
      n) new_profile && return 0 ;;
      d) delete_profile ;;
      r) restore_backup; return 0 ;;
      b|"") return 0 ;;
      *) if [[ "$c" =~ ^[0-9]+$ ]] && (( c>=1 && c<=${#list[@]} )); then
           PROFILE="${list[$((c-1))]}"; load_profile
           ok "Switched to '$PROFILE'."; return 0
         else warn "Unknown choice: $c"; fi ;;
    esac
  done
}

# Startup: migrate a legacy ./.env, then pick or create a profile.
startup_profiles() {
  mkdir -p "$PROFILES_DIR"
  if [[ -f "$SCRIPT_DIR/.env" && -z "$(list_profiles)" ]]; then
    mv "$SCRIPT_DIR/.env" "$PROFILES_DIR/default.env"
    info "Migrated your existing .env → profiles/default.env"
  fi
  local last=""; [[ -f "$STATE_FILE" ]] && last="$(cat "$STATE_FILE" 2>/dev/null)"
  local list; mapfile -t list < <(list_profiles)
  if ((${#list[@]}==0)); then
    info "No profiles yet — let's create your first one."
    new_profile
  elif [[ -n "$last" && -f "$PROFILES_DIR/$last.env" ]]; then
    PROFILE="$last"; load_profile
    info "Loaded last profile: ${C_BOLD}$PROFILE${C_RESET}  ($(profile_summary "$ENV_FILE"))"
  else
    profiles_menu
  fi
  [[ -n "$PROFILE" ]] || { PROFILE="default"; load_profile; }
  log "──────── wizard session started (profile=$PROFILE, ip=${TARGET_IP:-?}) ────────"
}

view_log() { # show the tail of the active profile's log
  [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]] || { info "No log yet for '$PROFILE'."; return 0; }
  banner "Log: $LOG_FILE  (last 40 lines)"
  tail -n 40 "$LOG_FILE"
  echo
  info "Full log: $LOG_FILE   (follow live with:  tail -f '$LOG_FILE')"
  read -r -p "$(printf '%s(press Enter)%s' "$C_DIM" "$C_RESET")" _ || true
}

# ===========================================================================
# Main menu
# ===========================================================================
status_line() {
  local cfg="not configured" ign="not built"
  [[ -n "$TARGET_IP" ]] && cfg="${FCOS_HOSTNAME:-?} @ ${TARGET_IP}"
  [[ -f "$IGN_FILE" ]]  && ign="built"
  printf '  %sProfile:%s %s   %sConfig:%s %s   %sIgnition:%s %s\n' \
    "$C_DIM" "$C_RESET" "${C_BOLD}${PROFILE}${C_RESET}" \
    "$C_DIM" "$C_RESET" "$cfg" "$C_DIM" "$C_RESET" "$ign"
}

main_menu() {
  while true; do
    banner "Fedora CoreOS install wizard (OVH rescue → CoreOS + Docker + Tailscale)"
    status_line
    cat <<EOF

  ${C_BOLD}Profile & settings${C_RESET}
    ${C_BOLD}p${C_RESET}) Profiles           switch / new / delete / restore backup
    ${C_BOLD}1${C_RESET}) Configure / edit settings   (IP, hostname, keys, rescue user…)

  ${C_BOLD}Install steps${C_RESET}  (run in order; resume after each reboot)
    ${C_BOLD}2${C_RESET}) Build Ignition     local:  Butane → config.ign
    ${C_BOLD}3${C_RESET}) Install to disk    rescue: coreos-installer  (${RESCUE_USER}@, password or key)
    ${C_BOLD}4${C_RESET}) Layer & reboot     coreos: docker-ce + tailscale
    ${C_BOLD}5${C_RESET}) Finalize           coreos: enable + tailscale up + GRO

  ${C_BOLD}Server management${C_RESET}  (live box)
    ${C_BOLD}m${C_RESET}) Manage             exit node · public SSH · firewall

  ${C_BOLD}a${C_RESET}) Run 2→5 in order     ${C_BOLD}L${C_RESET}) View log     ${C_BOLD}q${C_RESET}) Quit
EOF
    local choice
    ask choice "Choose" ""
    # '|| true' lets a step's recoverable failure return to this menu (instead of
    # set -e killing the wizard). A hard 'die' inside a step still exits.
    case "$choice" in
      l|L) view_log || true ;;
      m|M) server_management_menu || true ;;
      p|P) profiles_menu || true ;;
      1) step_configure || true ;;
      2) step_build_ignition || true ;;
      3) step_rescue_install || true ;;
      4) step_coreos_layer || true ;;
      5) step_coreos_finalize || true ;;
      a) if step_build_ignition && step_rescue_install; then
           warn "Now switch OVH to 'boot from hard disk' and reboot the server."
           if confirm "Server rebooted into CoreOS — continue?"; then
             step_coreos_layer && step_coreos_finalize || true
           fi
         fi
         true ;;
      q|Q|"") break ;;
      *) warn "Unknown choice: $choice" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
trap 'rescue_ssh_close' EXIT
startup_profiles
main_menu
ok "Bye."
