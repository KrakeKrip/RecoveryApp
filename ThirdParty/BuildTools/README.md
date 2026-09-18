# Build-only DMG tools

These Python modules are used only by `Scripts/package-dmg.sh` while building
the distributable DMG. They are not copied into `RecoveryApp.app` or the final
DMG.

- `dmgbuild` 1.6.7 — MIT license.
- `ds_store` 1.3.3 — MIT license.
- `mac_alias` 2.2.3 — MIT license.

The corresponding license texts are stored in `licenses/`. Upstream projects:

- https://github.com/dmgbuild/dmgbuild
- https://github.com/dmgbuild/ds_store
- https://github.com/dmgbuild/mac_alias
