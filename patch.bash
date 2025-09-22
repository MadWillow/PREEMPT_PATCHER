#!/bin/bash

set -eu
IFS=$'\n\t'

# Flags for choosing which steps are executed
CHECK_ENVIRONMENT=true
INSTALL_DEPENDENCIES=true
COMPILE_KERNEL=true
INSTALL_KERNEL=true
ADD_BOOT_ENTRY=true
CREATE_TINY_KERNEL_BASE=false
MENUCONFIG=false

###########################
#####       UI        #####
###########################
# Generic functions for a cli-wizard

# Wizard metadata
TITLE=""
HEADER=()
STEP_NAMES=()
STEP_STATES=()
STEP_COMMENTS=()
CURRENT_STEP_INDEX=0
HEADER_END=0
STEPS_END=0

# ANSI color/state markers
STATE_PLANNED="\033[90m 🕑"
STATE_CURRENT="\033[0m →"
STATE_SKIPPED="\033[33m ↷"
STATE_COMPLETED="\033[32m ✓"
STATE_FAILED="\033[31m ❌"

# Set wizard title
function title() {
  TITLE="$*"
}

# Append lines to header
function header() {
  HEADER+=("$*")
}

# Register a new step
function register_step() {
  STEP_NAMES+=("$*")
  STEP_COMMENTS+=("")
  STEP_STATES+=("$STATE_PLANNED")
}

