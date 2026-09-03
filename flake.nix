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
          initialCompdump = host.runCommand "nixterm-zcompdump" { nativeBuildInputs = [ host.zsh ]; } ''
            mkdir -p "$out"
            ZSH_COMPDUMP="$out/.zcompdump" zsh -dfc '
              fpath=(
                ${guest.oh-my-zsh}/share/oh-my-zsh/plugins/git
                ${guest.oh-my-zsh}/share/oh-my-zsh/functions
                ${guest.oh-my-zsh}/share/oh-my-zsh/completions
                ${guest.oh-my-zsh}/share/oh-my-zsh/custom/functions
                ${guest.oh-my-zsh}/share/oh-my-zsh/custom/completions
                /run/nixterm-zsh/cache/completions
                $fpath
              )
              autoload -U compinit
              compinit -u -d "$ZSH_COMPDUMP"
              print >> "$ZSH_COMPDUMP"
              print -r -- "#omz revision: " >> "$ZSH_COMPDUMP"
              print -r -- "#omz fpath: $fpath" >> "$ZSH_COMPDUMP"
            '
          '';
          runtimeInit = host.writeScript "nixterm-runtime-init" ''
            #!${busybox}/bin/sh

            export PATH=${guestPath}
            export HOME=/root
            export TERM=xterm-256color
            export USER=root
            export LOGNAME=root
            export LANG=C.UTF-8
            export LC_ALL=C.UTF-8
            export SHELL=${guest.zsh}/bin/zsh
            export SSL_CERT_FILE=${guest.cacert}/etc/ssl/certs/ca-bundle.crt
            export PS1='\u@nixterm:\w\$ '

            mkdir -p /dev /proc /sys /run /tmp /root /etc
            [ -e /dev/null ] || mount -t devtmpfs devtmpfs /dev
            mkdir -p /dev/pts /dev/shm
            mount -t proc proc /proc
            mount -t sysfs sysfs /sys
            mount -t devpts devpts /dev/pts
            mount -t tmpfs tmpfs /dev/shm
            mount -t tmpfs tmpfs /run
            mount -t tmpfs tmpfs /tmp
            mount -t tmpfs tmpfs /etc
            hostname nixterm
            chmod 1777 /tmp

            export ZDOTDIR=/run/nixterm-zsh
            mkdir -p "$ZDOTDIR"
            cat > "$ZDOTDIR/.zshrc" <<'EOF'
            export ZSH=${guest.oh-my-zsh}/share/oh-my-zsh
            PROMPT_EOL_MARK=""
            ZSH_CACHE_DIR="$ZDOTDIR/cache"
            ZSH_COMPDUMP="$ZDOTDIR/.zcompdump"
            mkdir -p "$ZSH_CACHE_DIR"
            cp -p ${initialCompdump}/.zcompdump "$ZSH_COMPDUMP"
            fpath=(
              "$ZSH/plugins/git"
              "$ZSH/functions"
              "$ZSH/completions"
              "$ZSH_CACHE_DIR/completions"
              $fpath
            )
            autoload -U compinit
            compinit -C -d "$ZSH_COMPDUMP"
            zstyle ':completion:*' menu select

            HISTFILE=/root/.zsh_history
            HISTSIZE=50000
            SAVEHIST=10000
            setopt append_history extended_history hist_expire_dups_first hist_ignore_dups hist_ignore_space share_history
            bindkey -e
            alias g=git ga='git add' gc='git commit' gd='git diff' gl='git pull' gp='git push' gst='git status'
            PROMPT='%(?.%F{green}.%F{red})➜  %F{cyan}%1~%f '
            nixterm_update_size() {
              local columns rows
              if [[ -r /root/.nixterm-size ]] && read columns rows < /root/.nixterm-size; then
                stty cols "$columns" rows "$rows"
              fi
            }
            nixterm_report_ready() {
              printf '\033]777;nixterm-ready\007'
              precmd_functions=(''${precmd_functions:#nixterm_report_ready})
            }
            precmd_functions+=(nixterm_update_size nixterm_report_ready)
            [[ -r /root/.zshrc ]] && source /root/.zshrc
            EOF

            ip link set lo up
            ip link set eth0 up
            ip address add 10.0.2.15/24 dev eth0
            ip route add default via 10.0.2.2
            echo 'root:x:0:0:root:/root:${guest.zsh}/bin/zsh' > /etc/passwd
            echo 'root:x:0:' > /etc/group
            echo 'nameserver 10.0.2.3' > /etc/resolv.conf

            # QEMU cannot migrate an attached 9p export, so pause immediately before mounting it.
            printf '\033]777;nixterm-snapshot-ready\007'
            read -r _ </dev/ttyAMA0
            mount -t 9p -o trans=virtio,version=9p2000.L hostshare /root || \
              echo 'warning: persistent Documents mount unavailable' >&2
            cd /root

            exec </dev/ttyAMA0 >/dev/ttyAMA0 2>&1
            if [ -r /root/.nixterm-size ] && read columns rows < /root/.nixterm-size; then
              stty -F /dev/ttyAMA0 cols "$columns" rows "$rows"
            fi
            echo
            echo 'NixTerm Linux'
            echo "Kernel $(uname -r), aarch64, packages selected by guest-packages.nix"
            echo 'Home: iOS Documents via virtio-9p; network: QEMU SLiRP'
            echo
            exec setsid cttyhack ${guest.zsh}/bin/zsh -l
          '';
          bootInit = host.writeScript "nixterm-boot-init" ''
            #!${busybox}/bin/sh

            mkdir -p /dev /new-root
            mount -t devtmpfs devtmpfs /dev
            mount -t squashfs -o ro /dev/vda /new-root
            exec switch_root /new-root /init
          '';
          rootClosure = host.closureInfo {
            rootPaths = [
              runtimeInit
              busybox
            ]
            ++ guestPackages;
          };
          rootImage = host.runCommand "nixterm-root.squashfs" { nativeBuildInputs = [ host.squashfsTools ]; } ''
            mkdir -p root/{dev,etc,proc,root,run,sys,tmp}
            while read -r path; do
              cp -a --parents "$path" root
            done < ${rootClosure}/store-paths
            ln -s ${runtimeInit} root/init
            mksquashfs root "$out" -noappend -comp lz4 -no-progress
          '';
          initrd = host.makeInitrd {
            name = "nixterm-initramfs";
            compressor = "cat";
            contents = [
              {
                object = bootInit;
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
            ];
          };
        in
        host.runCommand "nixterm-linux-guest" { } ''
          mkdir -p "$out"
          cp ${kernel}/Image "$out/Image"
          cp ${initrd}/initrd "$out/initramfs.cpio"
          cp ${rootImage} "$out/root.squashfs"
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
              rm -f Resources/Guest/initramfs.cpio.gz Resources/Guest/initramfs.cpio.lz4
              install -m 0644 ${guestBundle}/Image Resources/Guest/Image
              install -m 0644 ${guestBundle}/initramfs.cpio Resources/Guest/initramfs.cpio
              install -m 0644 ${guestBundle}/root.squashfs Resources/Guest/root.squashfs
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
