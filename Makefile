APP = macwm.app
SIGN_ID := macwm local

.PHONY: app test run

# Gatekeeper reports CSSMERR_TP_CERT_REVOKED for an Apple Development cert used outside Xcode, then moves the app to the Bin. This local cert is only "rejected", same as ad-hoc, and its hash stays put so Accessibility survives rebuilds.
app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/macwm $(APP)/Contents/MacOS/macwm
	cp Info.plist $(APP)/Contents/Info.plist
	keychain="$(HOME)/Library/Application Support/macwm/signing.keychain-db"; \
	if [ ! -f "$$keychain" ]; then \
		mkdir -p "$(HOME)/Library/Application Support/macwm"; \
		openssl req -x509 -newkey rsa:2048 -keyout /tmp/macwm-local.key -out /tmp/macwm-local.crt -days 3650 -nodes \
			-subj "/CN=$(SIGN_ID)/" -addext "extendedKeyUsage=codeSigning" -addext "keyUsage=digitalSignature"; \
		openssl pkcs12 -export -inkey /tmp/macwm-local.key -in /tmp/macwm-local.crt -out /tmp/macwm-local.p12 -passout pass:macwm; \
		security create-keychain -p macwm "$$keychain"; \
		security set-keychain-settings -lut 21600 "$$keychain"; \
		security unlock-keychain -p macwm "$$keychain"; \
		security import /tmp/macwm-local.p12 -k "$$keychain" -P macwm -T /usr/bin/codesign -T /usr/bin/security; \
		security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k macwm "$$keychain"; \
		rm -f /tmp/macwm-local.key /tmp/macwm-local.crt /tmp/macwm-local.p12; \
	fi; \
	security unlock-keychain -p macwm "$$keychain"; \
	codesign --force --sign "$(SIGN_ID)" --keychain "$$keychain" --identifier com.benbrackenbury.macwm $(APP)

test:
	swift test

run: app
	open $(APP)
