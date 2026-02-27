#!/bin/bash
# Generate a code signing certificate and import to YubiKey(s).
# The key is generated in software, imported to each YubiKey, then deleted.

set -e

echo "==> Generating RSA 2048 key + cert with code signing EKU"
openssl req -x509 -newkey rsa:2048 -keyout /tmp/cs-key.pem -out /tmp/cs-cert.pem \
  -days 36500 -nodes -subj "/CN=Developer Signing" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning"

echo ""
echo "Verify extensions:"
openssl x509 -in /tmp/cs-cert.pem -noout -text | grep -A1 "Extended Key Usage"

echo ""
echo "==> Importing to YubiKey #1 (slot 9c)"
echo "    Make sure your first YubiKey is plugged in, then press Enter."
read -r
ykman piv keys import 9c /tmp/cs-key.pem --pin-policy always
ykman piv certificates import 9c /tmp/cs-cert.pem --verify
echo "    YubiKey #1 done."

echo ""
echo "==> Trusting cert for code signing"
security delete-certificate -c "Developer Signing" ~/Library/Keychains/login.keychain-db 2>/dev/null || true
security import /tmp/cs-cert.pem -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
security add-trusted-cert -p codeSign /tmp/cs-cert.pem
echo "    Trust configured."

echo ""
echo "==> Import to YubiKey #2? Swap keys and press Enter (or Ctrl-C to skip)."
read -r
echo "==> Importing to YubiKey #2 (slot 9c)"
ykman piv keys import 9c /tmp/cs-key.pem --pin-policy always
ykman piv certificates import 9c /tmp/cs-cert.pem --verify
echo "    YubiKey #2 done."

echo ""
echo "==> Deleting software key"
rm -f /tmp/cs-key.pem /tmp/cs-cert.pem

echo ""
echo "Done! Unplug and replug YubiKey, then verify:"
echo '  bash -c '"'"'cp /bin/echo /tmp/test && codesign --force --sign "Developer Signing" /tmp/test && codesign -dvv /tmp/test; rm /tmp/test'"'"''
