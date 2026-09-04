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
            hwclock --hctosys --utc || echo 'warning: unable to synchronize guest clock' >&2
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
          rootImage =
            host.runCommand "nixterm-root.squashfs" { nativeBuildInputs = [ host.squashfsTools ]; }
              ''
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
      makeFreeBSDGuestBundle =
        host:
        let
          image = host.fetchurl {
            url = "https://download.freebsd.org/releases/VM-IMAGES/14.4-RELEASE/aarch64/Latest/FreeBSD-14.4-RELEASE-arm64-aarch64-ufs.qcow2.xz";
            hash = "sha256-kKOgJd2kae1hsVgrYbOlAVy734o7zHQeFmSGgxddYbw=";
          };
          pkgPackage = host.fetchurl {
            url = "https://pkg.freebsd.org/FreeBSD:14:aarch64/latest/All/Hashed/pkg-2.8.4~2%2476rad79q.pkg";
            hash = "sha256-q+y3uYtE7WYxpPVVYrBAVB6R9TkYL7zA4Z22mjsgzSE=";
          };
          zshPackage = host.fetchurl {
            url = "https://pkg.freebsd.org/FreeBSD:14:aarch64/latest/All/Hashed/zsh-5.9.2~2%24koyfnxux.pkg";
            hash = "sha256-1GVdU6ESq5H1psK6aXRIkLLCsqvidbkcLW0LiP8qHF4=";
          };
          ohMyZsh = host.fetchurl {
            url = "https://github.com/ohmyzsh/ohmyzsh/archive/9112b53fa8b5ab556c7c893aa8be8a247ac512a0.tar.gz";
            hash = "sha256-uMd8WPHL0GVzi7/7YTCVgFy/cy3StdSO2wvu/jGcPP4=";
          };
          configuration = host.runCommand "nixterm-freebsd-configuration" { } ''
            mkdir -p "$out"
            cp ${pkgPackage} "$out/pkg.pkg"
            cp ${zshPackage} "$out/zsh.pkg"
            cp ${ohMyZsh} "$out/oh-my-zsh.tar.gz"
            cat > "$out/configure.sh" <<'SCRIPT'
            set -eu

            cat > /boot/loader.conf.local <<'EOF'
            autoboot_delay="0"
            beastie_disable="YES"
            virtio_p9fs_load="YES"
            EOF
            sysrc hostname=nixterm-freebsd
            sysrc ifconfig_vtnet0="inet 10.0.2.15 netmask 255.255.255.0"
            sysrc defaultrouter=10.0.2.2
            sysrc syslogd_enable=NO
            sysrc cron_enable=NO
            sysrc background_fsck=NO
            sysrc cleanvar_enable=NO
            sysrc devd_enable=NO
            sysrc devmatch_enable=NO
            sysrc dmesg_enable=NO
            sysrc gptboot_enable=NO
            sysrc growfs_enable=NO
            sysrc hostid_enable=NO
            sysrc ip6addrctl_enable=NO
            sysrc ipv6_network_interfaces=none
            sysrc kldxref_enable=NO
            sysrc mixer_enable=NO
            sysrc newsyslog_enable=NO
            sysrc osrelease_enable=NO
            sysrc rctl_enable=NO
            sysrc resolv_enable=NO
            sysrc savecore_enable=NO
            sysrc update_motd=NO
            sysrc var_run_enable=NO
            sysrc virecover_enable=NO
            printf '%s\n' 'nameserver 10.0.2.3' > /etc/resolv.conf
            env SIGNATURE_TYPE=none /usr/sbin/pkg add -y /mnt/config/pkg.pkg
            /usr/local/sbin/pkg add /mnt/config/zsh.pkg
            tar -xzf /mnt/config/oh-my-zsh.tar.gz -C /root
            mv /root/ohmyzsh-* /root/.oh-my-zsh
            chmod -R go-w /root/.oh-my-zsh
            mkdir -p /root/.oh-my-zsh/custom/themes
            cat > /root/.oh-my-zsh/custom/themes/nixterm-onedark.zsh-theme <<'EOF'
            autoload -Uz colors vcs_info
            colors
            zstyle ':vcs_info:git:*' formats ' %F{176}(%b)%f'
            precmd() { vcs_info }
            PROMPT='%F{75}%1~%f''${vcs_info_msg_0_} %(?.%F{114}➜.%F{203}➜)%f '
            EOF
            pw usermod root -s /usr/local/bin/zsh
            touch /root/.hushlogin
            mkdir -p /mnt/host
            sed -i "" '/rootfs/ s/[[:space:]]rw[[:space:]]/ rw,noatime /' /etc/fstab
            cat >> /etc/fstab <<'EOF'
            tmpfs /tmp tmpfs rw,mode=1777 0 0
            tmpfs /var/log tmpfs rw,mode=0755 0 0
            tmpfs /var/run tmpfs rw,mode=0755 0 0
            tmpfs /var/tmp tmpfs rw,mode=1777 0 0
            EOF
            cat > /root/.zprofile <<'EOF'
            export TERM=xterm-256color
            EOF
            cat > /root/.zshrc <<'EOF'
            export ZSH=/root/.oh-my-zsh
            export ZSH_CACHE_DIR=/tmp/oh-my-zsh-cache
            export ZSH_COMPDUMP=/root/.zcompdump
            ZSH_DISABLE_COMPFIX=true
            DISABLE_AUTO_UPDATE=true
            mkdir -p "$ZSH_CACHE_DIR"
            ZSH_THEME="nixterm-onedark"
            plugins=()
            zstyle ':omz:update' mode disabled
            source "$ZSH/oh-my-zsh.sh"
            if [[ ''${NIXTERM_IMAGE_BUILD:-0} == 1 ]]; then
                return
            fi
            sync
            printf '\033]777;nixterm-snapshot-ready\007'
            read -r _ </dev/ttyu0
            mount -t p9fs hostshare /mnt/host || printf 'warning: persistent Documents mount unavailable\n' >&2
            cd /mnt/host 2>/dev/null || cd /root
            HISTFILE=/mnt/host/.zsh_history
            HISTSIZE=50000
            SAVEHIST=10000
            setopt append_history extended_history hist_expire_dups_first hist_ignore_dups hist_ignore_space share_history
            bindkey -e
            if [ -r /mnt/host/.nixterm-size ]; then
                set -- $(cat /mnt/host/.nixterm-size)
                stty cols "$1" rows "$2"
            fi
            printf '\nNixTerm FreeBSD\n'
            uname -mrs
            printf 'Zsh + Oh My Zsh + One Dark; home: iOS Documents\n\n'
            autoload -Uz add-zsh-hook
            nixterm_report_ready() {
                printf '\033]777;nixterm-ready\007'
                add-zsh-hook -d precmd nixterm_report_ready
            }
            add-zsh-hook precmd nixterm_report_ready
            EOF
            env NIXTERM_IMAGE_BUILD=1 HOME=/root /usr/local/bin/zsh -ilc exit
            /usr/local/sbin/pkg clean -ay
            poweroff
            SCRIPT
          '';
        in
        host.runCommand "nixterm-freebsd-guest"
          {
            nativeBuildInputs = [
              host.expect
              host.qemu
              host.xz
            ];
          }
          ''
            mkdir -p "$out"
            xz -dc ${image} > freebsd.qcow2
            expect <<'EOF'
            log_user 0
            set timeout 300
            spawn qemu-system-aarch64 \
              -machine virt,gic-version=3 \
              -cpu cortex-a53 \
              -accel tcg,thread=single,tb-size=64 \
              -rtc base=utc,clock=host \
              -smp 1 \
              -m 512 \
              -nodefaults \
              -nographic \
              -no-reboot \
              -audio none \
              -netdev user,id=net0 \
              -device virtio-net-pci,netdev=net0,romfile= \
              -device virtio-rng-pci,romfile= \
              -drive file=freebsd.qcow2,format=qcow2,if=none,id=rootfs \
              -device virtio-blk-pci,drive=rootfs,bootindex=1,romfile= \
              -virtfs local,path=${configuration},mount_tag=hostshare,security_model=none,id=hostshare \
              -bios ${host.qemu}/share/qemu/edk2-aarch64-code.fd \
              -serial stdio
            expect {
              "login:" {}
              timeout { puts stderr "FreeBSD guest did not reach login"; exit 1 }
            }
            send "root\r"
            expect {
              "root@freebsd:~ #" {}
              timeout { puts stderr "FreeBSD guest did not open a root shell"; exit 1 }
            }
            send "kldload virtio_p9fs; mkdir -p /mnt/config; mount -t p9fs hostshare /mnt/config; sh /mnt/config/configure.sh\r"
            expect {
              "Uptime:" {}
              timeout { puts stderr "FreeBSD guest customization did not shut down cleanly"; exit 1 }
            }
            expect eof
            EOF
            qemu-img convert -O qcow2 -c -o compression_type=zstd freebsd.qcow2 "$out/FreeBSD.qcow2"
            (
              cd "$out"
              qemu-img create -f qcow2 -F qcow2 -b FreeBSD.qcow2 FreeBSD-overlay.qcow2
            )
            cp ${host.qemu}/share/qemu/edk2-aarch64-code.fd "$out/QEMU_EFI.fd"
          '';
    in
    {
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      packages = forAllSystems (
        system:
        let
          nixosGuestBundle = makeGuestBundle nixpkgs.legacyPackages.${system};
          freebsdGuestBundle = makeFreeBSDGuestBundle nixpkgs.legacyPackages.${system};
        in
        {
          nixos-guest = nixosGuestBundle;
          freebsd-guest = freebsdGuestBundle;
          guest = nixosGuestBundle;
          default = nixosGuestBundle;
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
          prepareGuest = pkgs.writeShellApplication {
            name = "nixterm-prepare-guest";
            runtimeInputs = [ pkgs.nix ];
            text = ''exec ${pkgs.bash}/bin/bash ${./scripts/prepare-guest.sh} "$@"'';
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
            meta.description = "Select and copy a NixOS or FreeBSD guest into app resources";
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
