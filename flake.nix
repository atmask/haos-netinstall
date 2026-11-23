{
  description = "Unofficial network installer for Home Assistant OS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  };

  outputs = inputs@{ self, nixpkgs, ... }:
  let
    lib = nixpkgs.lib;

    # Each system is both a target (the machine HAOS gets installed on) and a host (where the test VMs run)
    systems = [ "aarch64-linux" "x86_64-linux" ];
    forAllSystems = lib.genAttrs systems;

    # What differs between targets
    targets = {
      aarch64-linux = {
        arch = "arm64";  # the folder name; matches iPXE's ${buildarch}
        qemu = "qemu-system-aarch64 -M virt -cpu max";
        console = "ttyAMA0";
        firmware = "edk2-aarch64-code.fd";
        vars = "edk2-arm-vars.fd";
      };
      x86_64-linux = {
        arch = "x86_64";
        qemu = "qemu-system-x86_64 -M q35 -cpu max";
        console = "ttyS0";
        firmware = "edk2-x86_64-code.fd";
        vars = "edk2-i386-vars.fd";
      };
    };

    # The installer, built for one target
    mkPackages = system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      kp = pkgs.linuxPackages;
      modules = pkgs.makeModulesClosure {
        kernel = pkgs.lib.getOutput "modules" kp.kernel;
        firmware = pkgs.linux-firmware;
        # The drivers that go in the initramfs; init loads the ones matching the hardware it finds.
        # Built into the kernel on some targets (e.g. virtio on aarch64); allowMissing skips those
        rootModules = [
          "efivarfs" "af_packet"
          # VMs (QEMU, Proxmox)
          "virtio_pci" "virtio_net" "virtio_blk" "virtio_scsi"
          # Disks: NVMe, SATA, USB, SD/eMMC
          "nvme" "ahci" "ata_piix" "sd_mod" "usb_storage" "uas" "mmc_block" "sdhci_pci" "sdhci_acpi"
          # USB controllers and keyboards (to answer the installer's prompts)
          "xhci_pci" "ehci_pci" "usbhid" "hid_generic"
          # Wired network cards: Intel, Realtek, Broadcom, and common USB adapters
          "e1000" "e1000e" "igb" "igc" "r8169" "tg3" "r8152" "cdc_ether" "ax88179_178a"
        ];
        allowMissing = true;
      };

      initramfs = pkgs.makeInitrdNG {
        compressor = "zstd";
        contents = [
         { source = ./installer/init; target = "/init"; }
         { source = "${pkgs.pkgsStatic.busybox}/bin/busybox"; target = "/bin/busybox"; }
         { source = ./installer/udhcpc.script; target = "/usr/share/udhcpc/default.script"; }
         { source = ./installer/haos-netinstall; target = "/usr/bin/haos-netinstall"; }
         { source = ./installer/lib/disks.sh; target = "/usr/lib/haos-netinstall/disks.sh"; }
         { source = pkgs.lib.getExe pkgs.pkgsStatic.curl; target = "/bin/curl"; }
         # Not pkgsStatic: static jq depends on a static tzdata whose tests fail at build time, and static
         # packages aren't in the binary cache, so CI builds them. Dynamic works the same as efibootmgr below.
         { source = pkgs.lib.getExe pkgs.jq; target = "/bin/jq"; }
         # Not pkgsStatic: efivar's build always links a shared libefiboot.so, which fails with static musl.
         # A dynamic binary is fine, makeInitrdNG copies the libraries it needs into the initramfs.
         { source = pkgs.lib.getExe pkgs.efibootmgr; target = "/bin/efibootmgr"; }
         { source = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"; target = "/etc/ssl/certs/ca-certificates.crt"; }
         { source = "${modules}/lib/modules"; target = "/lib/modules"; }
        ];
      };

      arch = targets.${system}.arch;
    in {
      kernel = kp.kernel;
      inherit initramfs;

      # The build folder to server
      netboot = pkgs.linkFarm "haos-netinstall-netboot-${arch}" [
        { name = "haos.ipxe"; path = ./ipxe/haos.ipxe; }
        # The kernel file is "Image" on aarch64 and "bzImage" on x86_64
        { name = "${arch}/vmlinuz"; path = "${kp.kernel}/${pkgs.stdenv.hostPlatform.linux-kernel.target}"; }
        { name = "${arch}/initrd"; path = "${initramfs}/initrd"; }
      ];

      # QEMU DHCP will point to ipxe.efi here.
      # emebed into the ipxe efi out custom script to hit dhcp again for ipxe client config and then get haos-netinstall ipxe script
      ipxe-test = pkgs.ipxe.override { embedScript = ./ipxe/embed.ipxe; };
    };

    # Test VMs that run on `host`. A VM's target can be another arch, QEMU then emulates it (slowly).
    mkApps = host:
    let
      pkgs = nixpkgs.legacyPackages.${host};
      qemu = pkgs.qemu;
      app = name: script: { type = "app"; program = toString (pkgs.writeShellScript name script); };

      vmsFor = system:
      let
        t = targets.${system};
        p = self.packages.${system};
        state = ".vm/${system}";  # disk images and firmware settings live here (in .gitignore)

        # The real flow: UEFI firmware -> PXE -> iPXE -> haos.ipxe over HTTP -> installer.
        # `disk` names the disk image and firmware settings, so each variant keeps its own.
        pxeVm = name: disk: devices: app name ''
          set -eu
          state=${state}
          mkdir -p "$state"
          [ -e "$state/${disk}.qcow2" ] || ${qemu}/bin/qemu-img create -f qcow2 "$state/${disk}.qcow2" 10G
          # separate firmware settings so boot entries don't mix with vm-disk
          [ -e "$state/efivars-pxe-${disk}.fd" ] || cp ${qemu}/share/qemu/${t.vars} "$state/efivars-pxe-${disk}.fd"
          chmod u+w "$state/efivars-pxe-${disk}.fd"

          # serve the netboot folder on port 8000; reachable from the guest as 10.0.2.2
          ${pkgs.busybox}/bin/busybox httpd -f -p 8000 -h ${p.netboot} &
          httpd=$!
          trap 'kill $httpd' EXIT

          # QEMU's DHCP points the firmware at ipxe.efi, served by its built-in TFTP.
          # No bootindex: with it, edk2 re-sorts BootOrder to QEMU's order on every boot, undoing
          # the installer's boot entry. Without it, the saved BootOrder is used, like a real PC.
          # 2G: the second run boots the installed HAOS, which needs at least 2G
          ${qemu}/bin/${t.qemu} -m 2G -nographic -no-reboot \
            -drive if=pflash,format=raw,readonly=on,file=${qemu}/share/qemu/${t.firmware} \
            -drive if=pflash,format=raw,file="$state/efivars-pxe-${disk}.fd" \
            -netdev user,id=net0,tftp=${p.ipxe-test},bootfile=ipxe.efi,hostfwd=tcp::8123-:80 \
            ${devices} \
            "$@"
        '';
      in {
        # Boot the installer directly with -kernel, skipping firmware and the network boot
        vm = app "haos-netinstall-vm" ''
          set -eu
          state=${state}

          # set up qcow2 disks
          mkdir -p "$state"
          for d in virtio nvme usb; do
            [ -e "$state/$d.qcow2" ] || ${qemu}/bin/qemu-img create -f qcow2 "$state/$d.qcow2" 10G
          done

          exec ${qemu}/bin/${t.qemu} -m 1G -nographic -no-reboot \
            -kernel ${p.netboot}/${t.arch}/vmlinuz \
            -initrd ${p.netboot}/${t.arch}/initrd \
            -append "console=${t.console} panic=-1 ''${KARGS:-}" \
            -nic user,model=virtio-net-pci \
            -drive file="$state/virtio.qcow2",if=virtio,format=qcow2 \
            -drive file="$state/nvme.qcow2",if=none,id=nvm,format=qcow2 \
            -device nvme,serial=haos-test,drive=nvm \
            -device qemu-xhci \
            -drive file="$state/usb.qcow2",if=none,id=usb,format=qcow2 \
            -device usb-storage,drive=usb,removable=on \
            "$@"
        '';

        # Boot whatever is installed on the NVMe disk, with the HA UI forwarded to host port 8123
        vm-disk = app "haos-netinstall-vm-disk" ''
          set -eu
          state=${state}
          mkdir -p "$state"
          [ -e "$state/efivars.fd" ] || cp ${qemu}/share/qemu/${t.vars} "$state/efivars.fd"
          chmod u+w "$state/efivars.fd"

          exec ${qemu}/bin/${t.qemu} -m 2G -nographic -no-reboot \
            -drive if=pflash,format=raw,readonly=on,file=${qemu}/share/qemu/${t.firmware} \
            -drive if=pflash,format=raw,file="$state/efivars.fd" \
            -nic user,model=virtio-net-pci,hostfwd=tcp::8123-:80 \
            -drive file="$state/nvme.qcow2",if=none,id=nvm,format=qcow2 \
            -device nvme,serial=haos-test,drive=nvm \
            "$@"
        '';

        # Network boot with VM hardware: virtio network card, NVMe disk
        vm-pxe = pxeVm "haos-netinstall-vm-pxe" "nvme" ''
          -device virtio-net-pci,netdev=net0 \
          -drive file="$state/nvme.qcow2",if=none,id=nvm,format=qcow2 \
          -device nvme,serial=haos-test,drive=nvm \
        '';

        # Network boot with PC hardware: Intel e1000e network card, SATA disk (tests the real drivers).
        # x86_64 only: the arm64 firmware has no driver to network boot from an e1000e.
        vm-pxe-pc = pxeVm "haos-netinstall-vm-pxe-pc" "sata" ''
          -device e1000e,netdev=net0 \
          -device ahci,id=ahci \
          -drive file="$state/sata.qcow2",if=none,id=sata,format=qcow2 \
          -device ide-hd,drive=sata,bus=ahci.0 \
        '';
      };

      # vm-pxe -> vm-pxe-x86_64, for running a specific target
      suffixed = system: lib.mapAttrs'
        (name: value: lib.nameValuePair "${name}-${lib.removeSuffix "-linux" system}" value)
        (vmsFor system);
    in
      # Plain vm, vm-disk, vm-pxe run the host's own arch; the suffixed ones pick a target
      vmsFor host // suffixed "aarch64-linux" // suffixed "x86_64-linux";
  in {
    packages = forAllSystems mkPackages;
    apps = forAllSystems mkApps;
  };
}
