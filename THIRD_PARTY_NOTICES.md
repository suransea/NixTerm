# Third-Party Notices

NixTerm includes or derives from the following components:

- SwiftTerm at revision `4b6cfc6bba6ff045985eed528abe830be3301d30`, MIT license.
- UTM launcher design and TCI framework build at revision `b6f7475be54f9cb542c46b131319454b83489ced`, Apache License 2.0.
- UTM's QEMU fork release `v10.0.12-utm`, GNU General Public License version 2.
- Linux and the Nix-built guest package closure, under their respective upstream licenses.
- FreeBSD 14.4 and its base-system components, under their respective BSD and upstream licenses.
- Zsh 5.9.2, under the Zsh license.
- Oh My Zsh at revision `9112b53fa8b5ab556c7c893aa8be8a247ac512a0`, MIT license.

The QEMU framework artifact is currently taken from UTM GitHub Actions run `33593908499`; `scripts/prepare-qemu-frameworks.sh` verifies the extracted archive with SHA-256. Redistribution must include the corresponding QEMU and Linux sources, UTM patches, build scripts, GPL license text, and notices for the complete framework and guest closure. This repository does not yet provide a release-compliance source bundle and should not be publicly distributed as a binary until one is generated.

SwiftTerm retains its upstream copyright and permission notices. The adapted Objective-C launcher files retain Apache-2.0 attribution in their headers and are based on UTM's `UTMProcess` and `UTMQemuSystem` implementation by osy and contributors.
