#!/usr/bin/env bash
# Scan an IPv4 range for SSH hosts, check what the Icinga2 NRPE Universal Bootstrap Kit
# installed on each selected device and create services-<hostname>.conf with
# icinga2-nrpe-service-generator - stored either on this machine or on the remote host.
#
#   https://github.com/Michdo93/Icinga2-NRPE-Universal-Bootstrap-Kit
#   https://github.com/Michdo93/icinga2-nrpe-service-generator
set -uo pipefail

readonly SSH_PORT="${SSH_PORT:-22}"
readonly CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-4}"
readonly SCAN_PARALLEL="${SCAN_PARALLEL:-32}"

LOG=$(mktemp) || exit 1
trap 'rm -f "$LOG"' EXIT

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
ask_yes_no() {
  local prompt="$1" default="$2" answer
  while true; do
    if [[ "$default" == y ]]; then read -r -p "$prompt [Y/n] " answer || return 1
    else read -r -p "$prompt [y/N] " answer || return 1; fi
    answer=${answer,,}
    case "$answer" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      '') [[ "$default" == y ]] && return 0 || return 1 ;;
      *) printf 'Please answer y/yes or n/no.\n' ;;
    esac
  done
}
ipv4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 )) || return 1
  printf '%u' "$(( (10#$a<<24) | (10#$b<<16) | (10#$c<<8) | 10#$d ))"
}
int_to_ipv4() { local n=$1; printf '%d.%d.%d.%d' "$((n>>24&255))" "$((n>>16&255))" "$((n>>8&255))" "$((n&255))"; }

# Prints the address if an SSH server answers. An authentication failure for a user that
# does not exist still proves that sshd is there. No host keys are stored while scanning.
probe_ssh() {
  local ip=$1 out
  out=$(timeout "$((CONNECT_TIMEOUT + 3))" ssh -F /dev/null -p "$SSH_PORT" -o BatchMode=yes \
    -o ConnectTimeout="$CONNECT_TIMEOUT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "ssh-scan@$ip" true 2>&1) && { printf '%s\n' "$ip"; return; }
  case "$out" in
    *'Permission denied'*|*'Too many authentication failures'*|*'no mutual signature'*) printf '%s\n' "$ip" ;;
  esac
}

ask_range() {
  while true; do
    printf '\nEnter the first and last IPv4 address in the range.\n'
    read -r -p 'First address: ' first || exit 0
    read -r -p 'Last address:  ' last || exit 0
    first_n=$(ipv4_to_int "$first") || { printf 'Invalid first IPv4 address.\n'; continue; }
    last_n=$(ipv4_to_int "$last") || { printf 'Invalid last IPv4 address.\n'; continue; }
    (( first_n <= last_n )) || { printf 'The first address must not be greater than the last address.\n'; continue; }
    (( last_n - first_n <= 65535 )) || { printf 'Ranges are limited to 65,536 addresses.\n'; continue; }
    if ask_yes_no "Scan ${first} through ${last}?" y; then break; fi
  done
}

