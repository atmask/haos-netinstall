{
  description = "Unofficial Network Installer ofr Home Assistant OS";
  
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  };

  outputs = inputs@{ self, nixpkgs, ... }:
  let
    system = "aarch64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    kp = pkgs.linuxPackages;
    modules = pkgs.makeModulesClosure {
      kernel = pkgs.lib.getOutput "modules" kp.kernel;
      firmware = pkgs.linux-firmware;
      rootModules = [ "nvme" ];
      allowMissing = true;
    };
    # QEMU DHCP will point to ipxe.efi here.
    # emebed into the ipxe efi out custom script to hit dhcp again for ipxe client config and then get haos-netinstall ipxe script
    ipxeTest = pkgs.ipxe.override { embedScript = ./ipxe/embed.ipxe; };
  in {
    packages.${system} = {
      kernel = kp.kernel;

      initramfs = pkgs.makeInitrdNG {
        compressor = "zstd";
        contents = [
         { source = ./installer/init; target = "/init"; }
         { source = "${pkgs.pkgsStatic.busybox}/bin/busybox"; target = "/bin/busybox"; }
         { source = ./installer/udhcpc.script; target = "/usr/share/udhcpc/default.script"; }
         { source = ./installer/lib/disks.sh; target = "/usr/lib/haos-netinstall/disks.sh"; }
         { source = pkgs.lib.getExe pkgs.pkgsStatic.curl; target = "/bin/curl"; }
         { source = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"; target = "/etc/ssl/certs/ca-certificates.crt"; }
         { source = "${modules}/lib/modules"; target = "/lib/modules"; }
        ];
      };

      # The build folder to server
      netboot = pkgs.linkFarm "haos-netinstall-netboot" [
        { name = "haos.ipxe"; path = ./ipxe/haos.ipxe; }
        { name = "arm64/vmlinuz"; path = "${kp.kernel}/Image"; }
        { name = "arm64/initrd"; path = "${self.packages.${system}.initramfs}/initrd"; }
      ];
    };

    apps.${system} = {
      vm = {
        type = "app";
        program = toString (pkgs.writeShellScript "haos-netinstall-vm" ''
          set -eu
          state=.vm #disk image lives here (add to .gitignore)
          
          # set up qcow2 disks
          mkdir -p "$state"
          for d in virtio nvme usb; do
            [ -e "$state/$d.qcow2" ] || ${pkgs.qemu}/bin/qemu-img create -f qcow2 "$state/$d.qcow2" 10G
          done


          exec ${pkgs.qemu}/bin/qemu-system-aarch64 \
            -M virt -cpu max -m 1G -nographic -no-reboot \
            -kernel ${self.packages.${system}.kernel}/Image \
            -initrd ${self.packages.${system}.initramfs}/initrd \
            -append "console=ttyAMA0 panic=-1 ''${KARGS:-}" \
            -nic user,model=virtio-net-pci \
            -drive file="$state/virtio.qcow2",if=virtio,format=qcow2 \
            -drive file="$state/nvme.qcow2",if=none,id=nvm,format=qcow2 \
            -device nvme,serial=haos-test,drive=nvm \
            -device qemu-xhci \
            -drive file="$state/usb.qcow2",if=none,id=usb,format=qcow2 \
            -device usb-storage,drive=usb,removable=on \
            "$@"
        '');
      };

      vm-disk = {
        type = "app";
        program = toString (pkgs.writeShellScript "haos-netinstall-vm" ''
          set -eu
          state=.vm #disk image lives here (add to .gitignore)
          [ -e "$state/efivars.fd" ] || cp ${pkgs.qemu}/share/qemu/edk2-arm-vars.fd "$state/efivars.fd"
          chmod u+w "$state/efivars.fd"

          exec ${pkgs.qemu}/bin/qemu-system-aarch64 \
            -M virt -cpu max -m 2G -nographic -no-reboot \
            -drive if=pflash,format=raw,readonly=on,file=${pkgs.qemu}/share/qemu/edk2-aarch64-code.fd \
            -drive if=pflash,format=raw,file="$state/efivars.fd" \
            -nic user,model=virtio-net-pci,hostfwd=tcp::8123-:80 \
            -drive file="$state/nvme.qcow2",if=none,id=nvm,format=qcow2 \
            -device nvme,serial=haos-test,drive=nvm \
            "$@" 
            '');
      };


    };
  };
}
