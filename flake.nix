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
    };

    apps.${system}.vm = {
      type = "app";
      program = toString (pkgs.writeShellScript "haos-netinstall-vm" ''
        set -eu
        state=.vm #disk image lives here (add to .gitignore)
        
        # set up qcow2 disks
        mkdir -p "$state"
        for d in virtio nvme usb; do
          [ -e "$state/$d.qcow2" ] || ${pkgs.qemu}/bin/qemu-img create -f qcow2 "$state/$d.qcow2" 32G
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
  };
}
