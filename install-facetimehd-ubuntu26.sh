
    
  
#!/usr/bin/env bash
# FaceTime HD (Broadcom 1570 PCIe) setup for Ubuntu 26.04 / Linux 7.x
# Source: https://github.com/patjak/facetimehd and facetimehd-firmware
# Run as your normal user: bash install-facetimehd-ubuntu26.sh
set -Eeuo pipefail
trap 'echo "ERROR: installation stopped at line $LINENO. Review the output above." >&2' ERR

say() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

if (( EUID == 0 )); then
  echo 'Run this as your regular user, not using sudo. The script invokes sudo when needed.' >&2
  exit 1
fi
if ! command -v apt-get >/dev/null; then
  echo 'This installer requires Ubuntu/Debian apt-get.' >&2
  exit 1
fi
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  [[ "${ID:-}" == ubuntu ]] || warn "Designed for Ubuntu; found ${PRETTY_NAME:-unknown}."
fi
say 'System information'
printf 'Kernel: %s\n' "$(uname -r)"
if [[ -r /sys/class/dmi/id/product_name ]]; then
  printf 'Device: %s\n' "$(cat /sys/class/dmi/id/product_name)"
fi
if command -v mokutil >/dev/null 2>&1; then
  mokutil --sb-state || true
fi
if command -v lspci >/dev/null 2>&1; then
  lspci -nn | grep -Ei 'broadcom|multimedia|camera' || true
fi

say 'Installing dependencies'
sudo apt-get update
sudo apt-get install -y git build-essential dkms "linux-headers-$(uname -r)" \
  curl xz-utils cpio v4l-utils pciutils mokutil

WORKDIR="${HOME}/Tweaks"
mkdir -p "$WORKDIR"
checkout() {
  local url="$1" dest="$2"
  if [[ -e "$dest" && ! -d "$dest/.git" ]]; then
    echo "Path exists but is not a Git checkout: $dest" >&2
    exit 1
  fi
  if [[ -d "$dest/.git" ]]; then
    local actual
    actual="$(git -C "$dest" remote get-url origin)"
    if [[ "$actual" != "$url" ]]; then
      echo "Unexpected Git remote in $dest: $actual" >&2
      exit 1
    fi
    if [[ -n "$(git -C "$dest" status --porcelain --untracked-files=no)" ]]; then
      echo "Local tracked changes in $dest; refusing to update automatically." >&2
      exit 1
    fi
    git -C "$dest" pull --ff-only
  else
    git clone "$url" "$dest"
  fi
}

say 'Fetching the upstream FaceTime HD driver'
checkout https://github.com/patjak/facetimehd.git "$WORKDIR/facetimehd-upstream"

say 'Checking FaceTime HD firmware'
FIRMWARE='/lib/firmware/facetimehd/firmware.bin'
if [[ -s "$FIRMWARE" || -s '/usr/lib/firmware/facetimehd/firmware.bin' ]]; then
  say 'Firmware already installed; keeping it'
else
  say 'Obtaining firmware extraction utility (downloads Apple firmware during build)'
  checkout https://github.com/patjak/facetimehd-firmware.git "$WORKDIR/facetimehd-firmware"
  cd "$WORKDIR/facetimehd-firmware"
  # Note: the upstream Makefile performs downloads itself; inspect it if desired.
  make
  test -s firmware.bin || { echo 'Firmware extraction did not produce firmware.bin.' >&2; exit 1; }
  sudo make install
fi

say 'Building driver for the currently running kernel'
cd "$WORKDIR/facetimehd-upstream"
make clean
make -j"$(nproc)"
test -s facetimehd.ko

say 'Installing kernel module'
sudo make install
sudo depmod -a

if mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'; then
  warn 'Secure Boot is enabled. An unsigned third-party kernel module may not load.'
  warn 'Module was built and installed, but this script will NOT bypass Secure Boot.'
  warn 'Sign/enroll the module using your chosen MOK procedure, then run: sudo modprobe facetimehd'
  exit 0
fi

say 'Loading driver'
if lsmod | grep -q '^bdc_pci '; then
  warn 'bdc_pci is loaded; trying to unload it before facetimehd.'
  sudo modprobe -r bdc_pci || warn 'Could not unload bdc_pci; camera might be claimed by another driver.'
fi
sudo modprobe facetimehd

say 'Detected camera devices'
v4l2-ctl --list-devices || true

say 'Ensuring module is requested on subsequent boots'
# This is only a request to load the module; manually installed modules still need
# rebuilding after kernel updates. No global driver blacklist is installed.
printf 'facetimehd\n' | sudo tee /etc/modules-load.d/facetimehd.conf >/dev/null

say 'Finished'
echo 'Test with a camera application. If no camera appears, inspect:'
echo '  sudo dmesg | grep -iE "facetimehd|firmware|fthd" | tail -60'
echo 'NOTE: This is NOT a DKMS installation. Rebuild after a kernel upgrade.'