# Fills the array "reachable" (sorted) with all addresses of the range that run sshd.
scan_range() {
  local n
  printf '\nScanning for SSH services on TCP port %d (%d parallel probes)...\n' "$SSH_PORT" "$SCAN_PARALLEL"
  export -f probe_ssh
  export SSH_PORT CONNECT_TIMEOUT
  mapfile -t reachable < <(
    for ((n=first_n; n<=last_n; n++)); do int_to_ipv4 "$n"; printf '\n'; done |
      xargs -P "$SCAN_PARALLEL" -I{} bash -c 'probe_ssh "$1"' _ {} |
      sort -t . -k1,1n -k2,2n -k3,3n -k4,4n)
  if ((${#reachable[@]} == 0)); then printf 'No SSH-reachable devices found in the range.\n'; exit 0; fi
  printf 'Found %d SSH-reachable device(s).\n' "${#reachable[@]}"
}

command -v ssh >/dev/null || die 'OpenSSH client (ssh) is required.'
command -v timeout >/dev/null || die "The 'timeout' command is required (available on Linux and WSL)."
command -v base64 >/dev/null || die "The 'base64' command is required."
command -v xargs >/dev/null || die "The 'xargs' command is required."


GENERATOR_URL="${GENERATOR_URL:-https://raw.githubusercontent.com/Michdo93/icinga2-nrpe-service-generator/main/generate-services.py}"
GENERATOR_FILE="${GENERATOR_FILE:-}"     # local copy instead of the download

CTL_DIR=$(mktemp -d) || exit 1
GEN=$(mktemp) || exit 1
trap 'for s in "$CTL_DIR"/*; do [ -S "$s" ] && ssh -S "$s" -O exit x 2>/dev/null; done; rm -rf "$CTL_DIR" "$GEN" "$LOG"' EXIT

q() { local s=$1 x="'"; printf "'%s'" "${s//$x/$x\\$x$x}"; }   # quote for the remote shell

# ---------- generator: fetched once here and sent to every device (devices need no Internet)
if [[ -n "$GENERATOR_FILE" ]]; then
  cp "$GENERATOR_FILE" "$GEN" || die "Cannot read $GENERATOR_FILE."
elif command -v curl >/dev/null; then
  curl -fsSL "$GENERATOR_URL" -o "$GEN" || die "Download of $GENERATOR_URL failed (set GENERATOR_FILE to a local copy)."
elif command -v wget >/dev/null; then
  wget -qO "$GEN" "$GENERATOR_URL" || die "Download of $GENERATOR_URL failed (set GENERATOR_FILE to a local copy)."
else
  die 'curl or wget is required (or set GENERATOR_FILE to a local copy of generate-services.py).'
fi
grep -q 'icinga2-nrpe-service-generator' "$GEN" || die "$GENERATOR_URL does not look like generate-services.py."

# Remote check (POSIX sh on stdin, no root needed): what did the bootstrap kit install?
read -r -d '' CHECK_SCRIPT <<'REMOTE'
pkg() { dpkg-query -W -f='${Status} ${Version}\n' "$1" 2>/dev/null | awk '/install ok installed/{print $4; f=1} END{if(!f) print "-"}'; }
echo "HOSTNAME=$(hostname 2>/dev/null)"
[ -r /etc/os-release ] && . /etc/os-release
echo "OS=${PRETTY_NAME:-$(uname -s)}"
echo "KERNEL=$(uname -s)"
echo "NRPE_PKG=$(pkg nagios-nrpe-server)"
echo "PLUGINS_PKG=$(pkg monitoring-plugins-basic)"
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  echo "NRPE_ACTIVE=$(systemctl is-active nagios-nrpe-server 2>/dev/null)"
elif pgrep -x nrpe >/dev/null 2>&1; then echo "NRPE_ACTIVE=active"; else echo "NRPE_ACTIVE=inactive"; fi
cfg=/etc/nagios/nrpe.d/icinga2-bootstrap.cfg
if [ -r "$cfg" ]; then echo "BOOTSTRAP=yes"; echo "COMMANDS=$(grep -c '^command\[' "$cfg")"
  echo "COMMAND_NAMES=$(sed -n 's/^command\[\([^]]*\)\].*/\1/p' "$cfg" | tr '\n' ' ')"
else echo "BOOTSTRAP=no"; echo "COMMANDS=$(cat /etc/nagios/nrpe.cfg /etc/nagios/nrpe.d/*.cfg 2>/dev/null | grep -c '^command\[')"; fi
echo "ALLOWED_HOSTS=$(sed -n 's/^allowed_hosts=//p' /etc/nagios/nrpe.cfg 2>/dev/null | tail -n 1)"
echo "PORT=$(sed -n 's/^server_port=//p' /etc/nagios/nrpe.cfg 2>/dev/null | tail -n 1)"
command -v python3 >/dev/null 2>&1 && echo "PYTHON=yes" || echo "PYTHON=no"
REMOTE

# ---------- settings (once)
printf 'Generator: %s\n' "${GENERATOR_FILE:-$GENERATOR_URL}"
read -r -p "Local directory for configuration files [${OUTPUT_DIR:-./icinga2-nrpe-services}]: " answer || exit 0
OUTPUT_DIR=${answer:-${OUTPUT_DIR:-./icinga2-nrpe-services}}
home_sign='~'   # literal: expanded on the remote host (home of the SSH user), not here
read -r -p "Directory on the remote hosts (if stored there) [${REMOTE_DIR:-$home_sign}]: " answer || exit 0
REMOTE_DIR=${answer:-${REMOTE_DIR:-$home_sign}}
declare -a gen_args=()
ask_yes_no 'Include all NRPE commands, not only those of the bootstrap kit?' n && gen_args+=(--all)
ask_yes_no 'Create a Host object in each file (No: only Service objects)?' y || gen_args+=(--no-host)

ask_range
scan_range

# login IP -> 0 when a master connection for $username@IP exists (up to three attempts)
login() {
  local ip=$1 attempt
  read -r -p 'SSH username: ' username || return 1
  [[ -n "$username" ]] || { printf 'Skipped: username cannot be empty.\n'; return 1; }
  CTL="$CTL_DIR/$ip"
  for attempt in 1 2 3; do
    printf 'SSH login attempt %d of 3 for %s.\n' "$attempt" "$ip"
    if ssh -fN -M -S "$CTL" -o ControlPersist=600 -p "$SSH_PORT" -o ConnectTimeout="$CONNECT_TIMEOUT" \
        -o NumberOfPasswordPrompts=1 -o PreferredAuthentications=publickey,keyboard-interactive,password \
        -o StrictHostKeyChecking=accept-new "$username@$ip" 2> >(tee "$LOG" >&2); then
      return 0
    fi
    sleep 0.2
    if grep -aq 'REMOTE HOST IDENTIFICATION HAS CHANGED' "$LOG"; then
      printf 'The host key of %s has changed. Verify the device, then remove the old key with: ssh-keygen -R %s\n' "$ip" "$ip"
      return 1
    fi
    if (( attempt < 3 )); then printf 'SSH login failed.\n'; else printf 'SSH login failed after 3 attempts; moving to the next device.\n'; fi
  done
  return 1
}
rssh() { ssh -S "$CTL" -o BatchMode=yes -p "$SSH_PORT" "$username@$ip" "$@"; }   # over the master connection

declare -a saved_local=() saved_remote=() failed=()
for ip in "${reachable[@]}"; do
  printf '\nDevice: %s\n' "$ip"
  ask_yes_no 'Connect and create the Icinga2 configuration for this device?' y || { printf 'Skipped %s.\n' "$ip"; continue; }
  login "$ip" || { failed+=("$ip"); continue; }

  declare -A info=()
  while IFS='=' read -r key value; do [[ -n "$key" ]] && info[$key]=$value; done < <(rssh 'sh -s' <<< "$CHECK_SCRIPT")
  host=${info[HOSTNAME]:-$ip}
  printf '  Host name:        %s (%s)\n' "$host" "${info[OS]:-unknown}"
  printf '  NRPE server:      %s, service %s\n' "${info[NRPE_PKG]:--}" "${info[NRPE_ACTIVE]:-unknown}"
  printf '  Plugins:          monitoring-plugins-basic %s\n' "${info[PLUGINS_PKG]:--}"
  printf '  Bootstrap kit:    %s (%s commands)\n' "$([[ ${info[BOOTSTRAP]} == yes ]] && echo configured || echo 'not found')" "${info[COMMANDS]:-0}"
  [[ -n "${info[COMMAND_NAMES]:-}" ]] && printf '  Commands:         %s\n' "${info[COMMAND_NAMES]}"
  printf '  allowed_hosts:    %s\n' "${info[ALLOWED_HOSTS]:--}"

  args=("${gen_args[@]}")
  if [[ "${info[KERNEL]:-}" != Linux || "${info[NRPE_PKG]:--}" == - ]]; then
    printf 'NRPE is not installed on %s - run the Icinga2 NRPE Universal Bootstrap Kit first (e.g. with ssh-icinga2-nrpe-manager).\n' "$ip"
    failed+=("$ip"); continue
  fi
  [[ "${info[NRPE_ACTIVE]}" == active ]] || printf 'Warning: the NRPE service is not active on %s.\n' "$ip"
  if [[ "${info[BOOTSTRAP]}" != yes && " ${args[*]} " != *' --all '* ]]; then
    printf 'The bootstrap kit configuration was not found on %s.\n' "$ip"
    if ask_yes_no 'Use all NRPE commands defined on this device instead?' n; then args+=(--all); else failed+=("$ip"); continue; fi
  fi
  [[ "${info[PYTHON]}" == yes ]] || { printf 'python3 is missing on %s - cannot run the generator.\n' "$ip"; failed+=("$ip"); continue; }

  remote_cmd="python3 - --address $(q "$ip")"
  for a in "${args[@]}"; do remote_cmd+=" $(q "$a")"; done
  if ask_yes_no "Store services-$host.conf on this machine? (No: on the remote host in $REMOTE_DIR)" y; then
    mkdir -p "$OUTPUT_DIR" || { failed+=("$ip"); continue; }
    target="$OUTPUT_DIR/services-$host.conf"
    if [[ -e "$target" ]] && ! ask_yes_no "$target exists. Overwrite?" y; then printf 'Kept the existing file.\n'; continue; fi
    if rssh "$remote_cmd --output -" < "$GEN" > "$target.tmp" && [[ -s "$target.tmp" ]]; then
      mv "$target.tmp" "$target"
      printf 'Saved %s (%d services).\n' "$target" "$(grep -c '^object Service' "$target")"
      saved_local+=("$target")
    else
      rm -f "$target.tmp"; printf 'Generating the configuration failed on %s.\n' "$ip"; failed+=("$ip")
    fi
  else
    if out=$(rssh "$remote_cmd --output-dir $(q "$REMOTE_DIR")" < "$GEN" 2>&1); then
      printf '%s (on %s)\n' "$out" "$ip"; saved_remote+=("$ip")
    else
      printf 'Generating the configuration failed on %s: %s\n' "$ip" "$out"; failed+=("$ip")
    fi
  fi
  ssh -S "$CTL" -O exit "$ip" 2>/dev/null
done

printf '\nFinished. Stored locally: %d, on remote hosts: %d, failed/skipped: %d%s\n' \
  "${#saved_local[@]}" "${#saved_remote[@]}" "${#failed[@]}" "$( ((${#failed[@]})) && printf ' (%s)' "${failed[*]}")"
if ((${#saved_local[@]})); then
  printf 'Files in %s:\n' "$OUTPUT_DIR"; printf '  %s\n' "${saved_local[@]}"
  if command -v icinga2 >/dev/null; then
    case "$(cd "$OUTPUT_DIR" && pwd)" in
      /etc/icinga2/*) ask_yes_no 'Validate the Icinga2 configuration now (icinga2 daemon -C)?' y && icinga2 daemon -C | tail -n 3 ;;
      *) printf 'Copy them to /etc/icinga2/conf.d/ (or a zone directory), then: icinga2 daemon -C && systemctl reload icinga2\n' ;;
    esac
  else
    printf 'Copy them to the Icinga2 master (e.g. /etc/icinga2/conf.d/), then: icinga2 daemon -C && systemctl reload icinga2\n'
  fi
fi
