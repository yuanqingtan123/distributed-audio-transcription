# Arch Linux Removable SSD Installation Guide
This README documents the full setup process for installing Arch Linux onto a removable SSD, including preparation, installation, configuration, and troubleshooting.

## Prerequisites
Before starting, ensure you have:
- A separate USB drive (at least 4GB) to create a bootable live USB.
- A removable SSD chosen based on your storage needs and compatibility.
- Ensure your BIOS/UEFI supports booting from external drives.
- Basic familiarity with terminal usage and Bash commands.
- Internet access in the live environment during installation for package downloads.
- Understanding of BIOS/UEFI boot selection.
- Optional: Familiarity with text editors like Vim (default here) or Nano.

## 1. Preparation

### Download Arch Linux ISO
- Official site: [https://archlinux.org/download/](https://archlinux.org/download/)
- Download the latest ISO image.
- Download the corresponding `.sig` file for signature verification.

### Verify ISO Authenticity
- Import Arch Linux master keys and verify signature:
  ```bash
  gpg --keyserver-options auto-key-retrieve --verify archlinux-*.iso.sig
  ```
- This ensures the ISO is authentic and untampered.
- If verification fails, refresh keys
    ```bash
    pacman-key --init && pacman-key --populate archlinux
    ```
    This would take quite some time

### Write ISO to USB using dd in Cygwin
- Alternatives include Rufus, BalenaEtcher, Ventoy, etc.
- Here, we use `dd` in Cygwin.

#### Install Cygwin
- Download from https://cygwin.com/install.html
- The `dd` package is installed by default.

#### Write ISO to USB
- Plug in and identify USB drive letter from Windows File Explorer (e.g., `E:`).
- In Cygwin terminal
    1. Identify the name of the USB Drive
        ```bash
        cat /proc/partitions
        ```
    1. A list of all partitions will be printed. Example:
        ```text
        major minor  #blocks  name   win-mounts
            8     0 175825944 sda
            8     1 175824896 sda1   C:\
            8    16 1953514582 sdb
            8    17 1953512448 sdb1   E:\
        ```
    1. If your USB drive letter is `E:`, `sdb1` represents a partition of your USB drive that is accessible by the Windows File Explorer, while `sdb` represents your entire USB drive.
    1. Be absolutely sure of the target device (`/dev/sdX`) — writing to the wrong disk will destroy data.
    1. Write the iso to the USB drive `sdb` instead of the partition `sdb1`
        ```bash
        dd if=/path/to/archlinux.iso of=/dev/sdX bs=4M status=progress && sync
        ```
        Replace `/dev/sdX` with your USB device (e.g., `/dev/sdb`).

#### Verify
- After completion, safely eject USB.
- Re-insert and check contents or boot from it.

### Enter BIOS/UEFI
- Common keys: `F2`, `F10`, `Del`, `Esc` during boot.
- Select USB as boot device.

## 2. Networking in Live Environment
### Check Network Interfaces
```bash
ip link
```
- Lists all network interfaces.

### Ethernet Connection
- Run this if using Ethernet Connection, else proceed to [Wi-Fi Connection](#wi-fi-connection)
    ```bash
    dhcpcd
    ```
- This starts the DHCP client.
- Verify with `ping archlinux.org`.

### Wi-Fi Connection
- Use `iwctl` interactive tool:
    ```bash
    iwctl
    ```
- Run these command one by one in `iwctl`
    ```bash
    device list
    station wlan0 scan
    station wlan0 get-networks
    station wlan0 connect YOUR_SSID
    exit
    ```
- Replace `YOUR_SSID` with your Wi-Fi network name.
- Key in the password for your wifi connction when prompted
- After exiting `iwctl`, verify connection
    ```bash
    ping -c 3 archlinux.org
    ```

## 3. Partitioning the SSD

### Partition Layout and Purpose
| Partition | Size       | Filesystem | Purpose                         |
|-----------|------------|------------|--------------------------------|
| /dev/sdX1 | 512MB      | FAT32      | EFI System Partition (ESP)      |
| /dev/sdX2 | ~160GB     | ext4       | Root filesystem (`/`)           |
| /dev/sdX3 | ~16GB      | swap       | Swap space                     |
| /dev/sdX4 | Remaining  | exFAT      | Shared storage (compatible with Windows/macOS/Linux) |
---
- Adjust sizes based on your SSD capacity and needs.
- EFI partition must be FAT32 for UEFI boot.
- Root partition ext4 is standard for Linux.
- Swap size depends on RAM and usage.
- exFAT for cross-platform storage.

### Partitioning Commands
- Plug in your ssd
- Run the following and identify your ssd device name (eg: `/dev/sdb` ) by checking the capacity
    ```bash
    lsblk
    ```
- Partition the ssd with `parted`
    ```bash
    parted /dev/sdX mklabel gpt
    parted /dev/sdX mkpart ESP fat32 1MiB 513MiB
    parted /dev/sdX set 1 boot on # note: boot flag is only need for the EFI partition
    parted /dev/sdX mkpart primary ext4 513MiB 166GiB
    parted /dev/sdX mkpart primary linux-swap 166GiB 182GiB
    parted /dev/sdX mkpart primary 182GiB 100%
    ```
- Replace `/dev/sdX` with your SSD device.
- Note on Partition Alignment:
    - Sometimes partitions may not be aligned optimally for SSD performance, which can lead to slower read/write speeds and increased wear.
    - To check alignment, use:
        ```bash
        parted /dev/sdb align-check optimal 1
        parted /dev/sdb align-check optimal 2
        parted /dev/sdb align-check optimal 3
        parted /dev/sdb align-check optimal 4
        ```
    - If any partition is reported as 'not aligned', you can recreate it with proper alignment by specifying start and end points aligned the block boundaries of your ssd.
    - Eg:
        ```bash
        # instead of
        parted /dev/sdX mkpart ESP fat32 1MiB 513MiB
        parted /dev/sdX mkpart primary ext4 513MiB 166GiB

        # use
        parted /dev/sdX mkpart ESP fat32 2MiB 514MiB
        parted /dev/sdX mkpart primary ext4 514MiB 167GiB
        ```
### Verification
- Confirm the start/end sectors of the partition
    ```bash
    parted /dev/sdb print
    ```

### Formatting Partitions
```bash
mkfs.fat -F32 /dev/sdX1
mkfs.ext4 /dev/sdX2
mkswap /dev/sdX3
swapon /dev/sdX3
pacman -S exfatprogs
mkfs.exfat /dev/sdX4
```

#### Windows Detection of exFAT Partition:
- Sometimes Windows may not detect the exFAT partition if its partition type GUID is not set correctly.
- To fix this, use `gdisk` to set the partition type to 0700 (Microsoft basic data):
    ```bash
    gdisk /dev/sdX
    ```
    Replace `/dev/sdX` with your SSD device.
- Do this one at a time when prompted in `gdisk`
    - Press `t` to change partition type.
    - Enter the partition number for the exFAT partition (e.g., 4).
    - Enter `0700` as the type code.
    - Press `w` to write changes and exit.
- After this, Windows should detect the exFAT partition properly.

### Verification
- Use `lsblk -f` to check partition types and filesystems.
- Use `blkid` for UUIDs.

## 4. Base Installation
### Mount Partitions
```bash
mount /dev/sdX2 /mnt
mkdir /mnt/boot
mount /dev/sdX1 /mnt/boot
swapon /dev/sdX3
```
Replace `/dev/sdX` with your SSD device.

### Install Base Packages
```bash
pacstrap /mnt base base-devel linux linux-firmware vim
```
- Vim is default editor; users can install nano if preferred.

### Generate fstab
```bash
genfstab -U /mnt >> /mnt/etc/fstab
```

### Enter Installed Environment
```bash
arch-chroot /mnt
```
- From this point, all commands affect the installed system.

## 5. System Configuration
### Set Timezone
```bash
ln -sf /usr/share/zoneinfo/Asia/Kuala_Lumpur /etc/localtime
hwclock --systohc
```
- Adjust timezone path as needed.

### Configure Locale
```bash
vim /etc/locale.gen
```
- Uncomment desired locales (e.g., `en_US.UTF-8 UTF-8`).
    ```bash
    locale-gen
    ```
    ```bash
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
    ```

### Set Hostname
```bash
echo "your_hostname" > /etc/hostname
```
- Replace `your_hostname` with your chosen name.

### Configure Hosts File
```bash
vim /etc/hosts
```
Add:
```
127.0.0.1   localhost
::1         localhost
127.0.1.1   your_hostname.localdomain your_hostname
```

### Set Root Password
```bash
passwd
```

## 6. Bootloader Setup
### Install GRUB and EFI Manager
```bash
pacman -S grub efibootmgr
```

### Install GRUB
```bash
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ArchSSD
# For external SSD persistence:
grub-install --target=x86_64-efi --efi-directory=/boot --removable
grub-mkconfig -o /boot/grub/grub.cfg
efibootmgr   # Verify entry exists
```
- `x86_64` target is for 64-bit Intel/AMD CPUs.
- Check hardware architecture with:
```bash
uname -m
```
- Or in Windows
    - Go to settings -> System -> About -> Device specifications -> System Type

### Generate GRUB Config
```bash
grub-mkconfig -o /boot/grub/grub.cfg
```

## 7. Post-Install Checklist
- Create a new user and add to `wheel` group:
    ```bash
    useradd -m -G wheel your_username
    passwd your_username
    ```

- Install sudo and configure:
    ```bash
    pacman -S sudo
    EDITOR=vim visudo
    ```

- Enable NetworkManager:
    ```bash
    systemctl enable NetworkManager
    ```
- Enable clock sync
    ```bash
    systemctl enable systemd-timesyncd
    ```
- Install desktop environment or window manager as needed.
- Verify all configurations before rebooting.

## 8. Preferences Settings
### Auto Login
- This is optional and may reduce security
- Create override directory and file:
    ```bash
    mkdir -p /etc/systemd/system/getty@tty1.service.d
    vim /etc/systemd/system/getty@tty1.service.d/override.conf
    ```
- Add the following into `override.conf`:
    ```text
    [Service]
    ExecStart=
    ExecStart=-/sbin/agetty --autologin your_username --noclear %I $TERM
    ```
- Reload systemd:
    ```bash
    systemctl daemon-reexec
    ```

### Terminal Font Size
- List available fonts:
    ```bash
    ls /usr/share/kbd/consolefonts/
    ```
- Install additional fonts (eg: `terminus-font`):
    ```bash
    pacman -S terminus-font
    ```
- Set font to any of the listed available fonts (eg: `ter-240b`):
    ```bash
    setfont ter-240b
    ```
- To persist across reboots, set in `/etc/vconsole.conf`:
    - Create/ edit `vconsole.conf`
        ```bash
        sudo vim /etc/vconsole.conf
        ```
    - Add the following
        ```text
        FONT=ter-240b
        ```

### Mount and Persist Storage Partition
- Add entry to `/etc/fstab` for `/dev/sdX4` with exFAT filesystem.
- Example:
    ```text
    UUID=your_uuid /mnt/storage exfat defaults 0 2
    ```
- Get UUID with:
    ```bash
    blkid /dev/sdX4
    ```

## 9. Common Problems & Solutions
- **No Internet in Live USB**: Use `dhcpcd` for Ethernet or `iwctl` for Wi-Fi.
- **exFAT not available**: Install `exfatprogs` before formatting.
- **Boot entry disappears**: Use `grub-install --removable` to place GRUB at fallback path.
- **Windows cannot see exFAT partition**: Ensure partition type is `0700 (Microsoft basic data)` using `gdisk`. Windows ignores Linux type codes.

## 10. Verification
- Check partitions:
    ```bash
    lsblk -f
    ```
- Check boot entries:
    ```bash
    efibootmgr
    ```
- Mount test:
    ```bash
    mount -a
    ```
- Windows visibility: Disk Management → assign drive letter to exFAT partition.

## Required pacman installs

| Package       | Step Needed                  |
|---------------|-----------------------------|
| exfatprogs    | Partitioning (exFAT format) |
| vim           | Base installation (editor)   |
| grub          | Bootloader setup            |
| efibootmgr    | Bootloader setup            |
| sudo          | Post-install checklist       |
| NetworkManager| Post-install checklist       |
| ttf-dejavu    | Preferences (fonts)          |
| ttf-liberation| Preferences (fonts)          |

## Summary
This guide covers the full lifecycle: preparing the ISO, booting live USB, connecting to Wi-Fi, partitioning and formatting, installing Arch to a removable SSD, configuring EFI persistence, setting up base system, and troubleshooting common pitfalls (networking, bootloader persistence, exFAT visibility).
