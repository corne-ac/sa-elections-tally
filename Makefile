.PHONY: build install uninstall run snapshot test clean

build:        ## Build dist/Tally.app
	@./scripts/build.sh

install:      ## Build and install to ~/Applications, then launch
	@./scripts/install.sh

uninstall:    ## Remove the app and every trace it can leave
	@./scripts/uninstall.sh

run: build    ## Run from dist/ without installing
	@open dist/Tally.app

snapshot: build  ## Render the live dashboard to PNGs in ./snapshots
	@./dist/Tally.app/Contents/MacOS/Tally --snapshot "$(CURDIR)/snapshots"

test:         ## Run the map click-rule tests (no Xcode project needed)
	@mkdir -p .build/tests
	@swiftc -module-cache-path .build/tests/mc Tests/MapNavigation/main.swift Sources/Tally/MapNavigation.swift -o .build/tests/navtest
	@./.build/tests/navtest

clean:
	@rm -rf .build dist snapshots
