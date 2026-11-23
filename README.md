# haos-netinstall

Install [Home Assistant OS](https://www.home-assistant.io/installation/) over the network: boot a machine
from the network, pick a disk, and it writes the latest stable HAOS release to it and reboots into it.
No USB stick to flash, no second computer to plug the disk into.

> **Unofficial.** This project is not affiliated with or endorsed by the Open Home Foundation or the
> Home Assistant project. It downloads the official, unmodified HAOS image from
> [home-assistant/operating-system](https://github.com/home-assistant/operating-system/releases).
>
> **It erases the disk you choose.** Everything on it is lost.

## How it works

```
UEFI firmware ──PXE/TFTP──▶ iPXE ──HTTP──▶ haos.ipxe ──▶ Linux kernel + installer (initramfs)
                                                           │
                       version.home-assistant.io ◀─────────┤ 1. find the current stable HAOS version
          github.com/home-assistant/operating-system ◀─────┤ 2. stream the image straight onto the disk
                                                           └ 3. add a UEFI boot entry, reboot into HAOS
```

The installer is a small Linux system (a kernel plus a BusyBox initramfs, built with Nix). It:

1. loads the drivers for your hardware and gets an address over DHCP on the first wired interface with a cable
2. looks up the current stable HAOS version for your architecture (`generic-x86-64` or `generic-aarch64`)
3. lists your disks and asks which one to install to, then asks you to type its name to confirm
4. streams the image straight onto the disk (`curl | xzcat | dd`), and checks the HAOS partitions are there
5. on UEFI machines, adds a "Home Assistant OS" boot entry and puts it first, so the reboot starts HAOS
   instead of booting from the network again

If anything fails, it drops to a shell instead of rebooting.

## Requirements

- An **x86-64 or arm64 machine with UEFI**, the same machines the HAOS `generic-x86-64` and
  `generic-aarch64` images support. **Secure Boot must be off** (HAOS needs that too).
- At least 2 GB of RAM (for HAOS itself).
- **Wired** Ethernet with DHCP and internet access. Wi-Fi isn't supported.
- A keyboard and screen (x86) or a serial console (arm64) to answer the prompts.

Raspberry Pis aren't supported: use the official Raspberry Pi image instead.

## Quick start

### 1. Serve the netboot files

Download `haos-netinstall-<version>.tar.gz` from [Releases](../../releases), check it, and serve the
folder over HTTP from any machine on your network:

```sh
sha256sum --check SHA256SUMS
tar -xzf haos-netinstall-*.tar.gz
cd netboot
sha256sum --check SHA256SUMS
python3 -m http.server 8000      # or any web server
```

The folder contains:

```
netboot/
├── haos.ipxe         the iPXE script; picks the files for the machine's architecture
├── x86_64/{vmlinuz,initrd}
└── arm64/{vmlinuz,initrd}
```

### 2. Boot the machine into it

You need [iPXE](https://ipxe.org) to load `haos.ipxe`. Pick whichever of these is easiest.

**A. From a USB stick or CD (no network changes).** Write a stock iPXE image (`ipxe.efi`, `ipxe.usb` or
`ipxe.iso` from [boot.ipxe.org](https://boot.ipxe.org), or `nix build nixpkgs#ipxe`) to a USB stick and
boot from it. Press **Ctrl-B** when it says so to get the iPXE shell, then type:

```
dhcp
chain http://192.168.1.10:8000/haos.ipxe
```

with your server's address instead of `192.168.1.10`.

**B. Network boot (PXE) with dnsmasq.** Have your DHCP server send the firmware iPXE over TFTP, and send
iPXE the script. iPXE identifies itself with the DHCP user class `iPXE`, which is what stops it from
loading itself again in a loop. With [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html):

```ini
enable-tftp
tftp-root=/srv/tftp          # put the iPXE EFI binaries here

# The firmware's architecture: 7 and 9 are x86-64 UEFI, 11 is arm64 UEFI
dhcp-match=set:efi-x86_64,option:client-arch,7
dhcp-match=set:efi-x86_64,option:client-arch,9
dhcp-match=set:efi-arm64,option:client-arch,11
dhcp-userclass=set:ipxe,iPXE

# Firmware: load iPXE.  iPXE: load the installer script.
dhcp-boot=tag:efi-x86_64,tag:!ipxe,ipxe-x86_64.efi
dhcp-boot=tag:efi-arm64,tag:!ipxe,ipxe-arm64.efi
dhcp-boot=tag:ipxe,http://192.168.1.10:8000/haos.ipxe
```

If your router is your DHCP server, dnsmasq can add the boot information alongside it in proxy mode
(`dhcp-range=<your subnet>,proxy`); see the dnsmasq documentation.

**C. From an existing iPXE menu.** If you already network boot with iPXE (your own menu, or a custom
[netboot.xyz](https://netboot.xyz) menu), add an entry that runs `chain http://192.168.1.10:8000/haos.ipxe`.

### 3. Install

The installer lists your disks:

```
DEVICE             SIZE  REMOVABLE MODEL
/dev/nvme0n1     238.5G  no        Samsung SSD 980
/dev/sda          28.9G  yes       Cruzer Blade
Install to which disk? (e.g. nvme0n1):
```

Type the disk's name, then type it again to confirm. When it's done, the machine reboots into Home
Assistant OS. After a few minutes, open `http://homeassistant.local:8123`.

## Consoles

On x86, the prompts appear on the **screen** (kernel messages also go to the first serial port). On arm64,
they appear on the **serial console** (`ttyAMA0`). To choose yourself, set `console` in iPXE before
loading the script; the last `console=` is where the prompts appear:

```
set console console=tty0 console=ttyS0
chain http://192.168.1.10:8000/haos.ipxe
```

## Troubleshooting

- **It installs, reboots, and installs again.** The firmware is still booting from the network first.
  Change the boot order so the disk comes first. In Proxmox, the VM's *Boot Order* setting overrides
  the boot entry the installer adds, so put the disk above the network there.
- **"no disks found" or DHCP fails.** The installer probably has no driver for your disk controller or
  network card. The drivers it includes are listed in `rootModules` in [`flake.nix`](flake.nix); please
  open an issue with your hardware.
- **Something else failed.** The installer drops to a shell. `dmesg`, `ip addr` and `cat /proc/partitions`
  are useful to look at; include them in an issue.

## Building

Everything is built with [Nix](https://nixos.org) (flakes enabled):

```sh
nix build .#netboot                         # the netboot folder for this machine's architecture
nix build .#packages.x86_64-linux.netboot   # or a specific one
```

Building for the other architecture needs a builder for it, for example
`boot.binfmt.emulatedSystems = [ "x86_64-linux" ];` on an arm64 NixOS machine.

### Testing in QEMU

| Command | What it does |
|---|---|
| `nix run .#vm` | Boot the installer directly (no firmware or network boot), with virtio, NVMe and USB disks |
| `nix run .#vm-pxe` | The whole flow: UEFI → PXE → iPXE → installer, with a virtio network card and an NVMe disk. Run it again to boot the installed HAOS |
| `nix run .#vm-pxe-pc` | The same with PC hardware: an Intel e1000e network card and a SATA disk (x86_64 only) |
| `nix run .#vm-disk` | Boot what's installed on the `vm` NVMe disk |

Each has `-x86_64` and `-aarch64` versions (e.g. `nix run .#vm-pxe-x86_64`) to test the other
architecture, emulated. Disk images live in `.vm/`; delete it to start over. The HAOS web UI is
forwarded to `http://localhost:8123` in `vm-disk` and the `vm-pxe` VMs. On x86, HAOS prints to the
screen only, not the serial port, so after the reboot the terminal goes quiet; check the web UI instead.

## License

[Apache-2.0](LICENSE). Home Assistant is a trademark of the Open Home Foundation.
