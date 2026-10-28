APP = macwm.app

.PHONY: app test run

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/macwm $(APP)/Contents/MacOS/macwm
	cp Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - --identifier com.benbrackenbury.macwm $(APP)

test:
	swift test

run: app
	open $(APP)
