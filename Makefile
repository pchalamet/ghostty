init:
	@echo You probably want to run "zig build" instead.
.PHONY: init

# Build an optimized Apple Silicon app at zig-out/Ttyrex.app.
release:
	@test "$$(uname -s)" = Darwin && test "$$(uname -m)" = arm64 || \
		{ echo "release requires an arm64 macOS host" >&2; exit 1; }
	zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos \
		-Dxcframework-target=native -Demit-macos-app=true
.PHONY: release

# glad updates the GLAD loader. To use this, place the generated glad.zip
# in this directory next to the Makefile, remove vendor/glad and run this target.
#
# Generator: https://gen.glad.sh/
glad: vendor/glad
.PHONY: glad

vendor/glad: vendor/glad/include/glad/gl.h vendor/glad/include/glad/glad.h

vendor/glad/include/glad/gl.h: glad.zip
	rm -rf vendor/glad
	mkdir -p vendor/glad
	unzip glad.zip -dvendor/glad
	find vendor/glad -type f -exec touch '{}' +

vendor/glad/include/glad/glad.h: vendor/glad/include/glad/gl.h
	@echo "#include <glad/gl.h>" > $@

clean:
	rm -rf \
		zig-out .zig-cache \
		macos/build \
		macos/GhosttyKit.xcframework
.PHONY: clean
