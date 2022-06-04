# Copyright (C) 2016-2022  Jonas Bernoulli
#
# Author: Jonas Bernoulli <jonas@bernoul.li>
# SPDX-License-Identifier: GPL-3.0-or-later

BORG_DIR := $(dir $(lastword $(MAKEFILE_LIST)))

-include etc/borg/config.mk

ifeq "$(BORG_SECONDARY_P)" "true"
  DRONES_DIR ?= $(shell git config "borg.drones-directory" || echo "elpa")
  BORG_ARGUMENTS = -L $(BORG_DIR) --load borg-elpa \
  --funcall borg-elpa-initialize
else
  DRONES_DIR ?= $(shell git config "borg.drones-directory" || echo "lib")
  BORG_ARGUMENTS = -L $(BORG_DIR) --load borg \
  --funcall borg-initialize
endif

EMACS           ?= emacs
EMACS_ARGUMENTS ?= -Q --batch

EMACS_EXTRA ?=

.PHONY: all help clean clean-init build build-init quick bootstrap
.FORCE:

all: build

SILENCIO  = --load subr-x
SILENCIO += --eval "(setq byte-compile-warnings '(not docstrings))"
SILENCIO += --eval "(setq borg-default-build-step '(borg-update-autoloads borg-byte-compile))"
SILENCIO += --eval "(fset 'original-message (symbol-function 'message))"
SILENCIO += --eval "(fset 'message\
(lambda (format &rest args)\
  (unless (or (equal format \"pcase-memoize: equal first branch, yet different\")\
              (equal format \"Not registering prefix \\\"%s\\\" from %s.  Affects: %S\")\
              (and (stringp (car args))\
                   (string-match-p \"Scraping files for\" (car args))))\
    (apply 'original-message format args))))"

help::
	$(info make [all|build]     = rebuild all drones and init files)
	$(info make quick           = rebuild most drones and init files)
ifeq "$(BORG_SECONDARY_P)" "true"
	$(info make $(DRONES_DIR)/DRONE      = rebuild DRONE)
else
	$(info make $(DRONES_DIR)/DRONE       = rebuild DRONE)
endif
	$(info make build-native    = rebuild drones natively and init files)
	$(info make build-init      = rebuild init files)
	$(info make tangle-init     = recreate init.el from init.org)
	$(info make clean           = remove all byte-code files)
	$(info make clean-init      = remove init files)
ifneq "$(BORG_SECONDARY_P)" "true"
	$(info make bootstrap-borg  = bootstrap borg itself)
endif
	$(info make bootstrap       = bootstrap collective or new drones)
	@true

clean:
	@find . -name '*.elc' -exec rm '{}' ';'

clean-init:
	@rm -f init.elc $(INIT_FILES:.el=.elc)

build: clean-init
	@$(EMACS) $(EMACS_ARGUMENTS) $(EMACS_EXTRA) $(SILENCIO) \
	$(BORG_ARGUMENTS) \
	--funcall borg-batch-rebuild $(INIT_FILES) 2>&1

build-native:
	@$(EMACS) $(EMACS_ARGUMENTS) $(EMACS_EXTRA) $(SILENCIO) \
	$(BORG_ARGUMENTS) \
	--eval "(borg-batch-rebuild nil 'native-compile-async)" \
	$(INIT_FILES) 2>&1

build-init: clean-init
	@$(EMACS) $(EMACS_ARGUMENTS) $(EMACS_EXTRA) \
	$(BORG_ARGUMENTS) \
	--funcall borg-batch-rebuild-init $(INIT_FILES) 2>&1

tangle-init: init.el
init.el: init.org
	@$(EMACS) $(EMACS_ARGUMENTS) $(EMACS_EXTRA) \
	--load org \
	--eval '(org-babel-tangle-file "init.org")' 2>&1

quick: clean-init
	@$(EMACS) $(EMACS_ARGUMENTS) $(EMACS_EXTRA) $(SILENCIO) \
	$(BORG_ARGUMENTS) \
	--eval '(borg-batch-rebuild t)' 2>&1

$(BORG_DIR)borg.mk: ;
$(DRONES_DIR)/%: .FORCE
	@$(EMACS) $(EMACS_ARGUMENTS) $(EMACS_EXTRA) $(SILENCIO) \
	$(BORG_ARGUMENTS) \
	--eval '(borg-build "$*")' 2>&1

bootstrap:
	@printf "\n=== Running 'git submodule init' ===\n\n"
	@git submodule init
	@printf "\n=== Running '$(BORG_DIR)borg.sh' ===\n"
	@$(BORG_DIR)borg.sh
	@printf "\n=== Running 'make build' ===\n\n"
	@make build
