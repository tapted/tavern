all: lib/src/packages
	dart2js --suppress-hints --package-root=lib/src/packages \
		 -o js/pubchrome.dart.js lib/src/app/pubchrome.dart

analyze :
	dartanalyzer --package-root lib/src/packages lib/src/app/pubchrome.dart

lib/src/packages: lib/src/pubspec.yaml
	cd lib/src/ && pub get

zip :
	rm -rf zip
	cp -r pub.html manifest.json style.css images zip/
	cp js/main.js js/pubchrome.dart.precompiled.js zip/js
	zip -r $(shell basename $(CURDIR)).zip zip/

.PHONY: app all analyze zip

