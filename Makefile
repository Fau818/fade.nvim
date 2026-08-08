# Not `NVIM`: Neovim sets that to its own server socket for every process it spawns, so `make test`
# inside `:terminal` would try to execute the socket.
NVIM_BIN ?= nvim

# `make test` runs everything; `make test SPEC=ghost` runs one file.
.PHONY: test
test:
	@$(NVIM_BIN) --headless --clean -i NONE -l tests/run.lua $(SPEC)
