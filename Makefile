.PHONY: check

check:
	@set -e; for file in AuctionatorTools/*.lua tests/*.lua; do \
		luac5.1 -p "$$file"; \
	done
	@set -e; for file in tests/*.lua; do \
		lua5.1 "$$file"; \
	done
