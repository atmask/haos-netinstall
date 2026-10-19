{
  description = "Unofficial Network Installer ofr Home Assistant OS";
  
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  };

  outputs = inputs@{ self, nixpkgs, ... }:
  let
    system = "aarch64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    packages.${system} = {
      kernel = pkgs.linuxPackages.kernel;

      initramfs = pkgs.makeInitrdNG {
        compressor = "zstd";
        contents = [
         { source = ./installer/init; target = "/init"; }
         { source = "${pkgs.pkgsStatic.busybox}/bin/busybox"; target = "/bin/busybox"; }
         { source = ./installer/udhcpc.script; target = "/usr/share/udhcp/default.script"; }
        ];
      };
    };
  };
}
