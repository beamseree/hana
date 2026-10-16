# Persistent signing for personal Hana builds

Hana's normal build and install scripts use a persistent certificate instead of
ad-hoc signing. macOS compares an app's designated requirement when deciding
whether an update is the same app. A certificate-based requirement stays stable
when Hana's executable or resources change; the old ad-hoc requirement contained
the hash of each individual build.

## Setup and updates

```sh
./scripts/setup-signing
./scripts/build
./scripts/validate-signing
# Quit Hana normally before installing an update.
./scripts/run
```

Setup creates or reuses **Hana Local Development** in the user's default Keychain,
with a ten-year, self-signed certificate restricted to code signing. Trust is
limited to code signing in the user domain. The private key permits access by
`/usr/bin/codesign`; it is not placed in the repository. Temporary key material is
removed after import. This is a personal local signing identity, not Developer ID
distribution or notarization.

The public certificate fingerprint is pinned in
`~/Library/Application Support/Hana/Signing/identity.sha1`, shared by Hana
checkouts on this Mac. Setup is idempotent. If the pinned identity disappears or
becomes invalid, setup and signing stop rather than silently generating another
identity or reverting to ad-hoc signing. Preserve the certificate and private key
in the Keychain across updates.

To deliberately use an existing valid Apple Development or Developer ID identity,
set `HANA_SIGNING_IDENTITY` to its full SHA-1 certificate fingerprint. Installation
rejects a different certificate-based designated requirement unless an intentional
migration is requested with `HANA_ALLOW_SIGNING_CHANGE=1`. Switching certificates
or signing policies can require another permission approval.

The bundle identifier remains `com.beamseree.hana`, and the installed path remains
`~/Applications/Hana.app`. Build and installation mirror their resources, removing
stale bundle files that would invalidate the signature.

## Migration and evidence limits

Moving from the old ad-hoc signature to this certificate changes Hana's identity
once. Existing Desktop, Documents, Downloads, Accessibility or Full Disk Access
grants may need one final user approval for the installed app. No script changes
those privacy settings, resets TCC, or grants Full Disk Access.

`scripts/validate-signing` signs two disposable copies of the real app with
different bundle versions. It requires different code hashes, identical
certificate-based designated requirements, and successful verification of each
bundle against the other's requirement. It also checks that invalid or missing
signers fail without modifying the bundle. The copies are never launched.

Those checks verify signature continuity. Permission retention across two
normally launched updates still needs a user-authorized trial after the migration
approval; it is not established by signature verification alone.

Local verification on 2026-10-16 passed the two-bundle continuity and signer
rejection checks. Re-running setup retained certificate fingerprint
`5C1F81113ECCDB4AE9B6D5C89AA22B045A29417B`. The normally installed and launched app
passed strict signature verification with authority **Hana Local Development**
and designated requirement
`identifier "com.beamseree.hana" and certificate leaf = H"5c1f81113eccdb4ae9b6d5c89aa22b045a29417b"`.
Its installed CDHash was `d48d15592edb894d21e82dc8d07adc1c42d30c1c`.
Native privacy-grant retention after a later update remains pending.

Apple references: [stable signing and TCC](https://developer.apple.com/forums/thread/663889),
[designated requirements and self-signed identities](https://developer.apple.com/library/archive/technotes/tn2206/),
[code signing tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html).
