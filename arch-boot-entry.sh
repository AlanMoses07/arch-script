#!/usr/bin/env bash
# Safe Arch Linux systemd-boot entry repair helper.
# Default: inspect and preview only. Use --apply only after reviewing the preview.
set -Eeuo pipefail

ROOT_MOUNT="/mnt"
ESP_MOUNT="/mnt/boot"
EXPECTED_ROOT="/dev/nvme0n1p2"
EXPECTED_ESP="/dev/nvme0n1p1"
ENTRY="$ESP_MOUNT/loader/entries/arch.conf"
CMDLINE_FILE="$ROOT_MOUNT/etc/kernel/cmdline"

fail() { printf '\nSTOP: %s\nNo boot files were changed by this script.\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "Run this script as root from the Arch live USB."
[[ -d "$ROOT_MOUNT/etc" && -f "$CMDLINE_FILE" ]] || fail "$ROOT_MOUNT does not look like the mounted Arch root filesystem."
[[ -d "$ESP_MOUNT/EFI" && -d "$ESP_MOUNT/loader/entries" ]] || fail "$ESP_MOUNT does not look like the mounted EFI System Partition."
[[ -f "$ENTRY" ]] || fail "Existing Arch entry not found: $ENTRY"

ROOT_SOURCE="$(findmnt -nro SOURCE --target "$ROOT_MOUNT" | head -n1)"
ESP_SOURCE="$(findmnt -nro SOURCE --target "$ESP_MOUNT" | head -n1)"
[[ "$ROOT_SOURCE" == "$EXPECTED_ROOT" ]] || fail "$ROOT_MOUNT is mounted from '$ROOT_SOURCE', expected '$EXPECTED_ROOT'. Check mounts before proceeding."
[[ "$ESP_SOURCE" == "$EXPECTED_ESP" ]] || fail "$ESP_MOUNT is mounted from '$ESP_SOURCE', expected '$EXPECTED_ESP'. Check mounts before proceeding."

ROOT_PARTUUID="$(blkid -s PARTUUID -o value "$EXPECTED_ROOT")"
[[ -n "$ROOT_PARTUUID" ]] || fail "Could not read the root partition PARTUUID."
CMDLINE="$(tr '\n' ' ' < "$CMDLINE_FILE" | xargs)"
[[ "$CMDLINE" == *"root=PARTUUID=$ROOT_PARTUUID"* ]] || fail "Kernel command line does not contain the expected root=PARTUUID=$ROOT_PARTUUID. Review it manually."

mapfile -t KERNELS < <(find "$ESP_MOUNT" -xdev -type f -name vmlinuz -print)
mapfile -t INITRDS < <(find "$ESP_MOUNT" -xdev -type f -name initramfs -print)
[[ ${#KERNELS[@]} -eq 1 ]] || fail "Expected exactly one file named vmlinuz on the EFI partition; found ${#KERNELS[@]}."
[[ ${#INITRDS[@]} -eq 1 ]] || fail "Expected exactly one file named initramfs on the EFI partition; found ${#INITRDS[@]}."

KERNEL_PATH="${KERNELS[0]#"$ESP_MOUNT"}"
INITRD_PATH="${INITRDS[0]#"$ESP_MOUNT"}"
[[ -s "${KERNELS[0]}" && -s "${INITRDS[0]}" ]] || fail "Kernel or initramfs file is empty."
[[ "$KERNEL_PATH" == /* && "$INITRD_PATH" == /* ]] || fail "Could not form valid EFI-relative file paths."

NEW_ENTRY="$(printf 'title Arch Linux\nlinux %s\ninitrd %s\noptions %s\n' "$KERNEL_PATH" "$INITRD_PATH" "$CMDLINE")"

printf '\n=== Read-only verification ===\n'
printf 'Root mount:      %s <- %s\n' "$ROOT_MOUNT" "$ROOT_SOURCE"
printf 'EFI mount:       %s <- %s\n' "$ESP_MOUNT" "$ESP_SOURCE"
printf 'Root PARTUUID:   %s\n' "$ROOT_PARTUUID"
printf 'Kernel:          %s\n' "$KERNEL_PATH"
printf 'Initramfs:       %s\n' "$INITRD_PATH"
printf '\n=== Proposed arch.conf ===\n%s\n' "$NEW_ENTRY"
printf '=== Existing arch.conf ===\n'
cat "$ENTRY"
printf '\n'

if [[ "${1:-}" != "--apply" ]]; then
  printf 'PREVIEW ONLY: nothing was changed.\n'
  printf 'If every path and option above looks correct, run this same script with --apply.\n'
  exit 0
fi

BACKUP_DIR="$ROOT_MOUNT/root/arch-boot-repair-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -m 700 -p "$BACKUP_DIR"
cp -a "$ENTRY" "$BACKUP_DIR/arch.conf.original"
cp -a "$ESP_MOUNT/loader/loader.conf" "$BACKUP_DIR/loader.conf.original" 2>/dev/null || true
cp -a "$CMDLINE_FILE" "$BACKUP_DIR/kernel.cmdline"
printf '%s\n' "$ROOT_PARTUUID" > "$BACKUP_DIR/root-partuuid.txt"
printf '%s\n' "$KERNEL_PATH" > "$BACKUP_DIR/kernel-path.txt"
printf '%s\n' "$INITRD_PATH" > "$BACKUP_DIR/initramfs-path.txt"

TMP_ENTRY="$(mktemp "$ESP_MOUNT/loader/entries/.arch.conf.XXXXXX")"
printf '%s\n' "$NEW_ENTRY" > "$TMP_ENTRY"
chmod 0644 "$TMP_ENTRY"
mv "$TMP_ENTRY" "$ENTRY"

printf '\nEntry updated. Backup saved at: %s\n' "$BACKUP_DIR"
printf '\n=== Verify updated entry ===\n'
cat "$ENTRY"
printf '\nNo bootloader was installed and no Windows files were changed.\n'
printf 'Do not reboot yet if any displayed path or option looks unexpected.\n'