# Select a step by name
function select_step() {
  for (( i = 0; i < ${#STEP_NAMES[@]}; i++ )); do
    if [[ "${STEP_NAMES[i]}" == "$*" ]]; then
      CURRENT_STEP_INDEX=$i
      return
    fi
  done
  echo -e "\033[31mStep \"$*\" not found!"
  exit 1
}

# Mark current step state
function mark_selected_step_as_current() {
  STEP_STATES[CURRENT_STEP_INDEX]="$STATE_CURRENT"
}

function mark_selected_step_as_skipped() {
  STEP_STATES[CURRENT_STEP_INDEX]="$STATE_SKIPPED"
}

function mark_selected_step_as_completed() {
  STEP_STATES[CURRENT_STEP_INDEX]="$STATE_COMPLETED"
}

function mark_selected_step_as_failed() {
  STEP_STATES[CURRENT_STEP_INDEX]="$STATE_FAILED"
}

# Add or append comment to current step
function comment() {
  if [[ -z "${STEP_COMMENTS[CURRENT_STEP_INDEX]}" ]]; then
    STEP_COMMENTS[CURRENT_STEP_INDEX]="$*"
  else
    STEP_COMMENTS[CURRENT_STEP_INDEX]+="; $*"
  fi
}

# Print wizard header
function print_header() {
  echo -e "\033[H ===== ${TITLE} =====\n"
  for line in "${HEADER[@]}"; do
    echo -e "$line"
  done
  HEADER_END=$((${#HEADER[@]} + 2))
}

# Print the currently selected step
function reprint_selected_step() {
  local line=$((HEADER_END + CURRENT_STEP_INDEX + 2))
  echo -e "\033[r\033[${line}H${STEP_STATES[CURRENT_STEP_INDEX]} ${STEP_NAMES[CURRENT_STEP_INDEX]} \033[33m${STEP_COMMENTS[CURRENT_STEP_INDEX]}"
}

# Print all registered steps
function print_steps() {
  local base_line=$((HEADER_END + 4))
  echo -e "\033[${base_line}HSteps:\n"
  local last_selected=$CURRENT_STEP_INDEX
  for (( i = 0; i < ${#STEP_NAMES[@]}; i++ )); do
    CURRENT_STEP_INDEX=i
    reprint_selected_step
  done
  CURRENT_STEP_INDEX=$last_selected
  STEPS_END=$((${#STEP_NAMES[@]} + base_line))
}

# Prepare step output area
function prepare_step_output() {
  local line=$((STEPS_END))
  echo -e "\033[r\033[${line}H\033[0J\033[36m${STEP_NAMES[CURRENT_STEP_INDEX]}:"
  echo -e "\033[$((line+1))r\033[0m" # setup scroll region (1..line+1), reset colors, clear below
}

# Full wizard UI refresh
function print() {
  echo -e "\033[r" # reset scrolling area to full screen
  clear
  print_header
  print_steps
  prepare_step_output
}

# Step switcher (mark prev done; mark new current)
function step() {
  if [[ "${STEP_STATES[CURRENT_STEP_INDEX]}" == "$STATE_CURRENT" ]]; then
    mark_selected_step_as_completed
  fi
  reprint_selected_step
  select_step "${*}"
  mark_selected_step_as_current
  reprint_selected_step
  prepare_step_output
}

# Restore terminal on exit
function cleanup() {
  echo -ne "\033[0m\033[r"
  local rows cols
  rows=${LINES:-$(tput lines 2>/dev/null || echo 24)}
  cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
  echo -ne "\033[$((rows-1));${cols}H"
  exit
}
trap cleanup EXIT INT TERM

# Error message and abort
function error() {
  echo -e "\033[31m⚠ Fatal Error! ⚠"
  echo -e "${*}"
  mark_selected_step_as_failed
  reprint_selected_step
  exit 1
}

# OK helper
function ok() {
  echo -e "\033[32m✓ ${*}"
}

#########################
#####     STEPS     #####
#########################
# logic of the steps (not executed yet)

KERNEL_PAGE="https://cdn.kernel.org/pub/linux/kernel"
RT_PAGE="${KERNEL_PAGE}/projects/rt"
WORKDIR=$(mktemp -d -t kernel-patching-XXXXXX)
KERNEL_BASE=$(uname -r | cut -d '.' -f1-2)  # e.g., "6.8"
KERNEL_VERSION=
PATCH_VERSION=
PATCH_SUFFIX=

# Download a file and verify its sha256 via the corresponding sha256sums.asc
function download_with_checksum() {
  local url="$1"
  local file
  file="$(basename "$url")"
  local sums_url="$2"
  local sums_file
  sums_file="$(basename "$sums_url")"

  # -O ensures the final filename is predictable; -nc is incompatible with -O (so we omit -nc).
  wget -q "$url" -O "$file"

  if wget -q -O "$sums_file" "$sums_url"; then
    # Extract the matching line and feed it to sha256sum -c
    grep -E "[[:space:]]$file\$" "$sums_file" > "$file.sha256" || true
    if [[ -s "$file.sha256" ]] && sha256sum -c "$file.sha256"; then
      ok "$file checksum ok"
      rm -f "$file.sha256"
    else
      error "$file checksum FAIL (or checksum not found)"
    fi
  else
    error "no checksum file for $file"
  fi
}

register_step "Check Environment"
function check_environment() {
  step "Check Environment"

  # Root is required only if performing privileged actions
  local needs_root=false
  if [[ "$INSTALL_DEPENDENCIES" = true || "$INSTALL_KERNEL" = true || "$ADD_BOOT_ENTRY" = true ]]; then
    needs_root=true
  fi

  if [[ $EUID -ne 0 && "$needs_root" = true ]]; then
    error "This script must be run as root for the selected actions"
  elif [[ $EUID -eq 0 ]]; then
    ok "Running as root"
  else
    ok "Running unprivileged (ok for non-install steps)"
  fi

  if [ -w "$WORKDIR" ]; then
    ok "${WORKDIR} is writable"
  else
    error "${WORKDIR} not writable"
  fi

  # Package manager: only required if we need to install dependencies
  if command -v apt-get &>/dev/null; then
    ok "apt-get available"
  else
    if [ "$INSTALL_DEPENDENCIES" = true ]; then
      error "Cannot install dependencies: apt-get not found"
    else
      comment "apt-get not found; assuming required tools are preinstalled"
      ok "continuing without dependency installation"
    fi
  fi
}

register_step "Install Dependencies"
function install_dependencies() {
  step "Install Dependencies"
  # Includes required build tools and helpers:
  #  - xz-utils: for .xz compression (kernel tarball/patch)
  #  - libncurses-dev: for menuconfig (if enabled)
  apt-get update
  apt-get install -y \
    build-essential bc python3 bison flex rsync libssl-dev wget curl \
    libelf-dev libncurses-dev dwarves gawk ccache xz-utils
}

register_step "Choose Kernel"
function choose_kernel() {
  step "Choose Kernel"
  # @todo: add logic to choose a different major.minor instead of current base
  comment "${KERNEL_BASE}"
}

register_step "Choose Patch"
function choose_patch() {
  step "Choose Patch"
  # @todo: allow selecting a specific RT patch instead of just the latest
  page=$(curl -s "${RT_PAGE}/${KERNEL_BASE}/")
  list=$(echo "$page" | grep -oP "patch-${KERNEL_BASE}-rt[0-9]+\.patch\.xz" | sort -V || true)
  [ -z "$list" ] && error "no patch found"
  latest=$(echo "$list" | tail -n 1)
  PATCH_VERSION=$(echo "$latest" | sed -E 's/patch-(.*)\.patch\.xz/\1/')
  KERNEL_VERSION=$(echo "$PATCH_VERSION" | cut -d '-' -f1)
  PATCH_SUFFIX=$(echo "$PATCH_VERSION" | cut -d '-' -f2)
  comment "${PATCH_VERSION}"
}

register_step "Download Kernel"
function download_kernel() {
  step "Download Kernel"
  url="${KERNEL_PAGE}/v${KERNEL_BASE%%.*}.x/linux-$KERNEL_VERSION.tar.xz"
  sum_url="$(dirname "$url")/sha256sums.asc"
  download_with_checksum "$url" "$sum_url"
  comment "${url}"
}

register_step "Unpack Kernel"
function unpack_kernel() {
  step "Unpack Kernel"
  tar -xf "linux-${KERNEL_VERSION}.tar.xz"
}

register_step "Download Patch"
function download_patch() {
  step "Download Patch"
  url="${RT_PAGE}/${KERNEL_BASE}/patch-${PATCH_VERSION}.patch.xz"
  sum_url="$(dirname "$url")/sha256sums.asc"
  download_with_checksum "$url" "$sum_url"
  comment "${url}"
}

register_step "Unpack Patch"
function unpack_patch() {
  step "Unpack Patch"
  xz -dk "patch-${PATCH_VERSION}.patch.xz"
}

register_step "Apply Patch"
function apply_patch() {
  step "Apply Patch"
  cd "${WORKDIR}/linux-${KERNEL_VERSION}"
  bash -c "patch -p1 < '${WORKDIR}/patch-${PATCH_VERSION}.patch'"
}

register_step "Create Kernel-Config"
function create_kernel_config() {
  step "Create Kernel-Config"

  # Pick a base: tiny (minimal) or localmodconfig (based on currently loaded modules)
  if [ "$CREATE_TINY_KERNEL_BASE" = true ]; then
    yes '' | make tinyconfig
    comment "tinyconfig"
  else
    yes '' | make localmodconfig
    comment "localmodconfig"
  fi

  # RT + smaller build + less cert baggage
  scripts/config --enable CONFIG_PREEMPT_RT
  scripts/config --disable CONFIG_DEBUG_INFO
  scripts/config --disable CONFIG_SYSTEM_REVOCATION_KEYS
  scripts/config --disable CONFIG_SYSTEM_TRUSTED_KEYS

  if [ "$MENUCONFIG" = true ]; then
    make menuconfig
  fi
}

register_step "Compile Kernel & Kernel-Modules"
function compile_kernel() {
  step "Compile Kernel & Kernel-Modules"
  yes '' | make -j"$(nproc)" -l"$(nproc)"
}

register_step "Install Modules"
function install_modules() {
  step "Install Modules"
  make modules_install
}

register_step "Install Kernel"
function install_kernel() {
  step "Install Kernel"
  make install
}

register_step "Locate Installed Files"
initrd=
vmlinuz=
function search_kernel_files() {
  step "Locate Installed Files"
  # Try standard Debian/Ubuntu-style paths first
  initrd="/boot/initrd.img-$KERNEL_VERSION"
  vmlinuz="/boot/vmlinuz-$KERNEL_VERSION"

  # Fallback: try matching by RT suffix if versioned filenames differ
  if [[ ! -f "$initrd" || ! -f "$vmlinuz" ]]; then
    # Common alternate naming schemes
    alt_vmlinuz=$(ls /boot/vmlinuz-*"$PATCH_SUFFIX"* 2>/dev/null | sort -V | tail -n1 || true)
    alt_initrd=$(ls /boot/initrd*.img-*"$PATCH_SUFFIX"* 2>/dev/null | sort -V | tail -n1 || true)
    if [[ -n "$alt_vmlinuz" && -n "$alt_initrd" ]]; then
      vmlinuz="$alt_vmlinuz"
      initrd="$alt_initrd"
    fi
  fi

  if [[ ! -f "$initrd" || ! -f "$vmlinuz" ]]; then
    error "Missing kernel files in /boot (initrd or vmlinuz not found)"
  fi

  comment "$initrd"
  comment "$vmlinuz"
}

register_step "Update Bootloader"
function add_boot() {
  step "Update Bootloader"
  # Prefer system tooling if present
  if command -v update-grub &>/dev/null; then
    update-grub
  elif command -v grub-mkconfig &>/dev/null; then
    grub-mkconfig -o /boot/grub/grub.cfg
  elif command -v kernelstub &>/dev/null; then
    # Ensure preempt=full is applied for RT kernels
    kernelstub --add-options "preempt=full" --kernel "$vmlinuz" --initrd "$initrd"
  else
    error "unsupported boot manager (need update-grub, grub-mkconfig, or kernelstub)"
  fi
  ok "updated bootloader"
}

register_step "Done"
function show_finish_screen() {
  step "Done"
  mark_selected_step_as_completed
  for (( i = 0; i < ${#STEP_STATES[@]}; i++ )); do
    if [[ "${STEP_STATES[i]}" == "$STATE_PLANNED" ]]; then
      STEP_STATES[i]="$STATE_SKIPPED"
    fi
  done
  echo -e "\033[32mScript finished!"
  if [ "$ADD_BOOT_ENTRY" = true ]; then
    echo -e "Reboot the system to boot into your new kernel."
  fi
  print_steps
}

######################### ACTUAL EXECUTION #############################

title "PREEMPT_RT Patcher"
header "downloads, patches, compiles and installs a realtime linux kernel"
header "(compiling may take a while…)"
print

if [ "$CHECK_ENVIRONMENT" = true ]; then
  check_environment
fi

if [ "$INSTALL_DEPENDENCIES" = true ]; then
  install_dependencies
fi

cd "$WORKDIR" || exit

choose_kernel
choose_patch
download_kernel
unpack_kernel
download_patch
unpack_patch
apply_patch
create_kernel_config

if [ "$COMPILE_KERNEL" = true ]; then
  compile_kernel
fi

if [ "$INSTALL_KERNEL" = true ]; then
  install_modules
  install_kernel
fi

if [ "$ADD_BOOT_ENTRY" = true ]; then
  search_kernel_files
  add_boot
fi

show_finish_screen
