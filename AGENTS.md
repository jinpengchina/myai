# myai repository guide

myai is an iPhone developer preview based on Poki. Use the local build and signing instructions in [README.md](README.md). Generate the Xcode project using `native/ios-app/scripts/generate-myai-project.sh` and keep credentials and personal signing values in local files.

- Use black backgrounds, white text and English interface copy for new designs.
- Preserve existing users' setup, pairing and account records during updates. Test fresh setup with a separately signed installation.
- Keep copyright notices, licenses and change attribution when modifying or removing inherited code. Use distributable assets with documented permissions.
- Validate the relevant iOS build and tests. Identify simulator and physical-device checks separately. The built-in packet tunnel requires a physical iPhone for runtime verification.
- Keep test artifacts, signing profiles, device and pairing data, logs and account credentials out of Git. Use synthetic pairing codes in screenshots and examples.
