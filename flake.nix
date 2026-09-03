{
  description = "A Nix-built Linux terminal running inside QEMU on iOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = lib.genAttrs systems;

      guest = nixpkgs.legacyPackages.aarch64-linux;
      kernel = guest.linux;
      busybox = guest.pkgsStatic.busybox;
      guestPackages = import ./guest-packages.nix guest;
      guestPath = lib.makeBinPath ([ busybox ] ++ guestPackages);
      makeGuestBundle =
        host:
        let
          init = host.writeScript "nixterm-init" ''
            #!${busybox}/bin/sh

            export PATH=${guestPath}
            export HOME=/root
            export TERM=xterm-256color
            export USER=root
            export LOGNAME=root
            export SHELL=${guest.bashInteractive}/bin/bash
            export SSL_CERT_FILE=${guest.cacert}/etc/ssl/certs/ca-bundle.crt
            export PS1='\u@nixterm:\w\$ '

            mkdir -p /dev /proc /sys /run /tmp /root
            mount -t devtmpfs devtmpfs /dev
            mkdir -p /dev/pts /dev/shm
            mount -t proc proc /proc
            mount -t sysfs sysfs /sys
            mount -t devpts devpts /dev/pts
            mount -t tmpfs tmpfs /dev/shm
            hostname nixterm
            chmod 1777 /tmp

            ip link set lo up
            ip link set eth0 up
            ip address add 10.0.2.15/24 dev eth0
            ip route add default via 10.0.2.2
            mkdir -p /etc
            echo 'nameserver 10.0.2.3' > /etc/resolv.conf
            mount -t 9p -o trans=virtio,version=9p2000.L hostshare /root || \
              echo 'warning: persistent Documents mount unavailable' >&2
            cd /root

            exec </dev/ttyAMA0 >/dev/ttyAMA0 2>&1
            echo
            echo 'NixTerm Linux'
            echo "Kernel $(uname -r), aarch64, packages selected by guest-packages.nix"
            echo 'Home: iOS Documents via virtio-9p; network: QEMU SLiRP'
            echo
            exec setsid cttyhack ${guest.bashInteractive}/bin/bash --noprofile --norc -i
          '';
          passwd = host.writeText "nixterm-passwd" ''
            root:x:0:0:root:/root:${guest.bashInteractive}/bin/bash
          '';
          group = host.writeText "nixterm-group" ''
            root:x:0:
          '';
          initrd = host.makeInitrd {
            name = "nixterm-initramfs";
            compressor = "gzip";
            compressorArgs = [ "-9n" ];
            contents = [
              {
                object = init;
                symlink = "/init";
              }
              {
                object = "${busybox}/bin";
                symlink = "/bin";
              }
              {
                object = "${busybox}/sbin";
                symlink = "/sbin";
              }
              {
                object = passwd;
                symlink = "/etc/passwd";
              }
              {
                object = group;
                symlink = "/etc/group";
              }
            ];
          };
        in
        host.runCommand "nixterm-linux-guest" { } ''
          mkdir -p "$out"
          cp ${kernel}/Image "$out/Image"
          cp ${initrd}/initrd "$out/initramfs.cpio.gz"
        '';
    in
    {
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      packages = forAllSystems (
        system:
        let
          guestBundle = makeGuestBundle nixpkgs.legacyPackages.${system};
        in
        {
          guest = guestBundle;
          default = guestBundle;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          guest-definition = pkgs.runCommand "guest-definition-check" { } ''
            test -s ${./guest-packages.nix}
            touch "$out"
          '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.gh
              pkgs.swiftformat
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.qemu ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
              pkgs.xcodegen
              pkgs.xcbeautify
            ];
          };
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          guestBundle = makeGuestBundle pkgs;
          prepareGuest = pkgs.writeShellApplication {
            name = "nixterm-prepare-guest";
            text = ''
              mkdir -p Resources/Guest
              install -m 0644 ${guestBundle}/Image Resources/Guest/Image
              install -m 0644 ${guestBundle}/initramfs.cpio.gz Resources/Guest/initramfs.cpio.gz
            '';
          };
          buildInstall = pkgs.writeShellApplication {
            name = "nixterm-build-install";
            runtimeInputs = [
              pkgs.xcodegen
              pkgs.xcbeautify
            ];
            text = ''
              exec ${pkgs.bash}/bin/bash ${./scripts/build-install.sh} "$@"
            '';
          };
          prepareQEMU = pkgs.writeShellApplication {
            name = "nixterm-prepare-qemu";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.gh
              pkgs.gnutar
            ];
            text = ''
              exec ${pkgs.bash}/bin/bash ${./scripts/prepare-qemu-frameworks.sh} "$@"
            '';
          };
        in
        {
          prepare-guest = {
            type = "app";
            program = "${prepareGuest}/bin/nixterm-prepare-guest";
            meta.description = "Copy the Nix-built Linux guest into app resources";
          };
          prepare-qemu = {
            type = "app";
            program = "${prepareQEMU}/bin/nixterm-prepare-qemu";
            meta.description = "Fetch the pinned UTM TCI QEMU framework closure";
          };
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
          build-install = {
            type = "app";
            program = "${buildInstall}/bin/nixterm-build-install";
            meta.description = "Build, sign, and install NixTerm on a paired iOS device";
          };
        }
      );
    };
}
